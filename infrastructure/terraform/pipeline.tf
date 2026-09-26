/**
 * Data pipeline automation:
 *   new raw file   -> EventBridge -> Lambda -> Glue (MERGE into Iceberg)
 *   Glue SUCCEEDED -> EventBridge -> deploy-views (sql/model) -> refresh-spice
 *   weekly schedule -> Lambda -> Athena -> SNS alert
 *
 * The views are deployed before SPICE refreshes, in sequence, so SPICE never
 * reads a view that is being replaced.
 *
 * No CloudWatch log groups are declared anywhere: the organization SCP forbids
 * their deletion, so Terraform must never own them.
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

# --- Shared execution role -------------------------------------------------
resource "aws_iam_role" "pipeline_automation" {
  name = "dashboards-dinamicos-pipeline-automation-dev"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "pipeline_automation" {
  name = "dashboards-dinamicos-pipeline-automation-dev"
  role = aws_iam_role.pipeline_automation.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "WriteLambdaLogs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:us-east-1:503561412084:log-group:/aws/lambda/${local.automation_lambda_prefix}-*"
      },
      {
        Sid      = "StartIngestionJob"
        Effect   = "Allow"
        Action   = ["glue:StartJobRun", "glue:GetJobRun", "glue:GetJobRuns"]
        Resource = "arn:aws:glue:us-east-1:503561412084:job/${aws_glue_job.flatten_invoices.name}"
      },
      {
        Sid    = "RefreshSpice"
        Effect = "Allow"
        Action = ["quicksight:CreateIngestion", "quicksight:DescribeIngestion"]
        Resource = [
          "arn:aws:quicksight:us-east-1:503561412084:dataset/${aws_quicksight_data_set.sales.data_set_id}/ingestion/*",
          "arn:aws:quicksight:us-east-1:503561412084:dataset/${aws_quicksight_data_set.comparativo.data_set_id}/ingestion/*",
        ]
      },
      {
        # Athena DDL for the model runs with the caller's catalog permissions.
        Sid    = "DeployModel"
        Effect = "Allow"
        Action = ["glue:CreateTable", "glue:UpdateTable", "glue:DeleteTable"]
        Resource = [
          "arn:aws:glue:us-east-1:503561412084:catalog",
          "arn:aws:glue:us-east-1:503561412084:database/${aws_glue_catalog_database.sales.name}",
          "arn:aws:glue:us-east-1:503561412084:table/${aws_glue_catalog_database.sales.name}/*",
        ]
      },
      {
        Sid      = "ChainSpiceRefresh"
        Effect   = "Allow"
        Action   = ["lambda:InvokeFunction"]
        Resource = aws_lambda_function.refresh_spice.arn
      },
      {
        Sid    = "QueryCertifiedView"
        Effect = "Allow"
        Action = [
          "athena:StartQueryExecution",
          "athena:GetQueryExecution",
          "athena:GetQueryResults",
        ]
        Resource = aws_athena_workgroup.sales.arn
      },
      {
        Sid    = "ReadCatalog"
        Effect = "Allow"
        Action = ["glue:GetDatabase", "glue:GetTable", "glue:GetTables", "glue:GetPartitions"]
        Resource = [
          "arn:aws:glue:us-east-1:503561412084:catalog",
          "arn:aws:glue:us-east-1:503561412084:database/${aws_glue_catalog_database.sales.name}",
          "arn:aws:glue:us-east-1:503561412084:table/${aws_glue_catalog_database.sales.name}/*",
        ]
      },
      {
        Sid      = "ListDataBucket"
        Effect   = "Allow"
        Action   = ["s3:GetBucketLocation", "s3:ListBucket"]
        Resource = aws_s3_bucket.data.arn
      },
      {
        Sid    = "ReadDataWriteQueryResults"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:PutObject", "s3:AbortMultipartUpload"]
        Resource = [
          "${aws_s3_bucket.data.arn}/curated/*",
          "${aws_s3_bucket.data.arn}/athena-results/*",
        ]
      },
      {
        Sid      = "PublishAlerts"
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = aws_sns_topic.alerts.arn
      },
    ]
  })
}

# --- Lambdas ---------------------------------------------------------------
resource "aws_lambda_function" "start_ingestion" {
  function_name    = "${local.automation_lambda_prefix}-start-ingestion-dev"
  role             = aws_iam_role.pipeline_automation.arn
  handler          = "start_ingestion.handler"
  runtime          = "nodejs22.x"
  architectures    = ["arm64"]
  timeout          = 30
  memory_size      = 256
  filename         = data.archive_file.pipeline_automation.output_path
  source_code_hash = data.archive_file.pipeline_automation.output_base64sha256

  environment {
    variables = {
      GLUE_JOB_NAME = aws_glue_job.flatten_invoices.name
    }
  }
}

resource "aws_lambda_function" "refresh_spice" {
  function_name    = "${local.automation_lambda_prefix}-refresh-spice-dev"
  role             = aws_iam_role.pipeline_automation.arn
  handler          = "refresh_spice.handler"
  runtime          = "nodejs22.x"
  architectures    = ["arm64"]
  timeout          = 120
  memory_size      = 256
  filename         = data.archive_file.pipeline_automation.output_path
  source_code_hash = data.archive_file.pipeline_automation.output_base64sha256

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
  role             = aws_iam_role.pipeline_automation.arn
  handler          = "deploy_views.handler"
  runtime          = "nodejs22.x"
  architectures    = ["arm64"]
  timeout          = 300
  memory_size      = 512
  filename         = data.archive_file.views_bootstrap.output_path
  source_code_hash = data.archive_file.views_bootstrap.output_base64sha256

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

  depends_on = [aws_iam_role_policy.pipeline_automation]
}

resource "aws_lambda_function" "sales_alerts" {
  function_name    = "${local.automation_lambda_prefix}-sales-alerts-dev"
  role             = aws_iam_role.pipeline_automation.arn
  handler          = "sales_alerts.handler"
  runtime          = "nodejs22.x"
  architectures    = ["arm64"]
  timeout          = 120
  memory_size      = 512
  filename         = data.archive_file.pipeline_automation.output_path
  source_code_hash = data.archive_file.pipeline_automation.output_base64sha256

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
resource "aws_sns_topic" "alerts" {
  name = "dashboards-dinamicos-alerts-dev"
}

resource "aws_sns_topic_policy" "alerts" {
  arn = aws_sns_topic.alerts.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = { AWS = "*" }
      Action    = "sns:Publish"
      Resource  = aws_sns_topic.alerts.arn
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
}

resource "aws_sns_topic_subscription" "alerts_email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = "rnhernandez@infile.com"
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

resource "aws_cloudwatch_event_rule" "weekly_sales_review" {
  name                = "dashboards-dinamicos-weekly-review-dev"
  description         = "Revisión semanal de caídas de facturación por región."
  schedule_expression = "cron(0 13 ? * MON *)"
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
