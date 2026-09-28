/**
 * Everything that has to happen between "a JSON file lands" and "the client can
 * chat with their data", with no human in the loop:
 *
 *   raw/*.jsonl    -> EventBridge -> Lambda -> Glue (MERGE into Iceberg)
 *   Glue SUCCEEDED -> EventBridge -> deploy-views (sql/model) -> refresh-spice
 *   weekly schedule -> Lambda -> Athena -> SNS alert
 *
 * deploy-views runs first and hands off to refresh-spice, so SPICE never reads
 * a view that is being replaced. refresh-spice picks incremental or full from
 * the dates the load actually wrote.
 *
 * Log groups live in observability.tf with skip_destroy: an organization SCP
 * forbids deleting them, so a destroy only forgets them.
 */

data "archive_file" "pipeline" {
  type        = "zip"
  source_dir  = "${path.module}/../../../../build/pipeline-automation"
  output_path = "${path.module}/../../../../build/tenant-pipeline.zip"
}

data "archive_file" "views" {
  type        = "zip"
  source_dir  = "${path.module}/../../../../build/views-bootstrap"
  output_path = "${path.module}/../../../../build/tenant-views.zip"
}

locals {
  automation_functions = ["start-ingestion", "refresh-spice", "deploy-views", "sales-alerts"]

  arn_glue       = "arn:aws:glue:${var.region}:${var.account_id}"
  arn_quicksight = "arn:aws:quicksight:${var.region}:${var.account_id}"

  catalog_resources = [
    "${local.arn_glue}:catalog",
    "${local.arn_glue}:database/${aws_glue_catalog_database.sales.name}",
    "${local.arn_glue}:table/${aws_glue_catalog_database.sales.name}/*",
  ]

  # Own log group, X-Ray and the (encrypted) alerts topic, which is also the
  # failure destination of every async invocation.
  common_statements = {
    for fn in local.automation_functions : fn => [
      {
        Sid      = "WriteOwnLogs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.lambda[fn].arn}:*"
      },
      {
        Sid      = "Tracing"
        Effect   = "Allow"
        Action   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
        Resource = "*"
      },
      {
        Sid      = "PublishAlerts"
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = aws_sns_topic.alerts.arn
      },
      {
        Sid      = "EncryptAlerts"
        Effect   = "Allow"
        Action   = ["kms:GenerateDataKey", "kms:Decrypt"]
        Resource = aws_kms_key.alerts.arn
      },
    ]
  }

  query_statements = [
    {
      Sid      = "QueryWorkgroup"
      Effect   = "Allow"
      Action   = ["athena:StartQueryExecution", "athena:GetQueryExecution", "athena:GetQueryResults", "athena:StopQueryExecution"]
      Resource = aws_athena_workgroup.sales.arn
    },
    {
      Sid      = "ReadCatalog"
      Effect   = "Allow"
      Action   = ["glue:GetDatabase", "glue:GetTable", "glue:GetTables", "glue:GetPartition", "glue:GetPartitions"]
      Resource = local.catalog_resources
    },
    {
      Sid      = "ListDataBucket"
      Effect   = "Allow"
      Action   = ["s3:GetBucketLocation", "s3:ListBucket"]
      Resource = aws_s3_bucket.data.arn
    },
    {
      Sid      = "ReadModel"
      Effect   = "Allow"
      Action   = ["s3:GetObject"]
      Resource = "${aws_s3_bucket.data.arn}/curated/*"
    },
    {
      Sid      = "WriteQueryResults"
      Effect   = "Allow"
      Action   = ["s3:GetObject", "s3:PutObject", "s3:AbortMultipartUpload"]
      Resource = "${aws_s3_bucket.data.arn}/athena-results/*"
    },
  ]

  function_statements = {
    start-ingestion = [
      {
        Sid      = "RunTransformation"
        Effect   = "Allow"
        Action   = ["glue:StartJobRun", "glue:GetJobRun"]
        Resource = "${local.arn_glue}:job/${aws_glue_job.flatten_invoices.name}"
      },
    ]

    refresh-spice = concat(local.query_statements, [
      {
        Sid    = "RefreshSpice"
        Effect = "Allow"
        Action = ["quicksight:CreateIngestion", "quicksight:DescribeIngestion"]
        Resource = [
          "${local.arn_quicksight}:dataset/${local.sales_data_set_id}/ingestion/*",
          "${local.arn_quicksight}:dataset/${local.periods_data_set_id}/ingestion/*",
        ]
      },
    ])

    deploy-views = concat(local.query_statements, [
      {
        Sid      = "DeployModel"
        Effect   = "Allow"
        Action   = ["glue:CreateTable", "glue:UpdateTable", "glue:DeleteTable"]
        Resource = local.catalog_resources
      },
      {
        Sid      = "WriteIcebergMetadata"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:AbortMultipartUpload"]
        Resource = "${aws_s3_bucket.data.arn}/${local.iceberg_prefix}*"
      },
      {
        Sid      = "ChainSpiceRefresh"
        Effect   = "Allow"
        Action   = ["lambda:InvokeFunction"]
        Resource = aws_lambda_function.refresh_spice.arn
      },
    ])

    sales-alerts = local.query_statements
  }
}

