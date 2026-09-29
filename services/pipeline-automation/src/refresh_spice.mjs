import {
  AthenaClient,
  GetQueryExecutionCommand,
  GetQueryResultsCommand,
  StartQueryExecutionCommand,
  StopQueryExecutionCommand,
} from "@aws-sdk/client-athena";
import { CreateIngestionCommand, QuickSightClient } from "@aws-sdk/client-quicksight";

const quicksight = new QuickSightClient({ maxAttempts: 5, retryMode: "adaptive" });
const athena = new AthenaClient({});

const required = (name) => {
  const value = process.env[name];
  if (!value) throw new Error(`Missing required environment variable: ${name}`);
  return value;
};

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

const DAY_MS = 24 * 60 * 60 * 1000;
// Guatemala: UTC-06:00 all year. Invoice dates in the model are local dates.
const BUSINESS_OFFSET_MS = -6 * 60 * 60 * 1000;
const QUERY_TIMEOUT_MS = 60_000;
const JOB_RUN_ID_PATTERN = /^jr_[0-9a-f]+$/;

/** Today's civil date in Guatemala, as YYYY-MM-DD. */
export const businessDate = (now = new Date()) =>
  new Date(now.getTime() + BUSINESS_OFFSET_MS).toISOString().slice(0, 10);

function lookbackDays() {
  const days = Number(required("LOOKBACK_DAYS"));
  if (!Number.isInteger(days) || days < 3)
    throw new Error(`LOOKBACK_DAYS must be an integer >= 3, got ${days}`);
  return days;
}

/**
 * Oldest emission date loaded by one Glue run, from ctl_archivos_procesados.
 * Returns undefined when the run recorded no files.
 */
async function oldestDateLoaded(jobRunId) {
  // Glue run ids are "jr_" plus hex; anything else never reaches the SQL.
  if (!JOB_RUN_ID_PATTERN.test(jobRunId)) throw new Error(`Unexpected job run id: ${jobRunId}`);

  const database = required("ATHENA_DATABASE");
  if (!/^[a-z0-9_]+$/.test(database)) throw new Error(`Invalid ATHENA_DATABASE: ${database}`);

  const started = await athena.send(
    new StartQueryExecutionCommand({
      QueryString:
        `SELECT CAST(min(fecha_min) AS varchar), count(*) ` +
        `FROM ${database}.ctl_archivos_procesados WHERE job_run_id = ?`,
      ExecutionParameters: [`'${jobRunId}'`],
      WorkGroup: required("ATHENA_WORKGROUP"),
      QueryExecutionContext: { Database: database },
    }),
  );
  const id = started.QueryExecutionId;

  const deadline = Date.now() + QUERY_TIMEOUT_MS;
  let state;
  for (let attempt = 0; Date.now() < deadline; attempt += 1) {
    await sleep(Math.min(250 * 2 ** attempt, 4000));
    const { QueryExecution } = await athena.send(
      new GetQueryExecutionCommand({ QueryExecutionId: id }),
    );
    state = QueryExecution?.Status?.State;
    if (state === "SUCCEEDED") break;
    if (state === "FAILED" || state === "CANCELLED") {
      throw new Error(`Athena ${state}: ${QueryExecution?.Status?.StateChangeReason}`);
    }
  }

  if (state !== "SUCCEEDED") {
    await athena
      .send(new StopQueryExecutionCommand({ QueryExecutionId: id }))
      .catch(() => undefined);
    throw new Error(`Athena query ${id} timed out after ${QUERY_TIMEOUT_MS} ms`);
  }

  const { ResultSet } = await athena.send(new GetQueryResultsCommand({ QueryExecutionId: id }));
  const [oldest, files] = (ResultSet?.Rows?.[1]?.Data ?? []).map((cell) => cell.VarCharValue);
  return Number(files) > 0 && oldest ? oldest : undefined;
}

