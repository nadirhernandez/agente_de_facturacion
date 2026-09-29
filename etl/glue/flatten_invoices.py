"""Load Guatemalan DTE invoices into the Iceberg sales model.

Tables (defined only in sql/model/tables and created by the model deployer):
  fct_lineas_factura       one row per invoice line, partitioned by day(fecha)
  ctl_archivos_procesados  one row per raw file already loaded
  agg_ventas_diario        daily totals of issued documents

Each run:
  1. Lists the raw files and keeps those not yet in ctl_archivos_procesados.
     Only those files are read: the cost follows the new data, not the history.
  2. Reads them with an explicit schema. Records that cannot be trusted (not
     valid JSON, no doc_id, unparseable date, unknown estado, a line without
     number or amount) go to the quarantine prefix instead of the model, and an
     EventBridge rule on that prefix alerts the team.
  3. MERGE into fct_lineas_factura by (doc_id, linea). A re-sent DTE replaces
     its lines instead of duplicating them; the most recent ingest wins.
  4. Recomputes agg_ventas_diario for every day the batch touched, including a
     day a line moved away from.
  5. Records the files, with this run's id and the days they touched, so the
     SPICE refresh can decide between incremental and full.

Business date: Guatemala is UTC-06:00 all year (no daylight saving). fecha is
the civil date of issue at UTC-06:00 and fecha_emision is the local wall-clock
time. An invoice issued at 19:30 local belongs to that day, not the next one
(which is what a UTC session produced before).

Idempotent: if a run dies between steps, the next one reprocesses the same files
and every MERGE converges to the same result.

--REPROCESS_ALL true reloads every raw file (the control table is ignored) and
matches lines on (doc_id, linea) across the whole table, so a line whose date
changed (for example after the UTC-06:00 correction) moves to its right day
instead of being duplicated. Incremental runs match only within the batch days,
which is what keeps them cheap; a re-sent DTE keeps its emission date.

Note: this script never calls sys.exit(). Glue reports a SystemExit as a failed
run, which would both mislead operators and break the EventBridge chain that
refreshes SPICE on success.
"""

import json
import sys
import time
from urllib.parse import urlparse

import boto3
from awsglue.utils import getResolvedOptions
from pyspark.sql import SparkSession, Window
from pyspark.sql import functions as F
from pyspark.sql.types import (
    ArrayType,
    DecimalType,
    IntegerType,
    StringType,
    StructField,
    StructType,
)

CATALOG = "lake"

# Guatemala: UTC-06:00, no daylight saving time.
BUSINESS_UTC_OFFSET = "-06:00"

VALID_ESTADOS = ("emitido", "anulado")

PRODUCT_CATEGORIES = {
    "Accesorios": ["PROD-004", "PROD-005"],
    "Servicios": ["PROD-006", "PROD-007"],
    "Corporativo": ["PROD-008", "PROD-012"],
    "Suscripciones": ["PROD-009"],
}

MONEY = DecimalType(12, 2)

# Only the fields the model uses. Amounts are read as decimals straight from the
# JSON text, so no binary floating point rounding ever touches a quetzal.
TAX_SCHEMA = StructType(
    [
        StructField("nombre_corto", StringType()),
        StructField("monto_gravable", MONEY),
        StructField("monto_impuesto", MONEY),
    ]
)

ITEM_SCHEMA = StructType(
    [
        StructField("linea", IntegerType()),
        StructField("codigo_producto", StringType()),
        StructField("descripcion", StringType()),
        StructField("cantidad", IntegerType()),
        StructField("precio_unitario", MONEY),
        StructField("monto", MONEY),
        StructField("impuestos", ArrayType(TAX_SCHEMA)),
    ]
)

