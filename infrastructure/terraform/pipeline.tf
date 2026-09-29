/**
 * Data pipeline automation:
 *   new raw file   -> EventBridge -> Lambda -> Glue (MERGE into Iceberg)
 *   Glue SUCCEEDED -> EventBridge -> deploy-views (sql/model) -> refresh-spice
 *   weekly schedule -> Lambda -> Athena -> SNS alert
 *
 * The views are deployed before SPICE refreshes, in sequence, so SPICE never
 * reads a view that is being replaced.
 *
 * Log groups live in observability.tf with skip_destroy: the organization SCP
 * forbids their deletion, so a destroy only forgets them.
 */

locals {
  automation_lambda_prefix = "dashboards-dinamicos"

  # Days SPICE replaces on an incremental refresh. Covers re-sent and annulled
  # DTEs of the last week; anything older triggers a full refresh.
  spice_lookback_days = 7
}

data "archive_file" "pipeline_automation" {
  type        = "zip"
  source_dir  = "${path.module}/../../build/pipeline-automation"
  output_path = "${path.module}/../../build/pipeline-automation.zip"
}

# Bundle built by scripts/build_lambda_bundle.sh, including sql/model.
data "archive_file" "views_bootstrap" {
  type        = "zip"
  source_dir  = "${path.module}/../../build/views-bootstrap"
  output_path = "${path.module}/../../build/views-bootstrap.zip"
}

# --- S3 events -------------------------------------------------------------
resource "aws_s3_bucket_notification" "data_events" {
  bucket      = aws_s3_bucket.data.id
  eventbridge = true
}

# --- Execution roles: one per function, least privilege --------------------
locals {
  automation_functions = ["start-ingestion", "refresh-spice", "deploy-views", "sales-alerts"]

  catalog_resources = [
    "${local.arn_glue}:catalog",
    "${local.arn_glue}:database/${aws_glue_catalog_database.sales.name}",
    "${local.arn_glue}:table/${aws_glue_catalog_database.sales.name}/*",
  ]

  # Statements every function needs: its own log group, X-Ray traces and the
  # alerts topic (failure destination of async invocations, and the KMS key
  # that encrypts it).
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
      Action   = ["glue:GetDatabase", "glue:GetTable", "glue:GetTables", "glue:GetPartitions"]
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
        Sid      = "StartIngestionJob"
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
          "${local.arn_quicksight}:dataset/${aws_quicksight_data_set.sales.data_set_id}/ingestion/*",
          "${local.arn_quicksight}:dataset/${aws_quicksight_data_set.comparativo.data_set_id}/ingestion/*",
        ]
      },
    ])

    deploy-views = concat(local.query_statements, [
      {
        # Athena DDL for the model runs with the caller's catalog permissions.
        Sid      = "DeployModel"
        Effect   = "Allow"
        Action   = ["glue:CreateTable", "glue:UpdateTable", "glue:DeleteTable"]
        Resource = local.catalog_resources
      },
      {
        # Creating an Iceberg table writes its first metadata file.
        Sid      = "WriteIcebergMetadata"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:AbortMultipartUpload"]
        Resource = "${aws_s3_bucket.data.arn}/curated/iceberg/*"
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

resource "aws_iam_role" "automation" {
  for_each = toset(local.automation_functions)

  name = "dashboards-dinamicos-${each.key}-dev"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
      Condition = { StringEquals = { "aws:SourceAccount" = local.account_id } }
    }]
  })
}

resource "aws_iam_role_policy" "automation" {
  for_each = toset(local.automation_functions)

  name = "dashboards-dinamicos-${each.key}-dev"
  role = aws_iam_role.automation[each.key].id

  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = concat(local.common_statements[each.key], local.function_statements[each.key])
  })
}

# --- Lambdas ---------------------------------------------------------------
resource "aws_lambda_function" "start_ingestion" {
  function_name    = "${local.automation_lambda_prefix}-start-ingestion-dev"
  role             = aws_iam_role.automation["start-ingestion"].arn
  handler          = "start_ingestion.handler"
  runtime          = "nodejs22.x"
  architectures    = ["arm64"]
  timeout          = 30
  memory_size      = 256
  filename         = data.archive_file.pipeline_automation.output_path
  source_code_hash = data.archive_file.pipeline_automation.output_base64sha256

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.lambda["start-ingestion"].name
  }

  tracing_config {
    mode = "Active"
  }

  environment {
    variables = {
      GLUE_JOB_NAME = aws_glue_job.flatten_invoices.name
    }
  }
}

