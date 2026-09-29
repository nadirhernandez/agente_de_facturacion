locals {
  project_name         = "dashboards-dinamicos"
  environment          = "dev"
  data_bucket_name     = "dashboards-dinamicos-dev-${local.account_id}"
  glue_database_name   = "sales_demo"
  athena_workgroup     = "dashboards-dinamicos-dev"
  glue_job_name        = "dashboards-dinamicos-flatten-invoices-dev"
  raw_invoices_key     = "raw/dte/country=gt/ingest_date=2026-09-24/facturas_demo.jsonl"
  glue_script_key      = "scripts/glue/flatten_invoices.py"
  curated_sales_prefix = "curated/ventas_lineas/"

  # Iceberg tables of the model (sql/model/tables). Under curated/ so the
  # existing QuickSight and automation read permissions already cover them.
  iceberg_warehouse = "s3://${local.data_bucket_name}/curated/iceberg"
}

resource "aws_s3_bucket" "data" {
  bucket        = local.data_bucket_name
  force_destroy = false
}

resource "aws_s3_bucket_public_access_block" "data" {
  bucket                  = aws_s3_bucket.data.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "data" {
  bucket = aws_s3_bucket.data.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "data" {
  bucket = aws_s3_bucket.data.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_ownership_controls" "data" {
  bucket = aws_s3_bucket.data.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# The bucket holds customer names and NITs: plain HTTP is always refused.
data "aws_iam_policy_document" "data_bucket" {
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.data.arn,
      "${aws_s3_bucket.data.arn}/*",
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "data" {
  bucket = aws_s3_bucket.data.id
  policy = data.aws_iam_policy_document.data_bucket.json

  depends_on = [aws_s3_bucket_public_access_block.data]
}

/**
 * Scratch prefixes expire; old versions are kept 90 days for recovery. Iceberg
 * only reads current objects, so expiring noncurrent versions is safe.
 * raw/ and curated/ current objects are never expired.
 */
resource "aws_s3_bucket_lifecycle_configuration" "data" {
  bucket = aws_s3_bucket.data.id

  rule {
    id     = "athena-results"
    status = "Enabled"
    filter {
      prefix = "athena-results/"
    }
    expiration {
      days = 30
    }
  }

  rule {
    id     = "glue-temp"
    status = "Enabled"
    filter {
      prefix = "glue-temp/"
    }
    expiration {
      days = 7
    }
  }

  rule {
    id     = "noncurrent-versions"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = 90
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.data]
}

resource "aws_s3_object" "raw_invoices" {
  bucket       = aws_s3_bucket.data.id
  key          = local.raw_invoices_key
  source       = "../../data/raw/facturas_demo.jsonl"
  etag         = filemd5("../../data/raw/facturas_demo.jsonl")
  content_type = "application/x-ndjson"
}

resource "aws_s3_object" "glue_script" {
  bucket       = aws_s3_bucket.data.id
  key          = local.glue_script_key
  source       = "../../etl/glue/flatten_invoices.py"
  etag         = filemd5("../../etl/glue/flatten_invoices.py")
  content_type = "text/x-python"
}

resource "aws_glue_catalog_database" "sales" {
  name        = local.glue_database_name
  description = "Modelo analítico de ventas para el MLP de facturación."
}

resource "aws_athena_workgroup" "sales" {
  name  = local.athena_workgroup
  state = "ENABLED"

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true
    # Cost brake: 10 GB per query. The whole model is a few MB today.
    bytes_scanned_cutoff_per_query = 10737418240

    result_configuration {
      output_location       = "s3://${aws_s3_bucket.data.bucket}/athena-results/"
      expected_bucket_owner = local.quicksight_account_id

      encryption_configuration {
        encryption_option = "SSE_S3"
      }
    }
  }
}

resource "aws_iam_role" "glue_etl" {
  name = "dashboards-dinamicos-glue-etl-dev"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "glue.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

/**
 * Least-privilege replacement for the AWSGlueServiceRole managed policy, which
 * grants glue:* and s3 on every aws-glue-* bucket of the account. The job only
 * needs its own database, its bucket prefixes, its logs and its metrics.
 */
resource "aws_iam_role_policy" "glue_data_access" {
  name = "dashboards-dinamicos-glue-data-access-dev"
  role = aws_iam_role.glue_etl.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ListProjectDataBucket"
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
        Resource = aws_s3_bucket.data.arn
      },
      {
        # Source files and the job script are read, never modified.
        Sid    = "ReadSources"
        Effect = "Allow"
        Action = ["s3:GetObject"]
        Resource = [
          "${aws_s3_bucket.data.arn}/raw/*",
          "${aws_s3_bucket.data.arn}/scripts/glue/*",
        ]
      },
      {
        Sid    = "WriteModelAndScratch"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload"]
        Resource = [
          "${aws_s3_bucket.data.arn}/curated/iceberg/*",
          "${aws_s3_bucket.data.arn}/glue-temp/*",
          "${aws_s3_bucket.data.arn}/quarantine/*",
        ]
      },
      {
        Sid    = "IcebergCatalog"
        Effect = "Allow"
        Action = [
          "glue:GetDatabase", "glue:GetDatabases",
          "glue:GetTable", "glue:GetTables", "glue:UpdateTable",
          "glue:GetPartition", "glue:GetPartitions", "glue:BatchGetPartition",
          "glue:GetUserDefinedFunctions",
        ]
        Resource = [
          "${local.arn_glue}:catalog",
          "${local.arn_glue}:database/default",
          "${local.arn_glue}:database/${aws_glue_catalog_database.sales.name}",
          "${local.arn_glue}:table/${aws_glue_catalog_database.sales.name}/*",
          "${local.arn_glue}:userDefinedFunction/${aws_glue_catalog_database.sales.name}/*",
        ]
      },
      {
        Sid    = "JobLogs"
        Effect = "Allow"
        Action = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = [
          "${local.arn_logs}:log-group:/aws-glue/*",
          "${local.arn_logs}:log-group:/dashboards-dinamicos/dev/glue*",
        ]
      },
      {
        Sid       = "JobMetrics"
        Effect    = "Allow"
        Action    = ["cloudwatch:PutMetricData"]
        Resource  = "*"
        Condition = { StringEquals = { "cloudwatch:namespace" = "Glue" } }
      },
    ]
  })
}