# One execution role per function, least privilege.
resource "aws_iam_role" "automation" {
  for_each = toset(local.automation_functions)

  name = "${local.prefix}-${each.key}"
  tags = local.tags

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
      Condition = { StringEquals = { "aws:SourceAccount" = var.account_id } }
    }]
  })
}

resource "aws_iam_role_policy" "automation" {
  for_each = toset(local.automation_functions)

  name = "${local.prefix}-${each.key}"
  role = aws_iam_role.automation[each.key].id

  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = concat(local.common_statements[each.key], local.function_statements[each.key])
  })
}

# --- Functions -------------------------------------------------------------
resource "aws_lambda_function" "start_ingestion" {
  function_name    = "${local.prefix}-start-ingestion"
  role             = aws_iam_role.automation["start-ingestion"].arn
  handler          = "start_ingestion.handler"
  runtime          = "nodejs22.x"
  architectures    = ["arm64"]
  timeout          = 30
  memory_size      = 256
  filename         = data.archive_file.pipeline.output_path
  source_code_hash = data.archive_file.pipeline.output_base64sha256
  tags             = local.tags

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.lambda["start-ingestion"].name
  }

  tracing_config {
    mode = "Active"
  }

  environment {
    variables = { GLUE_JOB_NAME = aws_glue_job.flatten_invoices.name }
  }
}

resource "aws_lambda_function" "refresh_spice" {
  function_name    = "${local.prefix}-refresh-spice"
  role             = aws_iam_role.automation["refresh-spice"].arn
  handler          = "refresh_spice.handler"
  runtime          = "nodejs22.x"
  architectures    = ["arm64"]
  timeout          = 120
  memory_size      = 256
  filename         = data.archive_file.pipeline.output_path
  source_code_hash = data.archive_file.pipeline.output_base64sha256
  tags             = local.tags

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.lambda["refresh-spice"].name
  }

  tracing_config {
    mode = "Active"
  }

  environment {
    variables = {
      QUICKSIGHT_ACCOUNT_ID = var.account_id
      LINES_DATA_SET_ID     = local.sales_data_set_id
      PERIODS_DATA_SET_ID   = local.periods_data_set_id
      LOOKBACK_DAYS         = tostring(var.spice_lookback_days)
      ATHENA_WORKGROUP      = aws_athena_workgroup.sales.name
      ATHENA_DATABASE       = aws_glue_catalog_database.sales.name
    }
  }
}

resource "aws_lambda_function" "sales_alerts" {
  function_name    = "${local.prefix}-sales-alerts"
  role             = aws_iam_role.automation["sales-alerts"].arn
  handler          = "sales_alerts.handler"
  runtime          = "nodejs22.x"
  architectures    = ["arm64"]
  timeout          = 120
  memory_size      = 512
  filename         = data.archive_file.pipeline.output_path
  source_code_hash = data.archive_file.pipeline.output_base64sha256
  tags             = local.tags

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.lambda["sales-alerts"].name
  }

  tracing_config {
    mode = "Active"
  }

  environment {
    variables = {
      ATHENA_WORKGROUP   = aws_athena_workgroup.sales.name
      ATHENA_DATABASE    = aws_glue_catalog_database.sales.name
      ALERTS_TOPIC_ARN   = aws_sns_topic.alerts.arn
      DROP_THRESHOLD_PCT = tostring(var.drop_threshold_pct)
      APP_URL            = local.app_url
    }
  }
}

