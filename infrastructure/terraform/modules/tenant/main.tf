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

      actions = [
        "s3:PutObject",
        "s3:PutObjectAcl",
        "s3:ListBucket",
        "s3:GetBucketLocation",
      ]

      resources = [
        aws_s3_bucket.data.arn,
        "${aws_s3_bucket.data.arn}/${local.raw_prefix}*",
      ]

      condition {
        test     = "StringEquals"
        variable = "s3:x-amz-acl"
        values   = ["bucket-owner-full-control"]
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

    result_configuration {
      output_location = "s3://${aws_s3_bucket.data.bucket}/athena-results/"

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

resource "aws_iam_role_policy_attachment" "glue_service" {
  role       = aws_iam_role.glue_etl.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

resource "aws_iam_role_policy" "glue_data_access" {
  name = "${local.prefix}-glue-data"
  role = aws_iam_role.glue_etl.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ListDataBucket"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = aws_s3_bucket.data.arn
      },
      {
        Sid      = "ReadWriteData"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = "${aws_s3_bucket.data.arn}/*"
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
  tags              = local.tags

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
  }

  # Two concurrent MERGE runs over the same days would conflict.
  execution_property {
    max_concurrent_runs = 1
  }

  depends_on = [
    aws_iam_role_policy_attachment.glue_service,
    aws_iam_role_policy.glue_data_access,
  ]
}