RAW_SCHEMA = StructType(
    [
        StructField("doc_id", StringType()),
        StructField("country", StringType()),
        StructField("fecha_emision", StringType()),
        StructField("estado", StringType()),
        StructField("codigo_moneda", StringType()),
        StructField("serie", StringType()),
        StructField("nit_receptor", StringType()),
        StructField("nombre_receptor", StringType()),
        StructField("establecimiento_codigo", StringType()),
        StructField("establecimiento_nombre", StringType()),
        StructField("departamento", StringType()),
        StructField("municipio", StringType()),
        StructField("gran_total", MONEY),
        StructField("items", ArrayType(ITEM_SCHEMA)),
        StructField("_corrupt_record", StringType()),
    ]
)

# Column order and types of fct_lineas_factura (sql/model/tables/10_*.sql).
# MERGE ... UPDATE SET * / INSERT * matches by name, so the batch is cast to
# exactly this shape before it touches the table.
FCT_COLUMNS = [
    ("doc_id", "string"),
    ("fecha_emision", "timestamp_ntz"),
    ("fecha", "date"),
    ("dia", "int"),
    ("estado", "string"),
    ("codigo_moneda", "string"),
    ("serie", "string"),
    ("nit_receptor", "string"),
    ("cliente", "string"),
    ("establecimiento_codigo", "string"),
    ("establecimiento", "string"),
    ("departamento", "string"),
    ("municipio", "string"),
    ("canal", "string"),
    ("gran_total_documento", "decimal(12,2)"),
    ("linea", "int"),
    ("codigo_producto", "string"),
    ("producto", "string"),
    ("categoria", "string"),
    ("cantidad", "int"),
    ("precio_unitario", "decimal(12,2)"),
    ("facturacion_total_linea", "decimal(12,2)"),
    ("ventas_sin_iva_linea", "decimal(12,2)"),
    ("iva_linea", "decimal(12,2)"),
    ("ingest_date", "string"),
    ("source_file", "string"),
    ("country", "string"),
    ("anio", "int"),
    ("mes", "int"),
]

INGEST_DATE_PATTERN = r"ingest_date=([0-9]{4}-[0-9]{2}-[0-9]{2})"

# Re-list passes per run for files that arrive while the job is busy.
MAX_PASSES = 5


def log(event: str, **fields) -> None:
    """One JSON line per event, searchable in CloudWatch Logs Insights."""
    print(json.dumps({"event": event, **fields}, default=str))


def job_run_id() -> str:
    """Glue passes --JOB_RUN_ID; a manual run without it is recorded as such."""
    for index, argument in enumerate(sys.argv):
        if argument == "--JOB_RUN_ID" and index + 1 < len(sys.argv):
            return sys.argv[index + 1]
        if argument.startswith("--JOB_RUN_ID="):
            return argument.split("=", 1)[1]
    return "manual"


def optional_arg(name: str, default: str) -> str:
    """getResolvedOptions fails on a missing argument; this one is optional."""
    flag = f"--{name}"
    if flag in sys.argv:
        return getResolvedOptions(sys.argv, [name])[name]
    return default


def list_raw_files(source_path: str) -> list[str]:
    """Every JSON file under the raw prefix, as s3:// URIs."""
    parsed = urlparse(source_path)
    bucket, prefix = parsed.netloc, parsed.path.lstrip("/")
    paginator = boto3.client("s3").get_paginator("list_objects_v2")
    files = []
    for page in paginator.paginate(Bucket=bucket, Prefix=prefix):
        for item in page.get("Contents", []):
            key = item["Key"]
            if key.endswith((".json", ".jsonl")) and item["Size"] > 0:
                files.append(f"s3://{bucket}/{key}")
    return sorted(files)


def publish_quarantine_notice(quarantine_path, run_id, count, reasons, files, target) -> None:
    """One small object per quarantine event under _avisos/.

    An EventBridge rule on that prefix alerts the team. Spark's own output
    (part files, _temporary, _SUCCESS) is never watched, so one bad batch
    produces exactly one alert.
    """
    parsed = urlparse(quarantine_path)
    prefix = parsed.path.strip("/")
    key = f"{prefix}/_avisos/run={run_id}-{int(time.time())}.json"
    body = {
        "run": run_id,
        "rechazados": count,
        "motivos": reasons,
        "archivos": files[:50],
        "detalle": target,
    }
    boto3.client("s3").put_object(
        Bucket=parsed.netloc,
        Key=key,
        Body=json.dumps(body, ensure_ascii=False, default=str).encode("utf-8"),
        ContentType="application/json",
    )


