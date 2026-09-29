import {
  GenerateEmbedUrlForRegisteredUserCommand,
  ListIngestionsCommand,
  ListUsersCommand,
  QuickSightClient,
} from "@aws-sdk/client-quicksight";

import { createHash } from "node:crypto";

// ListUsers has a low TPS quota; adaptive retries back off under throttling.
const client = new QuickSightClient({ maxAttempts: 5, retryMode: "adaptive" });

const SESSION_MINUTES = 60;
const CACHE_TTL_MS = 5 * 60 * 1000;

const errorInfo = (error) => ({
  name: error?.name,
  message: error?.message,
  requestId: error?.$metadata?.requestId,
});

/** Short, non-reversible reference to a caller for logs; never log the email itself. */
const callerRef = (value) => createHash("sha256").update(String(value)).digest("hex").slice(0, 12);

const required = (name) => {
  const value = process.env[name];
  if (!value) throw new Error(`Missing required environment variable: ${name}`);
  return value;
};

const csv = (value) =>
  (value ?? "")
    .split(",")
    .map((item) => item.trim().toLowerCase())
    .filter(Boolean);

const allowedDomains = () =>
  required("ALLOWED_DOMAINS")
    .split(",")
    .map((domain) => domain.trim())
    .filter(Boolean);

const response = (statusCode, body) => ({
  statusCode,
  headers: {
    "content-type": "application/json",
    // API Gateway's cors_configuration is the source of truth; this mirrors it.
    "access-control-allow-origin": required("CORS_ORIGIN"),
    "access-control-allow-methods": "GET,OPTIONS",
    vary: "Origin",
    "cache-control": "no-store",
  },
  body: JSON.stringify(body),
});

/**
 * Only a verified email identifies a person. Cognito leaves email_verified
 * false after an unverified change, so an unverified claim is never trusted.
 */
export function verifiedEmail(claims = {}) {
  const verified = claims.email_verified === true || claims.email_verified === "true";
  if (!verified || typeof claims.email !== "string") return undefined;
  const email = claims.email.trim().toLowerCase();
  return email || undefined;
}

/**
 * ALLOWED_EMAIL_DOMAINS (optional, comma separated) is a second gate behind the
 * Cognito pre sign-up trigger: a token for any other domain gets a 403.
 */
export function isAllowedEmail(email, domains = csv(process.env.ALLOWED_EMAIL_DOMAINS)) {
  if (!email) return false;
  if (domains.length === 0) return true;
  const at = email.lastIndexOf("@");
  return at > 0 && domains.includes(email.slice(at + 1));
}

/**
 * Shared identity mode. With SHARED_QUICKSIGHT_USER_ARN set, every verified
 * and allowed caller embeds as that single QuickSight user: same dashboard,
 * same agent, same permissions, and the same chat history. Meant for an
 * internal pilot only; the tenant module never sets it.
 */
const sharedIdentityArn = () => process.env.SHARED_QUICKSIGHT_USER_ARN || undefined;

/**
 * email -> QuickSight user ARN (or null for "no user"), with a TTL so that a
 * revoked or newly created user takes effect within minutes, and so that
 * unknown callers do not trigger a full ListUsers scan on every request.
 */
const userArnCache = new Map();

/**
 * Per-user identity: each person maps to their own QuickSight user, so row-level
 * security and author/reader permissions apply per user. No match means 403.
 */
async function resolveQuickSightUserArn(email) {
  const cached = userArnCache.get(email);
  if (cached && cached.expiresAt > Date.now()) return cached.arn ?? undefined;

  const accountId = required("QUICKSIGHT_ACCOUNT_ID");
  let nextToken;
  let arn = null;

  do {
    const page = await client.send(
      new ListUsersCommand({
        AwsAccountId: accountId,
        Namespace: "default",
        MaxResults: 100,
        NextToken: nextToken,
      }),
    );

    const match = page.UserList?.find(
      (user) => user.Email?.toLowerCase() === email && user.Active !== false,
    );

    if (match?.Arn) {
      arn = match.Arn;
      break;
    }

    nextToken = page.NextToken;
  } while (nextToken);

  userArnCache.set(email, { arn, expiresAt: Date.now() + CACHE_TTL_MS });
  if (!arn) {
    console.warn(
      JSON.stringify({
        message: "No QuickSight user matched the caller",
        caller: callerRef(email),
      }),
    );
  }
  return arn ?? undefined;
}

function experienceConfigurationFor(experience, { shared }) {
  switch (experience) {
    case "dashboard":
      return {
        Dashboard: {
          InitialDashboardId: required("DASHBOARD_ID"),
          FeatureConfigurations: {
            Bookmarks: { Enabled: false },
            SharedView: { Enabled: false },
            // With one shared identity, persisted filters would leak from one
            // person's session into everyone else's.
            StatePersistence: { Enabled: !shared },
          },
        },
      };
    case "chat":
      return { QuickChat: {} };
    default:
      return undefined;
  }
}