resource "aws_lambda_function" "refresh_spice" {
  function_name    = "${local.automation_lambda_prefix}-refresh-spice-dev"
  role             = aws_iam_role.automation["refresh-spice"].arn
  handler          = "refresh_spice.handler"
  runtime          = "nodejs22.x"
  architectures    = ["arm64"]
  timeout          = 120
  memory_size      = 256
  filename         = data.archive_file.pipeline_automation.output_path
  source_code_hash = data.archive_file.pipeline_automation.output_base64sha256

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.lambda["refresh-spice"].name
  }

  tracing_config {
    mode = "Active"
  }

  environment {
    variables = {
      QUICKSIGHT_ACCOUNT_ID = local.quicksight_account_id
      LINES_DATA_SET_ID     = aws_quicksight_data_set.sales.data_set_id
      PERIODS_DATA_SET_ID   = aws_quicksight_data_set.comparativo.data_set_id
      LOOKBACK_DAYS         = tostring(local.spice_lookback_days)
      ATHENA_WORKGROUP      = aws_athena_workgroup.sales.name
      ATHENA_DATABASE       = aws_glue_catalog_database.sales.name
    }
  }
}

# Deploys sql/model: creates missing Iceberg tables, replaces the views.
resource "aws_lambda_function" "deploy_views" {
  function_name    = "${local.automation_lambda_prefix}-deploy-views-dev"
  role             = aws_iam_role.automation["deploy-views"].arn
  handler          = "deploy_views.handler"
  runtime          = "nodejs22.x"
  architectures    = ["arm64"]
  timeout          = 300
  memory_size      = 512
  filename         = data.archive_file.views_bootstrap.output_path
  source_code_hash = data.archive_file.views_bootstrap.output_base64sha256

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

# Re-deploys the model on every apply that changes the bundle, which includes
# any change to a file in sql/model.
resource "aws_lambda_invocation" "deploy_views" {
  function_name = aws_lambda_function.deploy_views.function_name
  input         = jsonencode({ trigger = "terraform-apply" })

  triggers = {
    bundle = data.archive_file.views_bootstrap.output_base64sha256
  }

  depends_on = [aws_iam_role_policy.automation]
}

resource "aws_lambda_function" "sales_alerts" {
  function_name    = "${local.automation_lambda_prefix}-sales-alerts-dev"
  role             = aws_iam_role.automation["sales-alerts"].arn
  handler          = "sales_alerts.handler"
  runtime          = "nodejs22.x"
  architectures    = ["arm64"]
  timeout          = 120
  memory_size      = 512
  filename         = data.archive_file.pipeline_automation.output_path
  source_code_hash = data.archive_file.pipeline_automation.output_base64sha256

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
      DROP_THRESHOLD_PCT = "10"
      APP_URL            = "https://${aws_cloudfront_distribution.web.domain_name}"
    }
  }
}

# --- Notifications ---------------------------------------------------------
/**
 * Customer managed key for the alerts topic. An AWS managed key would not
 * work: EventBridge and CloudWatch alarms can only publish to an encrypted
 * topic when the key policy lets them use the key.
 */
resource "aws_kms_key" "alerts" {
  description             = "Cifrado del topic de alertas de Ventas Inteligentes (dev)"
  enable_key_rotation     = true
  deletion_window_in_days = 30

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AccountAdministration"
        Effect    = "Allow"
        Principal = { AWS = "arn:${local.partition}:iam::${local.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "AlertingServices"
        Effect    = "Allow"
        Principal = { Service = ["events.amazonaws.com", "cloudwatch.amazonaws.com"] }
        Action    = ["kms:GenerateDataKey*", "kms:Decrypt"]
        Resource  = "*"
        Condition = { StringEquals = { "aws:SourceAccount" = local.account_id } }
      },
    ]
  })
}

resource "aws_kms_alias" "alerts" {
  name          = "alias/dashboards-dinamicos-alerts-dev"
  target_key_id = aws_kms_key.alerts.key_id
}

resource "aws_sns_topic" "alerts" {
  name              = "dashboards-dinamicos-alerts-dev"
  kms_master_key_id = aws_kms_key.alerts.arn
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
        Condition = { StringEquals = { "aws:SourceAccount" = local.quicksight_account_id } }
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

resource "aws_sns_topic_subscription" "alerts_email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alerts_email
}