def with_business_dates(invoices):
    """Parses fecha_emision (ISO 8601 with offset) into the UTC-06:00 business date.

    The Spark session runs at UTC-06:00, so to_timestamp() yields the instant and
    both the date and the wall-clock time are read in Guatemala time.
    """
    emitted = F.to_timestamp("fecha_emision")
    return (
        invoices.withColumn("_emitido_en", emitted)
        .withColumn("fecha", F.to_date(emitted))
        .withColumn("fecha_emision_local", emitted.cast("timestamp_ntz"))
    )


def split_valid(invoices):
    """(valid documents, rejected documents with a reason)."""
    reason = (
        F.when(F.col("_corrupt_record").isNotNull(), F.lit("json_invalido"))
        .when(F.col("doc_id").isNull() | (F.trim("doc_id") == ""), F.lit("sin_doc_id"))
        .when(F.col("_emitido_en").isNull(), F.lit("fecha_emision_invalida"))
        .when(~F.lower("estado").isin(*VALID_ESTADOS) | F.col("estado").isNull(), F.lit("estado_desconocido"))
        .when(F.col("items").isNull() | (F.size("items") == 0), F.lit("sin_lineas"))
    )
    tagged = invoices.withColumn("_rechazo", reason)
    return (
        tagged.filter(F.col("_rechazo").isNull()).drop("_rechazo"),
        tagged.filter(F.col("_rechazo").isNotNull()),
    )


def build_sales_lines(invoices):
    """Explode invoice items into one row per sold line."""
    items = invoices.select(
        "doc_id",
        "fecha_emision_local",
        "fecha",
        F.lower("estado").alias("estado"),
        "country",
        "codigo_moneda",
        "serie",
        "nit_receptor",
        "nombre_receptor",
        "establecimiento_codigo",
        "establecimiento_nombre",
        "departamento",
        "municipio",
        "gran_total",
        "ingest_date",
        "source_file",
        F.explode("items").alias("item"),
    )

    # TODO: replace with a product dimension join once the ERP exposes categories.
    categoria = F.lit("Alimentos")
    for name, codes in PRODUCT_CATEGORIES.items():
        categoria = F.when(F.col("item.codigo_producto").isin(codes), F.lit(name)).otherwise(categoria)

    lines = items.select(
        "doc_id",
        F.col("fecha_emision_local").alias("fecha_emision"),
        "fecha",
        # Calendar parts come from the business date, never from the source's
        # own anio/mes/dia fields, so the three can never disagree.
        F.dayofmonth("fecha").alias("dia"),
        "estado",
        "codigo_moneda",
        "serie",
        "nit_receptor",
        F.col("nombre_receptor").alias("cliente"),
        "establecimiento_codigo",
        F.col("establecimiento_nombre").alias("establecimiento"),
        "departamento",
        "municipio",
        F.when(F.col("establecimiento_codigo") == "4", F.lit("Canal corporativo"))
        .otherwise(F.lit("Canal tienda"))
        .alias("canal"),
        F.col("gran_total").alias("gran_total_documento"),
        F.col("item.linea").alias("linea"),
        F.col("item.codigo_producto").alias("codigo_producto"),
        F.col("item.descripcion").alias("producto"),
        categoria.alias("categoria"),
        F.col("item.cantidad").alias("cantidad"),
        F.col("item.precio_unitario").alias("precio_unitario"),
        F.col("item.monto").alias("facturacion_total_linea"),
        F.col("item.impuestos")[0]["monto_gravable"].alias("ventas_sin_iva_linea"),
        F.col("item.impuestos")[0]["monto_impuesto"].alias("iva_linea"),
        "ingest_date",
        "source_file",
        "country",
        F.year("fecha").alias("anio"),
        F.month("fecha").alias("mes"),
    )

    return lines.select([F.col(name).cast(kind).alias(name) for name, kind in FCT_COLUMNS])


