"""Load Guatemalan DTE invoices into the Iceberg sales model.

Tables (defined only in sql/model/tables and created by the model deployer):
  fct_lineas_factura       one row per invoice line, partitioned by day(fecha)
  ctl_archivos_procesados  one row per raw file already loaded
  agg_ventas_diario        daily totals of issued documents

Each run:
  1. Lists the raw files and keeps those not yet in ctl_archivos_procesados.
     Only those files are read: the cost follows the new data, not the history.
  2. MERGE into fct_lineas_factura by (doc_id, linea). A re-sent DTE replaces
     its lines instead of duplicating them; the most recent ingest wins.
  3. Recomputes agg_ventas_diario only for the days the batch touched.
  4. Records the files, with this run's id and the days they touched, so the
     SPICE refresh can decide between incremental and full.

Idempotent: if a run dies between steps, the next one reprocesses the same files
and every MERGE converges to the same result.

Pass --REPROCESS_ALL true to reload every raw file (the control table is ignored).

Known behaviour, same as before Iceberg: a line is matched only within the days
of the batch. A re-sent DTE keeps its emission date, so this holds; a DTE whose
emission date changed would keep its old line on the old day.

Note: this script never calls sys.exit(). Glue reports a SystemExit as a failed
run, which would both mislead operators and break the EventBridge chain that
refreshes SPICE on success.
"""

import sys
from urllib.parse import urlparse

import boto3
from awsglue.utils import getResolvedOptions
from pyspark.sql import SparkSession, Window, functions as F

CATALOG = "lake"

PRODUCT_CATEGORIES = {
    "Accesorios": ["PROD-004", "PROD-005"],
    "Servicios": ["PROD-006", "PROD-007"],
    "Corporativo": ["PROD-008", "PROD-012"],
    "Suscripciones": ["PROD-009"],
}

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


def job_run_id() -> str:
    """Glue passes --JOB_RUN_ID; a manual run without it is recorded as such."""
    for index, argument in enumerate(sys.argv):
        if argument == "--JOB_RUN_ID" and index + 1 < len(sys.argv):
            return sys.argv[index + 1]
        if argument.startswith("--JOB_RUN_ID="):
            return argument.split("=", 1)[1]
    return "manual"


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


def build_sales_lines(invoices):
    """Explode invoice items into one row per sold line."""
    items = invoices.select(
        "doc_id",
        "fecha_emision",
        "anio",
        "mes",
        "dia",
        "estado",
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
        F.to_timestamp("fecha_emision").alias("fecha_emision"),
        F.to_date("fecha_emision").alias("fecha"),
        "dia",
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
        "anio",
        "mes",
    )

    return lines.select([F.col(name).cast(kind).alias(name) for name, kind in FCT_COLUMNS])


def date_literals(dates) -> str:
    return ", ".join(f"DATE '{day.isoformat()}'" for day in dates)


def main() -> None:
    args = getResolvedOptions(sys.argv, ["JOB_NAME", "SOURCE_PATH", "DATABASE", "WAREHOUSE", "REPROCESS_ALL"])
    run_id = job_run_id()
    database = args["DATABASE"]
    fct = f"{CATALOG}.{database}.fct_lineas_factura"
    ctl = f"{CATALOG}.{database}.ctl_archivos_procesados"
    agg = f"{CATALOG}.{database}.agg_ventas_diario"

    spark = (
        SparkSession.builder
        .config("spark.sql.extensions", "org.apache.iceberg.spark.extensions.IcebergSparkSessionExtensions")
        .config(f"spark.sql.catalog.{CATALOG}", "org.apache.iceberg.spark.SparkCatalog")
        .config(f"spark.sql.catalog.{CATALOG}.type", "glue")
        .config(f"spark.sql.catalog.{CATALOG}.warehouse", args["WAREHOUSE"])
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

    print(f"run {run_id}: {len(listed)} raw file(s), {len(pending)} to load")
    if not pending:
        print("Every raw file was already loaded; nothing to do.")
        return

    invoices = (
        spark.read.json(pending)
        # _metadata.file_path is deterministic; input_file_name() is not, and
        # MERGE refuses non-deterministic expressions.
        .withColumn("source_file", F.col("_metadata.file_path"))
        .withColumn(
            "ingest_date",
            F.regexp_extract(F.col("source_file"), r"ingest_date=([0-9]{4}-[0-9]{2}-[0-9]{2})", 1),
        )
        .cache()
    )

    lines = build_sales_lines(invoices).cache()

    # One row per (doc_id, linea) inside the batch, preferring the latest ingest.
    latest = Window.partitionBy("doc_id", "linea").orderBy(
        F.col("ingest_date").desc_nulls_last(), F.col("source_file").desc_nulls_last()
    )
    batch = lines.withColumn("_rank", F.row_number().over(latest)).filter("_rank = 1").drop("_rank")

    dates = sorted(row["fecha"] for row in batch.select("fecha").distinct().collect() if row["fecha"])

    if dates:
        batch.createOrReplaceTempView("lote")
        # The literal date list is what limits the MERGE to the days of the batch
        # instead of scanning the whole table for matches.
        spark.sql(f"""
            MERGE INTO {fct} t
            USING lote s
            ON t.fecha IN ({date_literals(dates)}) AND t.doc_id = s.doc_id AND t.linea = s.linea
            WHEN MATCHED AND (
                s.ingest_date > t.ingest_date
                OR (s.ingest_date = t.ingest_date AND s.source_file >= t.source_file)
            ) THEN UPDATE SET *
            WHEN NOT MATCHED THEN INSERT *
        """)

        spark.createDataFrame([(day,) for day in dates], "fecha date").createOrReplaceTempView("dias_lote")
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
                    WHERE fecha IN ({date_literals(dates)}) AND estado = 'emitido'
                    GROUP BY fecha
                ) x ON x.fecha = d.fecha
            ) s
            ON a.fecha = s.fecha
            WHEN MATCHED THEN UPDATE SET *
            WHEN NOT MATCHED THEN INSERT *
        """)

    # Every pending file is recorded, including one without lines, so it is not
    # read again on every run.
    stats = (
        invoices.groupBy("source_file")
        .agg(
            F.count("*").alias("documentos"),
            F.min(F.to_date("fecha_emision")).alias("fecha_min"),
            F.max(F.to_date("fecha_emision")).alias("fecha_max"),
        )
        .join(lines.groupBy("source_file").agg(F.count("*").alias("lineas")), "source_file", "left")
    )
    files = (
        spark.createDataFrame([(uri,) for uri in pending], "source_file string")
        .join(stats, "source_file", "left")
        .select(
            "source_file",
            F.regexp_extract("source_file", r"ingest_date=([0-9]{4}-[0-9]{2}-[0-9]{2})", 1).alias("ingest_date"),
            F.lit(run_id).alias("job_run_id"),
            F.coalesce("documentos", F.lit(0)).cast("bigint").alias("documentos"),
            F.coalesce("lineas", F.lit(0)).cast("bigint").alias("lineas"),
            F.col("fecha_min").cast("date").alias("fecha_min"),
            F.col("fecha_max").cast("date").alias("fecha_max"),
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

    print(
        f"run {run_id}: {batch.count()} line(s) merged over {len(dates)} day(s), "
        f"{len(pending)} file(s) recorded"
    )


main()
