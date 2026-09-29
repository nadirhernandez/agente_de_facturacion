import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { mockClient } from "aws-sdk-client-mock";
import {
  GenerateEmbedUrlForRegisteredUserCommand,
  ListIngestionsCommand,
  ListUsersCommand,
  QuickSightClient,
} from "@aws-sdk/client-quicksight";

import { handler, isAllowedEmail, verifiedEmail } from "../src/handler.mjs";

const quicksight = mockClient(QuickSightClient);

const BASE_ENV = {
  QUICKSIGHT_ACCOUNT_ID: "123456789012",
  DASHBOARD_ID: "pulso-facturacion-dev",
  DATA_SET_IDS: "ds-lines,ds-periods",
  ALLOWED_DOMAINS: "https://app.example.com, http://localhost:5173",
  CORS_ORIGIN: "https://app.example.com",
};

const SHARED_ARN = "arn:aws:quicksight:us-east-1:123456789012:user/default/admin";

function apiEvent({
  method = "GET",
  path = "/embed",
  experience = "dashboard",
  claims = { sub: "sub-1", email: "Ana@Example.com", email_verified: "true" },
} = {}) {
  return {
    rawPath: path,
    requestContext: { http: { method, path }, authorizer: { jwt: { claims } } },
    queryStringParameters: experience === null ? undefined : { experience },
  };
}

const body = (response) => JSON.parse(response.body);

beforeEach(() => {
  quicksight.reset();
  process.env = { ...BASE_ENV };
  vi.spyOn(console, "log").mockImplementation(() => undefined);
  vi.spyOn(console, "warn").mockImplementation(() => undefined);
  vi.spyOn(console, "error").mockImplementation(() => undefined);
});

afterEach(() => {
  vi.restoreAllMocks();
});

describe("verifiedEmail", () => {
  it("returns the normalized email only when the claim is verified", () => {
    expect(verifiedEmail({ email: "  Ana@Example.com ", email_verified: true })).toBe(
      "ana@example.com",
    );
    expect(verifiedEmail({ email: "ana@example.com", email_verified: "true" })).toBe(
      "ana@example.com",
    );
  });

  it("rejects unverified, missing or non-string emails", () => {
    expect(verifiedEmail({ email: "ana@example.com", email_verified: false })).toBeUndefined();
    expect(verifiedEmail({ email: "ana@example.com", email_verified: "false" })).toBeUndefined();
    expect(verifiedEmail({ email_verified: true })).toBeUndefined();
    expect(verifiedEmail({ email: 42, email_verified: true })).toBeUndefined();
    expect(verifiedEmail({ email: "   ", email_verified: true })).toBeUndefined();
    expect(verifiedEmail()).toBeUndefined();
  });
});

describe("isAllowedEmail", () => {
  it("accepts any verified email when no domain list is configured", () => {
    expect(isAllowedEmail("ana@example.com", [])).toBe(true);
  });

  it("never accepts a missing email", () => {
    expect(isAllowedEmail(undefined, [])).toBe(false);
    expect(isAllowedEmail("", ["example.com"])).toBe(false);
  });

  it("matches the exact domain only", () => {
    const domains = ["example.com"];
    expect(isAllowedEmail("ana@example.com", domains)).toBe(true);
    expect(isAllowedEmail("ana@mail.example.com", domains)).toBe(false);
    expect(isAllowedEmail("ana@example.com.evil.io", domains)).toBe(false);
    expect(isAllowedEmail("@example.com", domains)).toBe(false);
  });

  it("reads ALLOWED_EMAIL_DOMAINS from the environment by default", () => {
    process.env.ALLOWED_EMAIL_DOMAINS = " Example.com , other.org";
    expect(isAllowedEmail("ana@example.com")).toBe(true);
    expect(isAllowedEmail("ana@other.org")).toBe(true);
    expect(isAllowedEmail("ana@else.net")).toBe(false);
  });
});

describe("handler: request validation", () => {
  it("answers CORS preflight with 204 and the configured origin", async () => {
    const response = await handler(apiEvent({ method: "OPTIONS" }));
    expect(response.statusCode).toBe(204);
    expect(response.headers["access-control-allow-origin"]).toBe("https://app.example.com");
    expect(response.headers["cache-control"]).toBe("no-store");
  });

  it("rejects unknown experiences with 400", async () => {
    const response = await handler(apiEvent({ experience: "console" }));
    expect(response.statusCode).toBe(400);
    expect(quicksight.calls()).toHaveLength(0);
  });

  it("rejects a missing experience with 400", async () => {
    const response = await handler(apiEvent({ experience: null }));
    expect(response.statusCode).toBe(400);
  });

  it("returns 403 when the email claim is not verified", async () => {
    const response = await handler(
      apiEvent({ claims: { sub: "s", email: "ana@example.com", email_verified: "false" } }),
    );
    expect(response.statusCode).toBe(403);
    expect(quicksight.calls()).toHaveLength(0);
  });

  it("returns 403 when the email domain is not allowed", async () => {
    process.env.ALLOWED_EMAIL_DOMAINS = "infile.com";
    const response = await handler(apiEvent());
    expect(response.statusCode).toBe(403);
    expect(quicksight.calls()).toHaveLength(0);
  });
});

