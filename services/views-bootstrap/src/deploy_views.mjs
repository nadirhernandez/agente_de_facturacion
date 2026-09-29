import { readdir, readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  AthenaClient,
  GetQueryExecutionCommand,
  StartQueryExecutionCommand,
  StopQueryExecutionCommand,
} from "@aws-sdk/client-athena";
import { GetTableCommand, GlueClient } from "@aws-sdk/client-glue";
import { InvokeCommand, LambdaClient } from "@aws-sdk/client-lambda";

/**
 * Deploys the analytical model from sql/model, the only place where tables and
 * views are defined. The same code runs for the pilot and for every tenant, so
 * a change to a .sql file reaches all of them identically.
 *
 *   tables/  created only when missing (Iceberg tables are never replaced)
 *   views/   always re-created (CREATE OR REPLACE VIEW)
 *
 * Runs at terraform apply, and after every successful Glue load. On a load it
 * then hands off to the SPICE refresh, so SPICE never reads a view that is
 * still being replaced.
 *
 * Also runnable locally with the same files:
 *   GLUE_DATABASE=... ATHENA_WORKGROUP=... WAREHOUSE_PATH=... SQL_DIR=sql/model \
 *     node services/views-bootstrap/src/deploy_views.mjs [--tables-only]
 */

const here = path.dirname(fileURLToPath(import.meta.url));

const athena = new AthenaClient({});
const glue = new GlueClient({});
const lambda = new LambdaClient({});

const required = (name) => {
  const value = process.env[name];
  if (!value) throw new Error(`Missing required environment variable: ${name}`);
  return value;
};

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// Outside Lambda (local runs) there is no remaining-time budget.
const LOCAL_BUDGET_MS = 15 * 60 * 1000;
// Time kept in reserve to stop a query and hand off before Lambda kills us.
const SAFETY_MS = 15_000;

const DATABASE_PATTERN = /^[a-z0-9_]{1,255}$/;
const WAREHOUSE_PATTERN = /^s3:\/\/[a-z0-9][a-z0-9.-]{1,61}[a-z0-9](\/[A-Za-z0-9_.=/-]*)?$/;

/**
 * Operator-supplied values go straight into DDL, so they are checked before
 * any statement is rendered: a stray quote must fail here, not in Athena.
 */
export function modelVariables(env = process.env) {
  const db = env.GLUE_DATABASE;
  if (!db || !DATABASE_PATTERN.test(db)) throw new Error(`Invalid GLUE_DATABASE: ${db}`);

  const warehouse = (env.WAREHOUSE_PATH ?? "").replace(/\/+$/, "");
  if (!WAREHOUSE_PATTERN.test(warehouse)) throw new Error(`Invalid WAREHOUSE_PATH: ${warehouse}`);

  const bucket = `s3://${new URL(warehouse).hostname}`;
  return { db, warehouse, bucket };
}
/** Replaces ${name} markers and refuses to run SQL with an unknown one left. */
export function render(sql, variables) {
  const rendered = sql.replace(/\$\{([a-z_]+)\}/g, (marker, name) => {
    if (!(name in variables)) throw new Error(`Unknown marker ${marker}`);
    return variables[name];
  });

  // Athena runs one statement per query; full-line comments are dropped so
  // DDL always starts with its keyword.
  return rendered
    .split("\n")
    .filter((line) => !line.trim().startsWith("--"))
    .join("\n")
    .trim()
    .replace(/;\s*$/, "");
}

/**
 * Reads <dir>/<kind>/*.sql in name order. Object name comes from the file name.
 * With `optional`, a missing folder (or an empty one) yields no statements
 * instead of failing: migrations exist only when the model needs them.
 */
export async function loadStatements(sqlDir, kind, variables, { optional = false } = {}) {
  const folder = path.join(sqlDir, kind);
  let files;
  try {
    files = (await readdir(folder)).filter((file) => file.endsWith(".sql")).sort();
  } catch (error) {
    if (optional && error?.code === "ENOENT") return [];
    throw error;
  }
  if (files.length === 0) {
    if (optional) return [];
    throw new Error(`No SQL files in ${folder}`);
  }

  return Promise.all(
    files.map(async (file) => {
      const match = /^\d+_(.+)\.sql$/.exec(file);
      if (!match) throw new Error(`SQL file must be named NN_<name>.sql: ${file}`);
      const sql = render(await readFile(path.join(folder, file), "utf8"), variables);
      return { file, name: match[1], sql };
    }),
  );
}

