import {
  AthenaClient,
  GetQueryExecutionCommand,
  GetQueryResultsCommand,
  StartQueryExecutionCommand,
} from "@aws-sdk/client-athena";
import { PublishCommand, SNSClient } from "@aws-sdk/client-sns";

const athena = new AthenaClient({});
const sns = new SNSClient({});

const required = (name) => {
  const value = process.env[name];
  if (!value) throw new Error(`Missing required environment variable: ${name}`);
  return value;
};

const DROP_THRESHOLD_PCT = Number(process.env.DROP_THRESHOLD_PCT ?? "10");

/**
 * Compares the last full month against the previous one, per region, using the
 * certified view. Reporting on the last *complete* month avoids false alarms
 * from a partially loaded current month.
 */
const QUERY = `
WITH periodos AS (
  SELECT
    date_trunc('month', max(fecha)) AS mes_actual,
    date_add('month', -1, date_trunc('month', max(fecha))) AS mes_previo
  FROM sales_demo.vw_ventas_comerciales
),
agregado AS (
  SELECT
    v.region,
    sum(CASE WHEN date_trunc('month', v.fecha) = p.mes_actual
             THEN v.facturacion_total_linea ELSE 0 END) AS actual,
    sum(CASE WHEN date_trunc('month', v.fecha) = p.mes_previo
             THEN v.facturacion_total_linea ELSE 0 END) AS previo
  FROM sales_demo.vw_ventas_comerciales v
  CROSS JOIN periodos p
  WHERE date_trunc('month', v.fecha) IN (p.mes_actual, p.mes_previo)
  GROUP BY v.region
)
SELECT
  region,
  round(actual, 2)  AS facturacion_actual,
  round(previo, 2)  AS facturacion_previa,
  round(CASE WHEN previo = 0 THEN 0 ELSE (actual - previo) / previo * 100 END, 1) AS variacion_pct,
  (SELECT format_datetime(mes_actual, 'yyyy-MM') FROM periodos) AS mes
FROM agregado
ORDER BY variacion_pct ASC
`;

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function runQuery() {
  const started = await athena.send(
    new StartQueryExecutionCommand({
      QueryString: QUERY,
      WorkGroup: required("ATHENA_WORKGROUP"),
      QueryExecutionContext: { Database: required("ATHENA_DATABASE") },
    }),
  );

  const id = started.QueryExecutionId;

  for (let attempt = 0; attempt < 30; attempt += 1) {
    await sleep(2000);
    const execution = await athena.send(new GetQueryExecutionCommand({ QueryExecutionId: id }));
    const state = execution.QueryExecution?.Status?.State;

    if (state === "SUCCEEDED") {
      const results = await athena.send(new GetQueryResultsCommand({ QueryExecutionId: id }));
      const [, ...rows] = results.ResultSet?.Rows ?? [];
      return rows.map((row) => {
        const [region, actual, previo, variacion, mes] = row.Data.map((cell) => cell.VarCharValue);
        return {
          region,
          actual: Number(actual),
          previo: Number(previo),
          variacion: Number(variacion),
          mes,
        };
      });
    }

    if (state === "FAILED" || state === "CANCELLED") {
      throw new Error(
        `Athena query ${state}: ${execution.QueryExecution?.Status?.StateChangeReason ?? "unknown"}`,
      );
    }
  }

  throw new Error("Athena query timed out");
}

const money = (value) =>
  `Q ${value.toLocaleString("es-GT", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;

/** Scheduled by EventBridge. Only notifies when something actually needs attention. */
export const handler = async () => {
  const rows = await runQuery();

  if (rows.length === 0) {
    console.log(JSON.stringify({ message: "No data available for comparison" }));
    return { alerted: false, reason: "no-data" };
  }

  const drops = rows.filter((row) => row.variacion <= -DROP_THRESHOLD_PCT);
  const mes = rows[0].mes;

  if (drops.length === 0) {
    console.log(JSON.stringify({ message: "No regions below threshold", mes, reviewed: rows.length }));
    return { alerted: false, reviewed: rows.length };
  }

  const lines = drops.map(
    (row) =>
      `• ${row.region}: ${row.variacion}%  (${money(row.actual)} vs ${money(row.previo)} el mes previo)`,
  );

  const growth = rows
    .filter((row) => row.variacion > 0)
    .slice(-2)
    .reverse()
    .map((row) => `• ${row.region}: +${row.variacion}%`);

  const body = [
    `Caídas de facturación detectadas en ${mes}`,
    "",
    `Regiones por debajo de -${DROP_THRESHOLD_PCT}% frente al mes anterior:`,
    ...lines,
    "",
    ...(growth.length > 0 ? ["En crecimiento:", ...growth, ""] : []),
    `Revisa el detalle: ${process.env.APP_URL ?? ""}`,
    "",
    "Métrica: facturación total con IVA, solo documentos emitidos.",
  ].join("\n");

  await sns.send(
    new PublishCommand({
      TopicArn: required("ALERTS_TOPIC_ARN"),
      Subject: `Ventas Inteligentes: ${drops.length} región(es) con caída en ${mes}`,
      Message: body,
    }),
  );

  console.log(JSON.stringify({ message: "Alert published", mes, drops: drops.length }));
  return { alerted: true, drops: drops.length };
};