describe("handler: shared identity mode", () => {
  beforeEach(() => {
    process.env.SHARED_QUICKSIGHT_USER_ARN = SHARED_ARN;
    quicksight
      .on(GenerateEmbedUrlForRegisteredUserCommand)
      .resolves({ EmbedUrl: "https://us-east-1.quicksight.aws.amazon.com/embed/abc" });
  });

  it("embeds the dashboard as the shared user without persisting state", async () => {
    const response = await handler(apiEvent({ experience: "dashboard" }));

    expect(response.statusCode).toBe(200);
    expect(body(response).embedUrl).toBe("https://us-east-1.quicksight.aws.amazon.com/embed/abc");
    expect(body(response).expiresAt).toMatch(/^\d{4}-\d{2}-\d{2}T/);

    const [call] = quicksight.commandCalls(GenerateEmbedUrlForRegisteredUserCommand);
    expect(call.args[0].input).toMatchObject({
      AwsAccountId: "123456789012",
      UserArn: SHARED_ARN,
      AllowedDomains: ["https://app.example.com", "http://localhost:5173"],
      SessionLifetimeInMinutes: 60,
      ExperienceConfiguration: {
        Dashboard: {
          InitialDashboardId: "pulso-facturacion-dev",
          FeatureConfigurations: {
            Bookmarks: { Enabled: false },
            SharedView: { Enabled: false },
            StatePersistence: { Enabled: false },
          },
        },
      },
    });
    expect(quicksight.commandCalls(ListUsersCommand)).toHaveLength(0);
  });

  it("embeds Quick chat", async () => {
    const response = await handler(apiEvent({ experience: "chat" }));
    expect(response.statusCode).toBe(200);
    const [call] = quicksight.commandCalls(GenerateEmbedUrlForRegisteredUserCommand);
    expect(call.args[0].input.ExperienceConfiguration).toEqual({ QuickChat: {} });
  });

  it("never logs the caller's email", async () => {
    await handler(apiEvent());
    const logged = console.log.mock.calls.map((args) => String(args[0])).join("\n");
    expect(logged).toContain("Embed URL issued");
    expect(logged).not.toContain("ana@example.com");
    expect(logged).toContain('"identity":"shared"');
  });

  it("returns 500 with a generic message when QuickSight fails", async () => {
    quicksight.on(GenerateEmbedUrlForRegisteredUserCommand).rejects(new Error("boom"));
    const response = await handler(apiEvent());
    expect(response.statusCode).toBe(500);
    expect(body(response).message).not.toContain("boom");
  });
});

describe("handler: per-user identity mode", () => {
  const userArn = "arn:aws:quicksight:us-east-1:123456789012:user/default/ana";

  beforeEach(() => {
    quicksight
      .on(GenerateEmbedUrlForRegisteredUserCommand)
      .resolves({ EmbedUrl: "https://us-east-1.quicksight.aws.amazon.com/embed/own" });
  });

  it("resolves the caller's own QuickSight user by verified email", async () => {
    quicksight
      .on(ListUsersCommand)
      .resolvesOnce({
        UserList: [{ Email: "other@example.com", Arn: "arn:other" }],
        NextToken: "p2",
      })
      .resolvesOnce({ UserList: [{ Email: "ANA@example.com", Arn: userArn, Active: true }] });

    const response = await handler(
      apiEvent({ claims: { sub: "s2", email: "ana@example.com", email_verified: true } }),
    );

    expect(response.statusCode).toBe(200);
    expect(quicksight.commandCalls(ListUsersCommand)).toHaveLength(2);
    const [call] = quicksight.commandCalls(GenerateEmbedUrlForRegisteredUserCommand);
    expect(call.args[0].input.UserArn).toBe(userArn);
    expect(
      call.args[0].input.ExperienceConfiguration.Dashboard.FeatureConfigurations.StatePersistence,
    ).toEqual({ Enabled: true });
  });

  it("returns 403 when no active QuickSight user matches", async () => {
    quicksight.on(ListUsersCommand).resolves({
      UserList: [{ Email: "nobody@example.com", Arn: userArn, Active: false }],
    });

    const response = await handler(
      apiEvent({ claims: { sub: "s3", email: "nobody@example.com", email_verified: true } }),
    );
    expect(response.statusCode).toBe(403);
    expect(quicksight.commandCalls(GenerateEmbedUrlForRegisteredUserCommand)).toHaveLength(0);
  });
});

describe("handler: /status", () => {
  it("reports the stalest completed ingestion and whether one is running", async () => {
    quicksight
      .on(ListIngestionsCommand, { DataSetId: "ds-lines" })
      .resolves({
        Ingestions: [
          { IngestionStatus: "RUNNING" },
          {
            IngestionStatus: "COMPLETED",
            CreatedTime: new Date("2026-09-28T10:00:00Z"),
            RowInfo: { RowsIngested: 120 },
          },
        ],
      })
      .on(ListIngestionsCommand, { DataSetId: "ds-periods" })
      .resolves({
        Ingestions: [
          { IngestionStatus: "COMPLETED", CreatedTime: new Date("2026-09-27T10:00:00Z") },
        ],
      });

    const response = await handler(apiEvent({ path: "/status", experience: null }));
    expect(response.statusCode).toBe(200);
    expect(body(response)).toEqual({
      lastRefreshAt: "2026-09-27T10:00:00.000Z",
      refreshing: true,
      datasets: [
        {
          dataSetId: "ds-lines",
          lastRefreshAt: "2026-09-28T10:00:00.000Z",
          rows: 120,
          running: true,
        },
        {
          dataSetId: "ds-periods",
          lastRefreshAt: "2026-09-27T10:00:00.000Z",
          rows: null,
          running: false,
        },
      ],
    });
  });

  it("degrades to nulls when a dataset cannot be read", async () => {
    quicksight.on(ListIngestionsCommand).rejects(new Error("denied"));
    const response = await handler(apiEvent({ path: "/status", experience: null }));
    expect(response.statusCode).toBe(200);
    expect(body(response).lastRefreshAt).toBeNull();
    expect(body(response).refreshing).toBe(false);
  });
});
