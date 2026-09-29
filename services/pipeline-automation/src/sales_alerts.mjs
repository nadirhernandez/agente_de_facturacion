import {
  AthenaClient,
  GetQueryExecutionCommand,
  GetQueryResultsCommand,
  StartQueryExecutionCommand,
  StopQueryExecutionCommand,
} from "@aws-sdk/client-athena";
import { PublishCommand, SNSClient } from "@aws-sdk/client-sns";

const athena = new AthenaClient({});
const sns = new SNSClient({});

const required = (name) => {
  const value = process.env[name];
  if (!value) throw new Error(`Missing required environment variable: ${name}`);
  return value;
};

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// Guatemala: UTC-06:00 all year. Invoice dates in the model are local dates.
const BUSINESS_OFFSET_MS = -6 * 60 * 60 * 1000;
const QUERY_TIMEOUT_MS = 90_000;

function dropThreshold() {
  const value = Number(process.env.DROP_THRESHOLD_PCT ?? "10");
  if (!Number.isFinite(value) || value <= 0 || value > 100) {
    throw new Error(
      `DROP_THRESHOLD_PCT must be in (0, 100], got ${process.env.DROP_THRESHOLD_PCT}`,
    );
  }
  return value;
}

const isoDate = (date) => date.toISOString().slice(0, 10);

/**
 * The last complete month and the one before it, by the civil date in
 * Guatemala. Run on the 2nd of October: current = September, previous = August.
 * A month in progress is never compared: half a month always looks like a drop.
 */
export function comparisonMonths(now = new Date()) {
  const local = new Date(now.getTime() + BUSINESS_OFFSET_MS);
  const year = local.getUTCFullYear();
  const month = local.getUTCMonth(); // 0-based: the month in progress

  const currentStart = new Date(Date.UTC(year, month - 1, 1));
  const previousStart = new Date(Date.UTC(year, month - 2, 1));
  const end = new Date(Date.UTC(year, month, 1)); // exclusive

  return {
    mes: isoDate(currentStart).slice(0, 7),
    mesActual: isoDate(currentStart),
    mesPrevio: isoDate(previousStart),
    hasta: isoDate(end),
  };
}

/**
 * Month totals per currency and region. Amounts in different currencies are
 * never added together: each (moneda, region) pair is its own row. The date
 * bounds are literals on fecha, the fact table's partition column, so Athena
 * reads only those two months.
 */
export function buildQuery(database, { mesActual, mesPrevio, hasta }) {
  if (!/^[a-z0-9_]+$/.test(database)) throw new Error(`Invalid ATHENA_DATABASE: ${database}`);
  for (const value of [mesActual, mesPrevio, hasta]) {
    if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) throw new Error(`Invalid date bound: ${value}`);
  }

  return `
WITH agregado AS (
  SELECT
    codigo_moneda,
    region,
    sum(CASE WHEN fecha >= DATE '${mesActual}' THEN facturacion_total_linea ELSE 0 END) AS actual,
    sum(CASE WHEN fecha <  DATE '${mesActual}' THEN facturacion_total_linea ELSE 0 END) AS previo
  FROM ${database}.vw_ventas_comerciales
  WHERE fecha >= DATE '${mesPrevio}' AND fecha < DATE '${hasta}'
  GROUP BY codigo_moneda, region
)
SELECT
  codigo_moneda,
  region,
  round(actual, 2) AS facturacion_actual,
  round(previo, 2) AS facturacion_previa,
  CASE WHEN previo = 0 THEN NULL ELSE round((actual - previo) / previo * 100, 1) END AS variacion_pct
FROM agregado
ORDER BY codigo_moneda, variacion_pct ASC NULLS LAST
`;
}