/**
 * Runs one statement and waits for it with exponential backoff, never past the
 * deadline: a statement still running then is stopped, so a timeout never
 * leaves a half-replaced model behind a silently killed Lambda.
 */
async function execute(statement, database, workGroup, deadline) {
  const started = await athena.send(
    new StartQueryExecutionCommand({
      QueryString: statement,
      WorkGroup: workGroup,
      QueryExecutionContext: { Database: database },
    }),
  );
  const id = started.QueryExecutionId;

  for (let attempt = 0; Date.now() < deadline; attempt += 1) {
    await sleep(Math.min(500 * 2 ** attempt, 5000));
    const execution = await athena.send(new GetQueryExecutionCommand({ QueryExecutionId: id }));
    const state = execution.QueryExecution?.Status?.State;

    if (state === "SUCCEEDED") return;
    if (state === "FAILED" || state === "CANCELLED") {
      throw new Error(
        `Athena ${state}: ${execution.QueryExecution?.Status?.StateChangeReason ?? "unknown"}`,
      );
    }
  }

  await athena.send(new StopQueryExecutionCommand({ QueryExecutionId: id })).catch(() => undefined);
  throw new Error(`Athena statement ${id} did not finish before the deadline and was stopped`);
}

async function tableExists(database, name) {
  try {
    await glue.send(new GetTableCommand({ DatabaseName: database, Name: name }));
    return true;
  } catch (error) {
    if (error.name === "EntityNotFoundException") return false;
    throw error;
  }
}

/**
 * Any failure stops the deployment. Views over a missing table or an invalid
 * statement are real problems: hiding them would leave SPICE refreshing
 * yesterday's model without anyone noticing.
 */
export async function deployModel({
  tablesOnly = false,
  deadline = Date.now() + LOCAL_BUDGET_MS,
} = {}) {
  const variables = modelVariables();
  const database = variables.db;
  const workGroup = required("ATHENA_WORKGROUP");
  const sqlDir = process.env.SQL_DIR ?? path.join(here, "sql");

  const summary = { tablesCreated: [], tablesExisting: [], migrations: [], views: [] };

  for (const table of await loadStatements(sqlDir, "tables", variables)) {
    if (await tableExists(database, table.name)) {
      summary.tablesExisting.push(table.name);
      continue;
    }
    await execute(table.sql, database, workGroup, deadline);
    summary.tablesCreated.push(table.name);
  }

  // Data migrations run on every deploy, after the tables exist and before the
  // views are replaced, so a view never points at a table that is still empty.
  // Each statement must be idempotent (a no-op once the data is in place).
  for (const migration of await loadStatements(sqlDir, "migrations", variables, {
    optional: true,
  })) {
    await execute(migration.sql, database, workGroup, deadline);
    summary.migrations.push(migration.name);
  }

  if (!tablesOnly) {
    for (const view of await loadStatements(sqlDir, "views", variables)) {
      await execute(view.sql, database, workGroup, deadline);
      summary.views.push(view.name);
    }
  }

  return summary;
}

export const handler = async (event = {}, context) => {
  const remaining = context?.getRemainingTimeInMillis?.() ?? LOCAL_BUDGET_MS;
  const summary = await deployModel({ deadline: Date.now() + remaining - SAFETY_MS });
  console.log(JSON.stringify({ message: "Model deployed", ...summary }));

  // After a successful Glue load, refresh SPICE only once the views are in
  // place. The rule already filters SUCCEEDED; checking again costs nothing.
  const loadSucceeded = event?.detail?.state === undefined || event.detail.state === "SUCCEEDED";
  const jobRunId = loadSucceeded ? event?.detail?.jobRunId : undefined;
  const refreshFunction = process.env.REFRESH_FUNCTION_NAME;
  if (jobRunId && refreshFunction) {
    await lambda.send(
      new InvokeCommand({
        FunctionName: refreshFunction,
        InvocationType: "Event",
        Payload: Buffer.from(JSON.stringify({ jobRunId, trigger: "glue-load" })),
      }),
    );
    console.log(JSON.stringify({ message: "SPICE refresh requested", jobRunId }));
  }

  return summary;
};

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  deployModel({ tablesOnly: process.argv.includes("--tables-only") })
    .then((summary) => console.log(JSON.stringify(summary, null, 2)))
    .catch((error) => {
      console.error(error);
      process.exitCode = 1;
    });
}