def split_valid_lines(lines):
    """A line without number or amount cannot be merged or summed."""
    reason = F.when(F.col("linea").isNull(), F.lit("linea_sin_numero")).when(
        F.col("facturacion_total_linea").isNull(), F.lit("linea_sin_monto")
    )
    tagged = lines.withColumn("_rechazo", reason)
    return (
        tagged.filter(F.col("_rechazo").isNull()).drop("_rechazo"),
        tagged.filter(F.col("_rechazo").isNotNull()),
    )


def date_literals(dates) -> str:
    return ", ".join(f"DATE '{day.isoformat()}'" for day in dates)


def load_files(spark, pending, *, run_id, fct, ctl, agg, reprocess_all, quarantine_path) -> dict:
    """Loads one set of raw files end to end and records them. Returns counters."""
    raw = (
        spark.read.schema(RAW_SCHEMA)
        .option("mode", "PERMISSIVE")
        .option("columnNameOfCorruptRecord", "_corrupt_record")
        .json(pending)
        # _metadata.file_path is deterministic; input_file_name() is not, and
        # MERGE refuses non-deterministic expressions.
        .withColumn("source_file", F.col("_metadata.file_path"))
        .withColumn("ingest_date", F.regexp_extract("source_file", INGEST_DATE_PATTERN, 1))
        .withColumn(
            "ingest_date",
            F.when(F.col("ingest_date") == "", F.lit(None).cast("string")).otherwise(F.col("ingest_date")),
        )
    )
    invoices_all = with_business_dates(raw).cache()

    invoices, rejected_docs = split_valid(invoices_all)
    lines_all = build_sales_lines(invoices)
    lines, rejected_lines = split_valid_lines(lines_all)

    # One row per (doc_id, linea) inside the batch, preferring the latest ingest.
    latest = Window.partitionBy("doc_id", "linea").orderBy(
        F.col("ingest_date").desc_nulls_last(), F.col("source_file").desc_nulls_last()
    )
    batch = lines.withColumn("_rank", F.row_number().over(latest)).filter("_rank = 1").drop("_rank").cache()

    # --- Quarantine ------------------------------------------------------------
    rejected = (
        rejected_docs.select(
            "source_file",
            "_rechazo",
            "doc_id",
            F.coalesce("_corrupt_record", F.to_json(F.struct("doc_id", "fecha_emision", "estado"))).alias(
                "registro"
            ),
        )
        .unionByName(
            rejected_lines.select(
                "source_file",
                "_rechazo",
                "doc_id",
                F.to_json(F.struct("doc_id", "linea", "codigo_producto")).alias("registro"),
            )
        )
        .cache()
    )
    rejected_count = rejected.count()
    if rejected_count:
        target = f"{quarantine_path}/run={run_id}/"
        rejected.coalesce(1).write.mode("append").json(target)
        reasons = {
            row["_rechazo"]: row["n"]
            for row in rejected.groupBy("_rechazo").agg(F.count("*").alias("n")).collect()
        }
        bad_files = sorted(
            {row["source_file"] for row in rejected.select("source_file").distinct().collect()}
        )
        log("records_quarantined", run=run_id, count=rejected_count, reasons=reasons, path=target)
        publish_quarantine_notice(quarantine_path, run_id, rejected_count, reasons, bad_files, target)

    # --- Fact table ----------------------------------------------------------
    new_dates = sorted(row["fecha"] for row in batch.select("fecha").distinct().collect())
    batch.createOrReplaceTempView("lote")

    # Days a matched line currently sits on. A line that moves day (after the
    # UTC-06:00 correction or a corrected emission date) must also refresh the
    # total of the day it leaves.
    if reprocess_all:
        previous_dates = [
            row["fecha"]
            for row in spark.sql(f"""
                SELECT DISTINCT t.fecha FROM {fct} t
                JOIN lote s ON t.doc_id = s.doc_id AND t.linea = s.linea
            """).collect()
        ]
    else:
        previous_dates = []

    touched_dates = sorted(set(new_dates) | set(previous_dates))

    if new_dates:
        # Incremental: the literal date list limits the MERGE to the batch days
        # instead of scanning the whole table. Reprocess: match everywhere so
        # a line that changed day is updated, not duplicated.
        date_scope = "" if reprocess_all else f"t.fecha IN ({date_literals(new_dates)}) AND "
        spark.sql(f"""
            MERGE INTO {fct} t
            USING lote s
            ON {date_scope}t.doc_id = s.doc_id AND t.linea = s.linea
            WHEN MATCHED AND (
                t.ingest_date IS NULL
                OR s.ingest_date > t.ingest_date
                OR (s.ingest_date = t.ingest_date AND s.source_file >= t.source_file)
            ) THEN UPDATE SET *
            WHEN NOT MATCHED THEN INSERT *
        """)

    # --- Daily aggregate -----------------------------------------------------
    if touched_dates:
        spark.createDataFrame([(day,) for day in touched_dates], "fecha date").createOrReplaceTempView(
            "dias_lote"
        )
        spark.sql(f"""
            MERGE INTO {agg} a
            USING (
                SELECT
                    d.fecha,
                    CAST(COALESCE(x.facturacion_total, 0) AS DECIMAL(18,2)) AS facturacion_total,
                    CAST(COALESCE(x.ventas_sin_iva, 0) AS DECIMAL(18,2))    AS ventas_sin_iva,
                    CAST(COALESCE(x.iva, 0) AS DECIMAL(18,2))               AS iva,
                    CAST(COALESCE(x.facturas, 0) AS BIGINT)                 AS facturas,
                    CAST(COALESCE(x.unidades, 0) AS BIGINT)                 AS unidades,
                    CAST(current_timestamp() AS TIMESTAMP_NTZ)              AS actualizado_en
                FROM dias_lote d
                LEFT JOIN (
                    SELECT
                        fecha,
                        sum(facturacion_total_linea) AS facturacion_total,
                        sum(ventas_sin_iva_linea)    AS ventas_sin_iva,
                        sum(iva_linea)               AS iva,
                        count(DISTINCT doc_id)       AS facturas,
                        sum(cantidad)                AS unidades
                    FROM {fct}
                    WHERE fecha IN (SELECT fecha FROM dias_lote) AND estado = 'emitido'
                    GROUP BY fecha
                ) x ON x.fecha = d.fecha
            ) s
            ON a.fecha = s.fecha
            WHEN MATCHED THEN UPDATE SET *
            WHEN NOT MATCHED THEN INSERT *
        """)

    # --- Control table -------------------------------------------------------
    # Every pending file is recorded, including one without valid lines, so it
    # is not read again on every run; its rejects are in quarantine.
    stats = (
        invoices.groupBy("source_file")
        .agg(
            F.count("*").alias("documentos"),
            F.min("fecha").alias("fecha_min_docs"),
            F.max("fecha").alias("fecha_max_docs"),
        )
        .join(lines.groupBy("source_file").agg(F.count("*").alias("lineas")), "source_file", "left")
    )
    # fecha_min drives the incremental-vs-full SPICE decision: on a reprocess it
    # must also cover the day a line moved away from.
    oldest_previous = min(previous_dates) if previous_dates else None
    fecha_min = (
        F.least(F.col("fecha_min_docs"), F.lit(oldest_previous))
        if oldest_previous
        else F.col("fecha_min_docs")
    )
    files = (
        spark.createDataFrame([(uri,) for uri in pending], "source_file string")
        .join(stats, "source_file", "left")
        .select(
            "source_file",
            F.regexp_extract("source_file", INGEST_DATE_PATTERN, 1).alias("ingest_date"),
            F.lit(run_id).alias("job_run_id"),
            F.coalesce("documentos", F.lit(0)).cast("bigint").alias("documentos"),
            F.coalesce("lineas", F.lit(0)).cast("bigint").alias("lineas"),
            fecha_min.cast("date").alias("fecha_min"),
            F.col("fecha_max_docs").cast("date").alias("fecha_max"),
            F.current_timestamp().cast("timestamp_ntz").alias("procesado_en"),
        )
    )
    files.createOrReplaceTempView("archivos_lote")
    spark.sql(f"""
        MERGE INTO {ctl} c
        USING archivos_lote s
        ON c.source_file = s.source_file
        WHEN MATCHED THEN UPDATE SET *
        WHEN NOT MATCHED THEN INSERT *
    """)

    merged = batch.count()
    log(
        "run_finished",
        run=run_id,
        lines_merged=merged,
        days_touched=len(touched_dates),
        files_recorded=len(pending),
        quarantined=rejected_count,
    )

    for frame in (batch, rejected, invoices_all):
        frame.unpersist()

    return {"lines_merged": merged, "days_touched": len(touched_dates), "quarantined": rejected_count}