# --- Event rules -----------------------------------------------------------
resource "aws_cloudwatch_event_rule" "raw_object_created" {
  name        = "dashboards-dinamicos-raw-object-created-dev"
  description = "Nuevo archivo de facturas en raw/dte/ dispara la carga incremental."

  event_pattern = jsonencode({
    source        = ["aws.s3"]
    "detail-type" = ["Object Created"]
    detail = {
      bucket = { name = [aws_s3_bucket.data.bucket] }
      object = { key = [{ prefix = "raw/dte/" }] }
    }
  })
}

resource "aws_cloudwatch_event_target" "raw_object_created" {
  rule = aws_cloudwatch_event_rule.raw_object_created.name
  arn  = aws_lambda_function.start_ingestion.arn
}

resource "aws_lambda_permission" "raw_object_created" {
  statement_id  = "AllowEventBridgeRawObject"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.start_ingestion.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.raw_object_created.arn
}

resource "aws_cloudwatch_event_rule" "glue_job_succeeded" {
  name        = "dashboards-dinamicos-glue-succeeded-dev"
  description = "Glue terminó correctamente: desplegar el modelo y luego refrescar SPICE."

  event_pattern = jsonencode({
    source        = ["aws.glue"]
    "detail-type" = ["Glue Job State Change"]
    detail = {
      jobName = [aws_glue_job.flatten_invoices.name]
      state   = ["SUCCEEDED"]
    }
  })
}

# Single target: deploy-views invokes refresh-spice itself once it finishes.
resource "aws_cloudwatch_event_target" "glue_job_succeeded" {
  rule = aws_cloudwatch_event_rule.glue_job_succeeded.name
  arn  = aws_lambda_function.deploy_views.arn
}

resource "aws_lambda_permission" "glue_job_succeeded" {
  statement_id  = "AllowEventBridgeGlueSuccess"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.deploy_views.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.glue_job_succeeded.arn
}

# Monthly: the review compares the last complete month with the one before, so
# it runs once per closed month (the 2nd, 07:00 Guatemala = 13:00 UTC; the
# extra day lets late loads of the last day arrive). A weekly run would repeat
# the same alert four times. The resource name is kept to avoid a replace.
resource "aws_cloudwatch_event_rule" "weekly_sales_review" {
  name                = "dashboards-dinamicos-weekly-review-dev"
  description         = "Revisión mensual de caídas de facturación por región (mes completo vs anterior)."
  schedule_expression = "cron(0 13 2 * ? *)"
}

resource "aws_cloudwatch_event_target" "weekly_sales_review" {
  rule = aws_cloudwatch_event_rule.weekly_sales_review.name
  arn  = aws_lambda_function.sales_alerts.arn
}

resource "aws_lambda_permission" "weekly_sales_review" {
  statement_id  = "AllowEventBridgeWeeklyReview"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.sales_alerts.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.weekly_sales_review.arn
}

# --- Backstop and data quality ---------------------------------------------
# Daily sweep, 01:30 Guatemala (07:30 UTC), before the 02:00 SPICE refresh: any
# raw file whose own trigger was lost gets loaded. A no-op run costs about a
# minute of Glue.
resource "aws_cloudwatch_event_rule" "daily_ingestion_sweep" {
  name                = "dashboards-dinamicos-ingestion-sweep-dev"
  description         = "Barrido diario: carga cualquier archivo crudo pendiente."
  schedule_expression = "cron(30 7 * * ? *)"
}

resource "aws_cloudwatch_event_target" "daily_ingestion_sweep" {
  rule = aws_cloudwatch_event_rule.daily_ingestion_sweep.name
  arn  = aws_lambda_function.start_ingestion.arn
}

resource "aws_lambda_permission" "daily_ingestion_sweep" {
  statement_id  = "AllowEventBridgeIngestionSweep"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.start_ingestion.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.daily_ingestion_sweep.arn
}

# Glue writes one notice per batch with rejected records under
# quarantine/_avisos/; each one becomes a readable email.
resource "aws_cloudwatch_event_rule" "records_quarantined" {
  name        = "dashboards-dinamicos-records-quarantined-dev"
  description = "Glue apartó registros inválidos en quarantine/."

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
