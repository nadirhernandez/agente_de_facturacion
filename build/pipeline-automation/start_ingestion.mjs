import { GlueClient, StartJobRunCommand } from "@aws-sdk/client-glue";

const client = new GlueClient({});

const required = (name) => {
  const value = process.env[name];
  if (!value) throw new Error(`Missing required environment variable: ${name}`);
  return value;
};

/**
 * Triggered by EventBridge when a new raw invoice file lands in S3.
 * Starts the incremental Glue job; concurrent runs are rejected by Glue itself,
 * which is the desired behaviour for a batch pipeline.
 */
export const handler = async (event) => {
  const key = event?.detail?.object?.key;
  console.log(JSON.stringify({ message: "Raw object received", key }));

  try {
    const result = await client.send(
      new StartJobRunCommand({
        JobName: required("GLUE_JOB_NAME"),
        Arguments: { "--REPROCESS_ALL": "false" },
      }),
    );
    console.log(JSON.stringify({ message: "Glue job started", runId: result.JobRunId }));
    return { runId: result.JobRunId };
  } catch (error) {
    if (error.name === "ConcurrentRunsExceededException") {
      console.log(JSON.stringify({ message: "Glue job already running; skipping" }));
      return { skipped: true };
    }
    throw error;
  }
};