async function runQuery(query) {
  const database = required("ATHENA_DATABASE");
  const started = await athena.send(
    new StartQueryExecutionCommand({
      QueryString: query,
      WorkGroup: required("ATHENA_WORKGROUP"),
      QueryExecutionContext: { Database: database },
    }),
  );
  const id = started.QueryExecutionId;
  const deadline = Date.now() + QUERY_TIMEOUT_MS;

  for (let attempt = 0; Date.now() < deadline; attempt += 1) {
    await sleep(Math.min(500 * 2 ** attempt, 5000));
    const execution = await athena.send(new GetQueryExecutionCommand({ QueryExecutionId: id }));
    const state = execution.QueryExecution?.Status?.State;

    if (state === "SUCCEEDED") {
      const results = await athena.send(new GetQueryResultsCommand({ QueryExecutionId: id }));
      const [, ...rows] = results.ResultSet?.Rows ?? [];
      return rows.map((row) => {
        const [moneda, region, actual, previo, variacion] = row.Data.map(
          (cell) => cell.VarCharValue,
        );
        return {
          moneda: moneda ?? "GTQ",
          region: region ?? "Sin región",
          actual: Number(actual ?? 0),
          previo: Number(previo ?? 0),
          // null: no sales in the previous month, so no percentage exists.
          variacion: variacion === undefined || variacion === null ? null : Number(variacion),
        };
      });
    }

    if (state === "FAILED" || state === "CANCELLED") {
      throw new Error(
        `Athena query ${state}: ${execution.QueryExecution?.Status?.StateChangeReason ?? "unknown"}`,
      );
    }
  }

  await athena.send(new StopQueryExecutionCommand({ QueryExecutionId: id })).catch(() => undefined);
  throw new Error(`Athena query ${id} timed out`);
}

/** Q for quetzales, US$ for dollars; never a bare "$" that could mean either. */
export const CURRENCY_PREFIX = { GTQ: "Q", USD: "US$" };

export const money = (value, moneda = "GTQ") =>
  `${CURRENCY_PREFIX[moneda] ?? moneda} ${value.toLocaleString("es-GT", {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  })}`;

/**
 * Monthly review, scheduled by EventBridge on the 2nd of each month (the extra
 * day lets late loads of the last day arrive). Only notifies when something
 * actually needs attention.
 */
export const handler = async (_event, _context, now = new Date()) => {
  const threshold = dropThreshold();
  const months = comparisonMonths(now);
  const rows = await runQuery(buildQuery(required("ATHENA_DATABASE"), months));
  const { mes } = months;

  if (rows.length === 0) {
    console.log(JSON.stringify({ message: "No data available for comparison", mes }));
    return { alerted: false, reason: "no-data", mes };
  }

  const drops = rows.filter((row) => row.variacion !== null && row.variacion <= -threshold);

  if (drops.length === 0) {
    console.log(
      JSON.stringify({ message: "No regions below threshold", mes, reviewed: rows.length }),
    );
    return { alerted: false, reviewed: rows.length, mes };
  }

  const lines = drops.map(
    (row) =>
      `• ${row.region} (${row.moneda}): ${row.variacion}%  (${money(row.actual, row.moneda)} vs ${money(row.previo, row.moneda)} el mes previo)`,
  );

  const growth = rows
    .filter((row) => row.variacion !== null && row.variacion > 0)
    .sort((a, b) => b.variacion - a.variacion)
    .slice(0, 2)
    .map((row) => `• ${row.region} (${row.moneda}): +${row.variacion}%`);

  const body = [
    `Caídas de facturación detectadas en ${mes}`,
    "",
    `Regiones por debajo de -${threshold}% frente al mes anterior:`,
    ...lines,
    "",
    ...(growth.length > 0 ? ["En crecimiento:", ...growth, ""] : []),
    `Revisa el detalle: ${process.env.APP_URL ?? ""}`,
    "",
    "Métrica: facturación total con IVA por moneda (GTQ y USD por separado, sin conversión), solo documentos emitidos, mes calendario completo (hora de Guatemala).",
  ].join("\n");

  await sns.send(
    new PublishCommand({
      TopicArn: required("ALERTS_TOPIC_ARN"),
      Subject: `Ventas Inteligentes: ${drops.length} región(es) con caída en ${mes}`.slice(0, 99),
      Message: body,
    }),
  );

  console.log(JSON.stringify({ message: "Alert published", mes, drops: drops.length }));
  return { alerted: true, drops: drops.length, mes };
};