resource "aws_glue_job" "flatten_invoices" {
  name              = local.glue_job_name
  role_arn          = aws_iam_role.glue_etl.arn
  glue_version      = "5.0"
  worker_type       = "G.1X"
  number_of_workers = 2
  max_retries       = 0
  # Glue's default is 48 hours; a hung run would bill all of it. Failures are
  # reported by glue_job_failed (observability.tf).
  timeout = 60

  command {
    name            = "glueetl"
    script_location = "s3://${aws_s3_bucket.data.bucket}/${aws_s3_object.glue_script.key}"
    python_version  = "3"
  }

  default_arguments = {
    "--enable-metrics"         = "true"
    "--custom-logGroup-prefix" = "/dashboards-dinamicos/dev/glue"
    "--job-language"           = "python"
    "--TempDir"                = "s3://${aws_s3_bucket.data.bucket}/glue-temp/"
    "--datalake-formats"       = "iceberg"
    "--SOURCE_PATH"            = "s3://${aws_s3_bucket.data.bucket}/raw/dte/"
    "--DATABASE"               = aws_glue_catalog_database.sales.name
    "--WAREHOUSE"              = local.iceberg_warehouse
    "--REPROCESS_ALL"          = "false"
    "--QUARANTINE_PATH"        = "s3://${aws_s3_bucket.data.bucket}/quarantine/"
  }

  # Two concurrent MERGE runs over the same days would conflict.
  execution_property {
    max_concurrent_runs = 1
  }

  depends_on = [
    aws_iam_role_policy.glue_data_access,
    aws_s3_object.glue_script,
    aws_s3_object.raw_invoices
  ]
}

# LEGACY, pending removal. The pre-Iceberg Parquet table. Nothing reads it and
# the Glue job no longer writes it; it stays only as the rollback path of the
# Iceberg migration (docs/HANDOFF.md). The model now lives in sql/model.
resource "aws_glue_catalog_table" "sales_lines" {
  name          = "ventas_lineas"
  database_name = aws_glue_catalog_database.sales.name
  table_type    = "EXTERNAL_TABLE"

  parameters = {
    "EXTERNAL"                  = "TRUE"
    "classification"            = "parquet"
    "projection.enabled"        = "true"
    "projection.country.type"   = "enum"
    "projection.country.values" = "gt"
    "projection.anio.type"      = "integer"
    "projection.anio.range"     = "2025,2030"
    "projection.mes.type"       = "integer"
    "projection.mes.range"      = "1,12"
    "storage.location.template" = "s3://${aws_s3_bucket.data.bucket}/${local.curated_sales_prefix}country=$${country}/anio=$${anio}/mes=$${mes}/"
  }

  storage_descriptor {
    location      = "s3://${aws_s3_bucket.data.bucket}/${local.curated_sales_prefix}"
    input_format  = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat"

    ser_de_info {
      serialization_library = "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe"
    }

    columns {
      name = "doc_id"
      type = "string"
    }
    columns {
      name = "fecha_emision"
      type = "timestamp"
    }
    columns {
      name = "fecha"
      type = "date"
    }
    columns {
      name = "dia"
      type = "int"
    }
    columns {
      name = "estado"
      type = "string"
    }
    columns {
      name = "codigo_moneda"
      type = "string"
    }
    columns {
      name = "serie"
      type = "string"
    }
    columns {
      name = "nit_receptor"
      type = "string"
    }
    columns {
      name = "cliente"
      type = "string"
    }
    columns {
      name = "establecimiento_codigo"
      type = "string"
    }
    columns {
      name = "establecimiento"
      type = "string"
    }
    columns {
      name = "departamento"
      type = "string"
    }
    columns {
      name = "municipio"
      type = "string"
    }
    columns {
      name = "canal"
      type = "string"
    }
    columns {
      name = "gran_total_documento"
      type = "decimal(12,2)"
    }
    columns {
      name = "linea"
      type = "int"
    }
    columns {
      name = "codigo_producto"
      type = "string"
    }
    columns {
      name = "producto"
      type = "string"
    }
    columns {
      name = "categoria"
      type = "string"
    }
    columns {
      name = "cantidad"
      type = "int"
    }
    columns {
      name = "precio_unitario"
      type = "decimal(12,2)"
    }
    columns {
      name = "facturacion_total_linea"
      type = "decimal(12,2)"
    }
    columns {
      name = "ventas_sin_iva_linea"
      type = "decimal(12,2)"
    }
    columns {
      name = "iva_linea"
      type = "decimal(12,2)"
    }
    # Lineage columns written by the Glue job. source_file is what makes the
    # incremental load safe when many files share one ingest_date.
    columns {
      name = "ingest_date"
      type = "string"
    }
    columns {
      name = "source_file"
      type = "string"
    }
  }

  partition_keys {
    name = "country"
    type = "string"
  }
  partition_keys {
    name = "anio"
    type = "int"
  }
  partition_keys {
    name = "mes"
    type = "int"
  }
}