/**
 * Last successful SPICE ingestion per dataset. This is what the UI should show:
 * SPICE is a copy, so "up to date" only means "as of the last refresh".
 */
async function datasetFreshness() {
  const accountId = required("QUICKSIGHT_ACCOUNT_ID");
  const datasetIds = required("DATA_SET_IDS")
    .split(",")
    .map((id) => id.trim())
    .filter(Boolean);

  const datasets = await Promise.all(
    datasetIds.map(async (dataSetId) => {
      try {
        const page = await client.send(
          new ListIngestionsCommand({
            AwsAccountId: accountId,
            DataSetId: dataSetId,
            MaxResults: 20,
          }),
        );

        const completed = page.Ingestions?.find(
          (ingestion) => ingestion.IngestionStatus === "COMPLETED",
        );

        return {
          dataSetId,
          lastRefreshAt: completed?.CreatedTime
            ? new Date(completed.CreatedTime).toISOString()
            : null,
          rows: completed?.RowInfo?.RowsIngested ?? null,
          running:
            page.Ingestions?.some((ingestion) =>
              ["INITIALIZED", "QUEUED", "RUNNING"].includes(ingestion.IngestionStatus),
            ) ?? false,
        };
      } catch (error) {
        console.warn(
          JSON.stringify({ message: "Could not read ingestions", dataSetId, error: String(error) }),
        );
        return { dataSetId, lastRefreshAt: null, rows: null, running: false };
      }
    }),
  );

  const timestamps = datasets
    .map((item) => item.lastRefreshAt)
    .filter(Boolean)
    .sort();

  return {
    // The dashboard is only as fresh as its stalest dataset.
    lastRefreshAt: timestamps.length > 0 ? timestamps[0] : null,
    refreshing: datasets.some((item) => item.running),
    datasets,
  };
}

export const handler = async (event) => {
  if (event.requestContext?.http?.method === "OPTIONS") {
    return response(204, {});
  }

  const path = event.requestContext?.http?.path ?? event.rawPath ?? "";
  if (path.endsWith("/status")) {
    try {
      return response(200, await datasetFreshness());
    } catch (error) {
      console.error(
        JSON.stringify({ message: "Failed to read dataset freshness", error: errorInfo(error) }),
      );
      return response(500, { message: "No fue posible consultar la actualización de datos." });
    }
  }

  const shared = sharedIdentityArn();
  const experience = event.queryStringParameters?.experience;
  const experienceConfiguration = experienceConfigurationFor(experience, {
    shared: Boolean(shared),
  });

  if (!experienceConfiguration) {
    return response(400, { message: "experience must be dashboard or chat" });
  }

  const claims = event.requestContext?.authorizer?.jwt?.claims ?? {};
  const email = verifiedEmail(claims);
  const caller = claims.sub ?? "unknown";

  if (!isAllowedEmail(email)) {
    console.warn(
      JSON.stringify({
        message: "Caller rejected",
        caller,
        reason: email ? "domain" : "unverified-email",
      }),
    );
    return response(403, {
      message: "Tu cuenta no está habilitada para esta aplicación. Contacta al administrador.",
    });
  }

  try {
    const userArn = shared ?? (await resolveQuickSightUserArn(email));
    if (!userArn) {
      return response(403, {
        message: "Tu cuenta aún no tiene acceso a los tableros. Contacta al administrador.",
      });
    }

    const result = await client.send(
      new GenerateEmbedUrlForRegisteredUserCommand({
        AwsAccountId: required("QUICKSIGHT_ACCOUNT_ID"),
        UserArn: userArn,
        ExperienceConfiguration: experienceConfiguration,
        AllowedDomains: allowedDomains(),
        SessionLifetimeInMinutes: SESSION_MINUTES,
      }),
    );

    // Audit trail: who opened what. With a shared identity this log is the only
    // record of which person was behind a session.
    console.log(
      JSON.stringify({
        message: "Embed URL issued",
        caller,
        callerRef: callerRef(email),
        experience,
        identity: shared ? "shared" : "own",
      }),
    );

    return response(200, {
      embedUrl: result.EmbedUrl,
      expiresAt: new Date(Date.now() + SESSION_MINUTES * 60 * 1000).toISOString(),
    });
  } catch (error) {
    console.error(
      JSON.stringify({
        message: "Failed to generate QuickSight embed URL",
        caller,
        error: errorInfo(error),
      }),
    );
    return response(500, { message: "No fue posible iniciar la experiencia de análisis." });
  }
};
