/**
 * Data layer for one tenant account.
 *
 * Everything is named from tenant_id so the same module can be applied to any
 * number of client accounts without collisions.
 */

terraform {
  required_version = ">= 1.16.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.60.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.7.1"
    }
  }
}

locals {
  prefix        = "vi-${var.tenant_id}-${var.environment}"
  data_bucket   = "vi-${var.tenant_id}-data-${var.account_id}"
  glue_database = "ventas_${replace(var.tenant_id, "-", "_")}"
  raw_prefix    = "raw/dte/"

  # Iceberg tables of the model. Their schema lives only in sql/model/tables;
  # the model deployer creates them, the Glue job only writes to them.
  iceberg_prefix    = "curated/iceberg/"
  iceberg_warehouse = "s3://${local.data_bucket}/curated/iceberg"

  tags = merge(
    {
      Project     = "ventas-inteligentes"
      Tenant      = var.tenant_id
      TenantName  = var.tenant_name
      Environment = var.environment
      ManagedBy   = "terraform"
    },
    var.tags,
  )
}

# --- Data lake -------------------------------------------------------------
resource "aws_s3_bucket" "data" {
  bucket        = local.data_bucket
  force_destroy = false
  tags          = local.tags
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
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_versioning" "data" {
  bucket = aws_s3_bucket.data.id

  versioning_configuration {
    status = "Enabled"
  }
}

# ACLs disabled: every object belongs to this account, whoever uploads it.
resource "aws_s3_bucket_ownership_controls" "data" {
  bucket = aws_s3_bucket.data.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
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

resource "aws_s3_bucket_notification" "data_events" {
  bucket      = aws_s3_bucket.data.id
  eventbridge = true
}

/**
 * Landing zone policy. The external delivery system may drop files into raw/
 * only, and objects must land owned by this account so the client keeps control
 * of their own data.
 */
data "aws_iam_policy_document" "data_bucket" {
  dynamic "statement" {
    for_each = length(var.data_writer_principals) > 0 ? [1] : []

    content {
      sid    = "AllowExternalDelivery"
      effect = "Allow"

      principals {
        type        = "AWS"
        identifiers = var.data_writer_principals
      }

      # BucketOwnerEnforced makes every object owned by this account, so no ACL
      # condition is needed (and PutObjectAcl is not granted).
      actions   = ["s3:PutObject"]
      resources = ["${aws_s3_bucket.data.arn}/${local.raw_prefix}*"]
    }
  }

  # ListBucket is a bucket-level action and never carries s3:x-amz-acl, so it
  # lives in its own statement, limited to the raw/ prefix.
  dynamic "statement" {
    for_each = length(var.data_writer_principals) > 0 ? [1] : []

    content {
      sid    = "AllowExternalDeliveryList"
      effect = "Allow"

      principals {
        type        = "AWS"
        identifiers = var.data_writer_principals
      }

      actions   = ["s3:ListBucket"]
      resources = [aws_s3_bucket.data.arn]

      condition {
        test     = "StringLike"
        variable = "s3:prefix"
        values   = ["${local.raw_prefix}*"]
      }
    }
  }

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

# --- Catalog and query -----------------------------------------------------
resource "aws_glue_catalog_database" "sales" {
  name        = local.glue_database
  description = "Modelo analítico de ventas de ${var.tenant_name}."
}

resource "aws_athena_workgroup" "sales" {
  name  = local.prefix
  state = "ENABLED"
  tags  = local.tags

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true
    # Cost brake: a runaway query (or chat follow-ups over the fact table) stops here.
    bytes_scanned_cutoff_per_query = var.athena_bytes_scanned_cutoff

    result_configuration {
      output_location       = "s3://${aws_s3_bucket.data.bucket}/athena-results/"
      expected_bucket_owner = var.account_id

      encryption_configuration {
        encryption_option = "SSE_S3"
      }
    }
  }
}

# No table is declared here. Tables and views come from sql/model and are
# deployed by the deploy-views Lambda (pipeline.tf), same as in the pilot.

# --- Transformation --------------------------------------------------------
resource "aws_s3_object" "glue_script" {
  bucket       = aws_s3_bucket.data.id
  key          = "scripts/glue/flatten_invoices.py"
  source       = "${path.module}/../../../../etl/glue/flatten_invoices.py"
  etag         = filemd5("${path.module}/../../../../etl/glue/flatten_invoices.py")
  content_type = "text/x-python"
}

resource "aws_iam_role" "glue_etl" {
  name = "${local.prefix}-glue-etl"
  tags = local.tags

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "glue.amazonaws.com" }
    }]
  })
}

/**
 * Least-privilege replacement for the AWSGlueServiceRole managed policy, which
 * grants glue:* and s3 on every aws-glue-* bucket of the account.
 */
resource "aws_iam_role_policy" "glue_data_access" {
  name = "${local.prefix}-glue-data"
  role = aws_iam_role.glue_etl.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ListDataBucket"
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
          "${aws_s3_bucket.data.arn}/${local.raw_prefix}*",
          "${aws_s3_bucket.data.arn}/scripts/glue/*",
        ]
      },
      {
        Sid    = "WriteModelAndScratch"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload"]
        Resource = [
          "${aws_s3_bucket.data.arn}/${local.iceberg_prefix}*",
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
          "arn:aws:glue:${var.region}:${var.account_id}:catalog",
          "arn:aws:glue:${var.region}:${var.account_id}:database/default",
          "arn:aws:glue:${var.region}:${var.account_id}:database/${aws_glue_catalog_database.sales.name}",
          "arn:aws:glue:${var.region}:${var.account_id}:table/${aws_glue_catalog_database.sales.name}/*",
          "arn:aws:glue:${var.region}:${var.account_id}:userDefinedFunction/${aws_glue_catalog_database.sales.name}/*",
        ]
      },
      {
        Sid    = "JobLogs"
        Effect = "Allow"
        Action = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = [
          "arn:aws:logs:${var.region}:${var.account_id}:log-group:/aws-glue/*",
          "arn:aws:logs:${var.region}:${var.account_id}:log-group:/ventas-inteligentes/${var.tenant_id}/glue*",
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
  name              = "${local.prefix}-flatten-invoices"
  role_arn          = aws_iam_role.glue_etl.arn
  glue_version      = "5.0"
  worker_type       = "G.1X"
  number_of_workers = var.glue_workers
  max_retries       = 0
  # Glue's default is 48 hours; a hung run would bill all of it. A failure is
  # reported by the glue_failed rule (observability.tf).
  timeout = var.glue_timeout_minutes
  tags    = local.tags

  command {
    name            = "glueetl"
    script_location = "s3://${aws_s3_bucket.data.bucket}/${aws_s3_object.glue_script.key}"
    python_version  = "3"
  }

  default_arguments = {
    "--enable-metrics"         = "true"
    "--custom-logGroup-prefix" = "/ventas-inteligentes/${var.tenant_id}/glue"
    "--job-language"           = "python"
    "--TempDir"                = "s3://${aws_s3_bucket.data.bucket}/glue-temp/"
    "--datalake-formats"       = "iceberg"
    "--SOURCE_PATH"            = "s3://${aws_s3_bucket.data.bucket}/${local.raw_prefix}"
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
  ]
}
