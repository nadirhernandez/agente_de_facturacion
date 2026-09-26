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
 * No CloudWatch log groups are declared: an organization SCP forbids deleting
 * them, so Terraform must never own them.
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

resource "aws_iam_role" "automation" {
  name = "${local.prefix}-automation"
  tags = local.tags

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "automation" {
  name = "${local.prefix}-automation"
  role = aws_iam_role.automation.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "WriteLogs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:${var.region}:${var.account_id}:log-group:/aws/lambda/${local.prefix}-*"
      },
      {
        Sid      = "RunTransformation"
        Effect   = "Allow"
        Action   = ["glue:StartJobRun", "glue:GetJobRun", "glue:GetJobRuns"]
        Resource = "arn:aws:glue:${var.region}:${var.account_id}:job/${aws_glue_job.flatten_invoices.name}"
      },
      {
        Sid    = "ReadCatalog"
        Effect = "Allow"
        Action = [
          "glue:GetDatabase", "glue:GetDatabases", "glue:GetTable", "glue:GetTables",
          "glue:GetPartition", "glue:GetPartitions",
          "glue:CreateTable", "glue:UpdateTable", "glue:DeleteTable",
        ]
        Resource = [
          "arn:aws:glue:${var.region}:${var.account_id}:catalog",
          "arn:aws:glue:${var.region}:${var.account_id}:database/${aws_glue_catalog_database.sales.name}",
          "arn:aws:glue:${var.region}:${var.account_id}:table/${aws_glue_catalog_database.sales.name}/*",
        ]
      },
      {
        Sid    = "QueryAthena"
        Effect = "Allow"
        Action = [
          "athena:StartQueryExecution", "athena:GetQueryExecution", "athena:GetQueryResults",
        ]
        Resource = aws_athena_workgroup.sales.arn
      },
      {
        Sid      = "ListDataBucket"
        Effect   = "Allow"
        Action   = ["s3:GetBucketLocation", "s3:ListBucket"]
        Resource = aws_s3_bucket.data.arn
      },
      {
        Sid      = "ReadDataWriteResults"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:AbortMultipartUpload"]
        Resource = ["${aws_s3_bucket.data.arn}/curated/*", "${aws_s3_bucket.data.arn}/athena-results/*"]
      },
      {
        Sid    = "RefreshSpice"
        Effect = "Allow"
        Action = ["quicksight:CreateIngestion", "quicksight:DescribeIngestion"]
        Resource = [
          "arn:aws:quicksight:${var.region}:${var.account_id}:dataset/${local.sales_data_set_id}/ingestion/*",
          "arn:aws:quicksight:${var.region}:${var.account_id}:dataset/${local.periods_data_set_id}/ingestion/*",
        ]
      },
      {
        Sid      = "PublishAlerts"
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = aws_sns_topic.alerts.arn
      },
      {
        Sid      = "ChainSpiceRefresh"
        Effect   = "Allow"
        Action   = ["lambda:InvokeFunction"]
        Resource = aws_lambda_function.refresh_spice.arn
      },
    ]
  })
}

# --- Functions -------------------------------------------------------------
resource "aws_lambda_function" "start_ingestion" {
  function_name    = "${local.prefix}-start-ingestion"
  role             = aws_iam_role.automation.arn
  handler          = "start_ingestion.handler"
  runtime          = "nodejs22.x"
  architectures    = ["arm64"]
  timeout          = 30
  memory_size      = 256
  filename         = data.archive_file.pipeline.output_path
  source_code_hash = data.archive_file.pipeline.output_base64sha256
  tags             = local.tags

  environment {
    variables = { GLUE_JOB_NAME = aws_glue_job.flatten_invoices.name }
  }
}

resource "aws_lambda_function" "refresh_spice" {
  function_name    = "${local.prefix}-refresh-spice"
  role             = aws_iam_role.automation.arn
  handler          = "refresh_spice.handler"
  runtime          = "nodejs22.x"
  architectures    = ["arm64"]
  timeout          = 120
  memory_size      = 256
  filename         = data.archive_file.pipeline.output_path
  source_code_hash = data.archive_file.pipeline.output_base64sha256
  tags             = local.tags

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
  role             = aws_iam_role.automation.arn
  handler          = "sales_alerts.handler"
  runtime          = "nodejs22.x"
  architectures    = ["arm64"]
  timeout          = 120
  memory_size      = 512
  filename         = data.archive_file.pipeline.output_path
  source_code_hash = data.archive_file.pipeline.output_base64sha256
  tags             = local.tags

  environment {
    variables = {
      ATHENA_WORKGROUP   = aws_athena_workgroup.sales.name
      ATHENA_DATABASE    = aws_glue_catalog_database.sales.name
      ALERTS_TOPIC_ARN   = aws_sns_topic.alerts.arn
      DROP_THRESHOLD_PCT = tostring(var.drop_threshold_pct)
    }
  }
}

resource "aws_lambda_function" "deploy_views" {
  function_name    = "${local.prefix}-deploy-views"
  role             = aws_iam_role.automation.arn
  handler          = "deploy_views.handler"
  runtime          = "nodejs22.x"
  architectures    = ["arm64"]
  timeout          = 300
  memory_size      = 512
  filename         = data.archive_file.views.output_path
  source_code_hash = data.archive_file.views.output_base64sha256
  tags             = local.tags

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
resource "aws_sns_topic" "alerts" {
  name = "${local.prefix}-alerts"
  tags = local.tags
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
  name                = "${local.prefix}-weekly-review"
  description         = "Revisión semanal de caídas de facturación."
  schedule_expression = "cron(0 13 ? * MON *)"
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
