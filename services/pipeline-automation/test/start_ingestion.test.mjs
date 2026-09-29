import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { mockClient } from "aws-sdk-client-mock";
import { GlueClient, StartJobRunCommand } from "@aws-sdk/client-glue";
import { GlueBusyError, handler } from "../src/start_ingestion.mjs";

const glue = mockClient(GlueClient);

const busy = () => Object.assign(new Error("busy"), { name: "ConcurrentRunsExceededException" });

beforeEach(() => {
  glue.reset();
  process.env.GLUE_JOB_NAME = "flatten-invoices";
  vi.spyOn(console, "log").mockImplementation(() => undefined);
  vi.spyOn(console, "warn").mockImplementation(() => undefined);
});

afterEach(() => vi.restoreAllMocks());

describe("start_ingestion handler", () => {
  it("starts the incremental Glue job", async () => {
    glue.on(StartJobRunCommand).resolves({ JobRunId: "jr_1" });

    await expect(
      handler({ source: "aws.s3", detail: { object: { key: "raw/a.jsonl" } } }),
    ).resolves.toEqual({
      runId: "jr_1",
    });
    expect(glue.commandCalls(StartJobRunCommand)[0].args[0].input).toEqual({
      JobName: "flatten-invoices",
      Arguments: { "--REPROCESS_ALL": "false" },
    });
  });

  it("throws GlueBusyError for an object event so Lambda retries later", async () => {
    glue.on(StartJobRunCommand).rejects(busy());
    await expect(handler({ source: "aws.s3" })).rejects.toBeInstanceOf(GlueBusyError);
  });

  it("skips quietly when the daily sweep finds the job already running", async () => {
    glue.on(StartJobRunCommand).rejects(busy());
    await expect(handler({ source: "aws.events" })).resolves.toEqual({ skipped: true });
  });

  it("propagates any other Glue error", async () => {
    glue.on(StartJobRunCommand).rejects(new Error("AccessDenied"));
    await expect(handler({})).rejects.toThrow("AccessDenied");
  });

  it("fails fast without GLUE_JOB_NAME", async () => {
    delete process.env.GLUE_JOB_NAME;
    await expect(handler({})).rejects.toThrow(
      "Missing required environment variable: GLUE_JOB_NAME",
    );
  });
});
