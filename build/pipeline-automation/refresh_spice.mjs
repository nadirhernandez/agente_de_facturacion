import {
  AthenaClient,
  GetQueryExecutionCommand,
  GetQueryResultsCommand,
  StartQueryExecutionCommand,
} from "@aws-sdk/client-athena";
import { CreateIngestionCommand, QuickSightClient } from "@aws-sdk/client-quicksight";

const quicksight = new QuickSightClient({});
const athena = new AthenaClient({});

const required = (name) => {
  const value = process.env[name];
  if (!value) throw new Error(`Missing required environment variable: ${name}`);
  return value;
};

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

const DAY_MS = 24 * 60 * 60 * 1000;

/**
 * Oldest emission date loaded by one Glue run, from ctl_archivos_procesados.
 * Returns undefined when the run recorded no files.
 */
async function oldestDateLoaded(jobRunId) {
  // Glue run ids are "jr_" plus hex; anything else never reaches the SQL.
  if (!/^jr_[0-9a-f]+$/.test(jobRunId)) throw new Error(`Unexpected job run id: ${jobRunId}`);

  const database = required("ATHENA_DATABASE");
  const started = await athena.send(
    new StartQueryExecutionCommand({
      QueryString:
        `SELECT CAST(min(fecha_min) AS varchar), count(*) ` +
        `FROM ${database}.ctl_archivos_procesados WHERE job_run_id = '${jobRunId}'`,
      WorkGroup: required("ATHENA_WORKGROUP"),
      QueryExecutionContext: { Database: database },
    }),
  );

  for (let attempt = 0; attempt < 30; attempt += 1) {
    await sleep(1000);
    const { QueryExecution } = await athena.send(
      new GetQueryExecutionCommand({ QueryExecutionId: started.QueryExecutionId }),
    );
    const state = QueryExecution?.Status?.State;
    if (state === "SUCCEEDED") break;
    if (state === "FAILED" || state === "CANCELLED") {
      throw new Error(`Athena ${state}: ${QueryExecution?.Status?.StateChangeReason}`);
    }
  }

  const { ResultSet } = await athena.send(
    new GetQueryResultsCommand({ QueryExecutionId: started.QueryExecutionId }),
  );
  const [oldest, files] = (ResultSet?.Rows?.[1]?.Data ?? []).map((cell) => cell.VarCharValue);
  return Number(files) > 0 && oldest ? oldest : undefined;
}

/**
 * Incremental refresh replaces only the last LOOKBACK_DAYS of SPICE. It is only
 * correct when everything the load touched falls inside that window, so the
 * decision uses the oldest date the load actually wrote. Two days of margin
 * cover the gap between UTC and the local date the invoices carry.
 *
 * Any doubt resolves to a full refresh: it is slower, never wrong.
 */
export async function chooseRefreshType(jobRunId, now = new Date()) {
  if (!jobRunId) return { type: "FULL_REFRESH", reason: "no Glue run in the event" };

  const oldest = await oldestDateLoaded(jobRunId);
  if (!oldest) return { type: "FULL_REFRESH", reason: "run recorded no files" };

  const lookbackDays = Number(required("LOOKBACK_DAYS"));
  const safeDays = lookbackDays - 2;
  const cutoff = new Date(now.getTime() - safeDays * DAY_MS).toISOString().slice(0, 10);

  return oldest >= cutoff
    ? { type: "INCREMENTAL_REFRESH", reason: `oldest date ${oldest} within ${safeDays} days`, oldest }
    : { type: "FULL_REFRESH", reason: `oldest date ${oldest} older than ${cutoff}`, oldest };
}

async function ingest(dataSetId, type, stamp) {
  const ingestionId = `auto-${stamp}-${type === "INCREMENTAL_REFRESH" ? "inc" : "full"}-${dataSetId.slice(-12)}`;
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
    // One dataset failing must not stop the other.
    console.error(JSON.stringify({ message: "Refresh failed", dataSetId, type, error: String(error) }));
    return { dataSetId, type, error: String(error) };
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
  const decision = await chooseRefreshType(jobRunId);
  const stamp = Date.now();

  const results = [await ingest(required("LINES_DATA_SET_ID"), decision.type, stamp)];
  const periods = process.env.PERIODS_DATA_SET_ID;
  if (periods) results.push(await ingest(periods, "FULL_REFRESH", stamp));

  console.log(JSON.stringify({ message: "SPICE refresh requested", jobRunId, decision, results }));
  return { decision, results };
};