resource "aws_lambda_function" "deploy_views" {
  function_name    = "${local.prefix}-deploy-views"
  role             = aws_iam_role.automation["deploy-views"].arn
  handler          = "deploy_views.handler"
  runtime          = "nodejs22.x"
  architectures    = ["arm64"]
  timeout          = 300
  memory_size      = 512
  filename         = data.archive_file.views.output_path
  source_code_hash = data.archive_file.views.output_base64sha256
  tags             = local.tags

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.lambda["deploy-views"].name
  }

  tracing_config {
    mode = "Active"
  }

  environment {
    variables = {
      GLUE_DATABASE         = aws_glue_catalog_database.sales.name
      ATHENA_WORKGROUP      = aws_athena_workgroup.sales.name
      WAREHOUSE_PATH        = local.iceberg_warehouse
      REFRESH_FUNCTION_NAME = aws_lambda_function.refresh_spice.function_name
    }
  }
}

/**
 * Deploy sql/model during apply: the empty Iceberg tables and the views over
 * them, so the account is functional before any data arrives and the SPICE
 * datasets have a real view to point at. Re-runs whenever the bundle changes,
 * which includes any change to a file in sql/model.
 */
resource "aws_lambda_invocation" "deploy_views" {
  function_name = aws_lambda_function.deploy_views.function_name
  input         = jsonencode({ trigger = "terraform-apply" })

  triggers = {
    bundle = data.archive_file.views.output_base64sha256
  }

  depends_on = [aws_iam_role_policy.automation]
}

# --- Notifications ---------------------------------------------------------
# Customer managed key: EventBridge and CloudWatch alarms can only publish to
# an encrypted topic when the key policy lets them use the key.
resource "aws_kms_key" "alerts" {
  description             = "Cifrado del topic de alertas de ${var.tenant_name}"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  tags                    = local.tags

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AccountAdministration"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${var.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "AlertingServices"
        Effect    = "Allow"
        Principal = { Service = ["events.amazonaws.com", "cloudwatch.amazonaws.com"] }
        Action    = ["kms:GenerateDataKey*", "kms:Decrypt"]
        Resource  = "*"
        Condition = { StringEquals = { "aws:SourceAccount" = var.account_id } }
      },
    ]
  })
}

resource "aws_kms_alias" "alerts" {
  name          = "alias/${local.prefix}-alerts"
  target_key_id = aws_kms_key.alerts.key_id
}

resource "aws_sns_topic" "alerts" {
  name              = "${local.prefix}-alerts"
  kms_master_key_id = aws_kms_key.alerts.arn
  tags              = local.tags
}

resource "aws_sns_topic_policy" "alerts" {
  arn = aws_sns_topic.alerts.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Glue failure rule and CloudWatch alarms, only from this account.
        Sid       = "AllowAlertingServices"
        Effect    = "Allow"
        Principal = { Service = ["events.amazonaws.com", "cloudwatch.amazonaws.com"] }
        Action    = "sns:Publish"
        Resource  = aws_sns_topic.alerts.arn
        Condition = { StringEquals = { "aws:SourceAccount" = var.account_id } }
      },
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = { AWS = "*" }
        Action    = ["sns:Publish", "sns:Subscribe"]
        Resource  = aws_sns_topic.alerts.arn
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
    ]
  })
}

resource "aws_sns_topic_subscription" "alerts" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.notification_email
}

# --- Event wiring ----------------------------------------------------------
resource "aws_cloudwatch_event_rule" "raw_object_created" {
  name        = "${local.prefix}-raw-created"
  description = "Un archivo de facturas nuevo dispara la carga incremental."
  tags        = local.tags

  event_pattern = jsonencode({
    source        = ["aws.s3"]
    "detail-type" = ["Object Created"]
    detail = {
      bucket = { name = [aws_s3_bucket.data.bucket] }
      object = { key = [{ prefix = local.raw_prefix }] }
    }
  })
}