def main() -> None:
    args = getResolvedOptions(sys.argv, ["JOB_NAME", "SOURCE_PATH", "DATABASE", "WAREHOUSE", "REPROCESS_ALL"])
    run_id = job_run_id()
    database = args["DATABASE"]
    fct = f"{CATALOG}.{database}.fct_lineas_factura"
    ctl = f"{CATALOG}.{database}.ctl_archivos_procesados"
    agg = f"{CATALOG}.{database}.agg_ventas_diario"

    source = urlparse(args["SOURCE_PATH"])
    quarantine_path = optional_arg("QUARANTINE_PATH", f"s3://{source.netloc}/quarantine/").rstrip("/")

    spark = (
        SparkSession.builder.config(
            "spark.sql.extensions", "org.apache.iceberg.spark.extensions.IcebergSparkSessionExtensions"
        )
        .config(f"spark.sql.catalog.{CATALOG}", "org.apache.iceberg.spark.SparkCatalog")
        .config(f"spark.sql.catalog.{CATALOG}.type", "glue")
        .config(f"spark.sql.catalog.{CATALOG}.warehouse", args["WAREHOUSE"])
        # Every date and wall-clock time in the model is Guatemala time.
        .config("spark.sql.session.timeZone", BUSINESS_UTC_OFFSET)
        .getOrCreate()
    )

    # The model deployer owns the schema. A missing table is a deployment
    # problem, and failing loudly here is the right outcome.
    for table in (fct, ctl, agg):
        if not spark.catalog.tableExists(table):
            raise RuntimeError(f"{table} does not exist; deploy the model from sql/model first")

    reprocess_all = str(args["REPROCESS_ALL"]).strip().lower() in {"true", "1", "yes"}
    listed = list_raw_files(args["SOURCE_PATH"])

    if reprocess_all:
        pending = listed
    else:
        processed = {row["source_file"] for row in spark.table(ctl).select("source_file").collect()}
        pending = [uri for uri in listed if uri not in processed]

    log("run_started", run=run_id, listed=len(listed), pending=len(pending), reprocess_all=reprocess_all)
    if not pending:
        log("nothing_to_do", run=run_id)
        return

    passes = 0
    totals = {"lines_merged": 0, "days_touched": 0, "quarantined": 0, "files": 0}
    # Everything listed at start is either already loaded or in this batch.
    seen = set(listed)
    while pending:
        passes += 1
        result = load_files(
            spark,
            pending,
            run_id=run_id,
            fct=fct,
            ctl=ctl,
            agg=agg,
            reprocess_all=reprocess_all and passes == 1,
            quarantine_path=quarantine_path,
        )
        for key, value in result.items():
            totals[key] += value
        totals["files"] += len(pending)

        # Files that landed while this run was busy: their own event was
        # rejected by max_concurrent_runs = 1, so this run picks them up.
        if passes >= MAX_PASSES:
            break
        arrived = [uri for uri in list_raw_files(args["SOURCE_PATH"]) if uri not in seen]
        seen.update(arrived)
        pending = arrived
        if pending:
            log("late_files_found", run=run_id, count=len(pending), pass_number=passes + 1)

    log("run_summary", run=run_id, passes=passes, **totals)


main()