/**
 * Incremental refresh replaces only the last LOOKBACK_DAYS of SPICE. It is only
 * correct when everything the load touched falls inside that window, so the
 * decision uses the oldest date the load actually wrote, compared with today's
 * date in Guatemala. Two days of margin absorb the window boundary.
 *
 * Any doubt resolves to a full refresh: it is slower, never wrong.
 */
export async function chooseRefreshType(jobRunId, now = new Date(), readOldest = oldestDateLoaded) {
  if (!jobRunId) return { type: "FULL_REFRESH", reason: "no Glue run in the event" };

  const oldest = await readOldest(jobRunId);
  if (!oldest) return { type: "FULL_REFRESH", reason: "run recorded no files" };

  const safeDays = lookbackDays() - 2;
  const cutoff = businessDate(new Date(now.getTime() - safeDays * DAY_MS));

  return oldest >= cutoff
    ? {
        type: "INCREMENTAL_REFRESH",
        reason: `oldest date ${oldest} within ${safeDays} days`,
        oldest,
      }
    : { type: "FULL_REFRESH", reason: `oldest date ${oldest} older than ${cutoff}`, oldest };
}

/**
 * Deterministic per (Glue run, dataset, type): a duplicate event or an async
 * retry asks for the same ingestion again and QuickSight answers "exists"
 * instead of refreshing twice. Manual calls get a unique id.
 */
export function ingestionIdFor(dataSetId, type, origin) {
  const kind = type === "INCREMENTAL_REFRESH" ? "inc" : "full";
  return `auto-${origin}-${kind}-${dataSetId}`.replace(/[^A-Za-z0-9_-]/g, "-").slice(0, 128);
}

async function ingest(dataSetId, type, origin) {
  const ingestionId = ingestionIdFor(dataSetId, type, origin);
  try {
    const result = await quicksight.send(
      new CreateIngestionCommand({
        AwsAccountId: required("QUICKSIGHT_ACCOUNT_ID"),
        DataSetId: dataSetId,
        IngestionId: ingestionId,
        IngestionType: type,
      }),
    );
    return { dataSetId, type, ingestionId, status: result.IngestionStatus };
  } catch (error) {
    if (error.name === "ResourceExistsException") {
      return { dataSetId, type, ingestionId, status: "ALREADY_REQUESTED" };
    }
    // Keep going with the other dataset, then fail the invocation (below) so
    // the async retry asks again; the id makes the retry safe.
    console.error(
      JSON.stringify({
        message: "Refresh failed",
        dataSetId,
        type,
        error: { name: error.name, message: error.message },
      }),
    );
    return { dataSetId, type, ingestionId, error: `${error.name}: ${error.message}` };
  }
}

/**
 * Invoked by the model deployer once the views are in place after a Glue load,
 * with { jobRunId }. A direct invocation without it refreshes everything.
 *
 *   lines dataset:   incremental when the load stayed inside the window
 *   periods dataset: always full; it is one row per period and cheap to rebuild
 */
export const handler = async (event = {}) => {
  const jobRunId = event.jobRunId ?? event.detail?.jobRunId;
  if (jobRunId && !JOB_RUN_ID_PATTERN.test(jobRunId))
    throw new Error(`Unexpected job run id: ${jobRunId}`);

  const decision = await chooseRefreshType(jobRunId);
  const origin = jobRunId ?? `manual-${Date.now()}`;

  const results = [await ingest(required("LINES_DATA_SET_ID"), decision.type, origin)];
  const periods = process.env.PERIODS_DATA_SET_ID;
  if (periods) results.push(await ingest(periods, "FULL_REFRESH", origin));

  console.log(JSON.stringify({ message: "SPICE refresh requested", jobRunId, decision, results }));

  const failed = results.filter((result) => result.error);
  if (failed.length > 0) {
    throw new Error(
      `SPICE refresh failed for ${failed.map((result) => result.dataSetId).join(", ")}`,
    );
  }
  return { decision, results };
};