resource "aws_cloudwatch_event_target" "raw_object_created" {
  rule = aws_cloudwatch_event_rule.raw_object_created.name
  arn  = aws_lambda_function.start_ingestion.arn
}

resource "aws_lambda_permission" "raw_object_created" {
  statement_id  = "AllowEventBridgeRawCreated"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.start_ingestion.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.raw_object_created.arn
}

resource "aws_cloudwatch_event_rule" "glue_succeeded" {
  name        = "${local.prefix}-glue-succeeded"
  description = "Transformación lista: refrescar vistas y SPICE."
  tags        = local.tags

  event_pattern = jsonencode({
    source        = ["aws.glue"]
    "detail-type" = ["Glue Job State Change"]
    detail = {
      jobName = [aws_glue_job.flatten_invoices.name]
      state   = ["SUCCEEDED"]
    }
  })
}

# Single target. Two targets on one rule run in parallel, which let SPICE read
# the views while they were being replaced; deploy-views now invokes
# refresh-spice itself when it finishes.
resource "aws_cloudwatch_event_target" "glue_succeeded_views" {
  rule      = aws_cloudwatch_event_rule.glue_succeeded.name
  target_id = "deploy-views"
  arn       = aws_lambda_function.deploy_views.arn
}

resource "aws_lambda_permission" "glue_succeeded_views" {
  statement_id  = "AllowEventBridgeGlueViews"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.deploy_views.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.glue_succeeded.arn
}

resource "aws_cloudwatch_event_rule" "weekly_review" {
  # Monthly (the 2nd, 13:00 UTC = 07:00 Guatemala): the review compares the
  # last complete month with the one before. Name kept to avoid a replace.
  name                = "${local.prefix}-weekly-review"
  description         = "Revisión mensual de caídas de facturación (mes completo vs anterior)."
  schedule_expression = "cron(0 13 2 * ? *)"
  tags                = local.tags
}

resource "aws_cloudwatch_event_target" "weekly_review" {
  rule = aws_cloudwatch_event_rule.weekly_review.name
  arn  = aws_lambda_function.sales_alerts.arn
}

resource "aws_lambda_permission" "weekly_review" {
  statement_id  = "AllowEventBridgeWeeklyReview"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.sales_alerts.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.weekly_review.arn
}

# --- Backstop and data quality ---------------------------------------------
# Daily sweep, 01:30 Guatemala (07:30 UTC): loads any raw file whose own
# trigger was lost. A no-op run costs about a minute of Glue.
resource "aws_cloudwatch_event_rule" "ingestion_sweep" {
  name                = "${local.prefix}-ingestion-sweep"
  description         = "Barrido diario: carga cualquier archivo crudo pendiente."
  schedule_expression = "cron(30 7 * * ? *)"
  tags                = local.tags
}

resource "aws_cloudwatch_event_target" "ingestion_sweep" {
  rule = aws_cloudwatch_event_rule.ingestion_sweep.name
  arn  = aws_lambda_function.start_ingestion.arn
}

resource "aws_lambda_permission" "ingestion_sweep" {
  statement_id  = "AllowEventBridgeIngestionSweep"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.start_ingestion.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.ingestion_sweep.arn
}

# One readable email per batch with rejected records (quarantine/_avisos/).
resource "aws_cloudwatch_event_rule" "records_quarantined" {
  name        = "${local.prefix}-records-quarantined"
  description = "Glue apartó registros inválidos en quarantine/."
  tags        = local.tags

  event_pattern = jsonencode({
    source        = ["aws.s3"]
    "detail-type" = ["Object Created"]
    detail = {
      bucket = { name = [aws_s3_bucket.data.bucket] }
      object = { key = [{ prefix = "quarantine/_avisos/" }] }
    }
  })
}

resource "aws_cloudwatch_event_target" "records_quarantined" {
  rule = aws_cloudwatch_event_rule.records_quarantined.name
  arn  = aws_sns_topic.alerts.arn

  input_transformer {
    input_paths = {
      bucket = "$.detail.bucket.name"
      key    = "$.detail.object.key"
    }
    input_template = "\"Ventas Inteligentes: la carga apartó registros inválidos en cuarentena. Detalle (motivos y archivos): s3://<bucket>/<key>\""
  }
}
