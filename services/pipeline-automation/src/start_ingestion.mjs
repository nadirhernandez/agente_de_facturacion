import { GlueClient, StartJobRunCommand } from "@aws-sdk/client-glue";

const client = new GlueClient({ maxAttempts: 5, retryMode: "adaptive" });

const required = (name) => {
  const value = process.env[name];
  if (!value) throw new Error(`Missing required environment variable: ${name}`);
  return value;
};

/** Raised on purpose so Lambda's async retry tries again once the run ends. */
export class GlueBusyError extends Error {
  constructor() {
    super("Glue job already running; the async retry will start it again");
    this.name = "GlueBusyError";
  }
}

/**
 * Starts the incremental Glue job. Triggered by EventBridge when a raw invoice
 * file lands in S3, and once a day by a backstop schedule.
 *
 * Nothing is lost when a run is already in progress (max_concurrent_runs = 1):
 *   1. the running job re-lists raw/ before finishing and loads late files;
 *   2. for a file that lands after that last listing, this function fails on
 *      purpose, so Lambda retries it (after ~1 and ~3 minutes);
 *   3. the daily schedule sweeps anything that is still pending, and a retry
 *      that exhausts its attempts is reported to the alerts topic.
 * The job only reads files missing from its control table, so extra runs are
 * harmless.
 */
export const handler = async (event = {}) => {
  const trigger = event.source === "aws.s3" ? "raw-object" : event.source === "aws.events" ? "schedule" : "manual";
  console.log(JSON.stringify({ message: "Ingestion requested", trigger, key: event.detail?.object?.key }));

  try {
    const result = await client.send(
      new StartJobRunCommand({
        JobName: required("GLUE_JOB_NAME"),
        Arguments: { "--REPROCESS_ALL": "false" },
      }),
    );
    console.log(JSON.stringify({ message: "Glue job started", trigger, runId: result.JobRunId }));
    return { runId: result.JobRunId };
  } catch (error) {
    if (error.name === "ConcurrentRunsExceededException") {
      // A scheduled sweep that finds the job busy has nothing left to do: the
      // running job will pick the files up itself.
      if (trigger === "schedule") {
        console.log(JSON.stringify({ message: "Glue job already running; sweep not needed" }));
        return { skipped: true };
      }
      console.warn(JSON.stringify({ message: "Glue job busy; deferring to async retry", trigger }));
      throw new GlueBusyError();
    }
    throw error;
  }
};
