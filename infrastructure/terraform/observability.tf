/**
 * Logs, failure notifications and alarms for the pilot. Same design as
 * modules/tenant/observability.tf.
 *
 * Log groups are declared so they get a retention period (Lambda creates them
 * with "never expire"). skip_destroy = true because an organization SCP forbids
 * deleting log groups: a destroy only removes them from state.
 *
 * The Lambda log groups already exist in the pilot account, so they are
 * imported instead of created. If a plan fails with "Cannot import non-existent
 * remote object", that function never ran: delete its key from
 * local.imported_lambda_log_groups and Terraform will create the group.
 */

locals {
  lambda_log_groups = {
    embedding-api   = local.lambda_name
    start-ingestion = aws_lambda_function.start_ingestion.function_name
    refresh-spice   = aws_lambda_function.refresh_spice.function_name
    deploy-views    = aws_lambda_function.deploy_views.function_name
    sales-alerts    = aws_lambda_function.sales_alerts.function_name
  }

  # Static names (import ids must be known at plan time).
  imported_lambda_log_groups = {
    embedding-api   = "/aws/lambda/dashboards-dinamicos-embedding-api-dev"
    start-ingestion = "/aws/lambda/dashboards-dinamicos-start-ingestion-dev"
    refresh-spice   = "/aws/lambda/dashboards-dinamicos-refresh-spice-dev"
    deploy-views    = "/aws/lambda/dashboards-dinamicos-deploy-views-dev"
    sales-alerts    = "/aws/lambda/dashboards-dinamicos-sales-alerts-dev"
  }

  async_lambdas = {
    start-ingestion = aws_lambda_function.start_ingestion.function_name
    refresh-spice   = aws_lambda_function.refresh_spice.function_name
    deploy-views    = aws_lambda_function.deploy_views.function_name
    sales-alerts    = aws_lambda_function.sales_alerts.function_name
  }

  log_retention_days = 90

  api_access_log_format = jsonencode({
    requestId      = "$context.requestId"
    ip             = "$context.identity.sourceIp"
    caller         = "$context.authorizer.claims.sub"
    routeKey       = "$context.routeKey"
    status         = "$context.status"
    latencyMs      = "$context.responseLatency"
    integrationErr = "$context.integrationErrorMessage"
    authorizerErr  = "$context.authorizer.error"
    requestTime    = "$context.requestTime"
  })
}

import {
  for_each = local.imported_lambda_log_groups
  to       = aws_cloudwatch_log_group.lambda[each.key]
  id       = each.value
}

resource "aws_cloudwatch_log_group" "lambda" {
  for_each = local.imported_lambda_log_groups

  name              = each.value
  retention_in_days = local.log_retention_days
  skip_destroy      = true
}

resource "aws_cloudwatch_log_group" "api_access" {
  name              = "/aws/apigateway/${local.lambda_name}"
  retention_in_days = local.log_retention_days
  skip_destroy      = true
}

# --- Failure notifications -------------------------------------------------
resource "aws_lambda_function_event_invoke_config" "async" {
  for_each = local.async_lambdas

  function_name                = each.value
  maximum_retry_attempts       = 2
  maximum_event_age_in_seconds = 3600

  destination_config {
    on_failure {
      # The pipeline role already has sns:Publish on this topic.
      destination = aws_sns_topic.alerts.arn
    }
  }
}

resource "aws_cloudwatch_event_rule" "glue_job_failed" {
  name        = "dashboards-dinamicos-glue-failed-dev"
  description = "La transformación de Glue falló: avisar, porque SPICE no se va a refrescar."

  event_pattern = jsonencode({
    source        = ["aws.glue"]
    "detail-type" = ["Glue Job State Change"]
    detail = {
      jobName = [aws_glue_job.flatten_invoices.name]
      state   = ["FAILED", "TIMEOUT", "STOPPED", "ERROR"]
    }
  })
}

resource "aws_cloudwatch_event_target" "glue_job_failed" {
  rule = aws_cloudwatch_event_rule.glue_job_failed.name
  arn  = aws_sns_topic.alerts.arn
}

# --- Alarms ----------------------------------------------------------------
# start-ingestion is left out on purpose: it fails by design while Glue is
# busy so that Lambda retries it; a real loss arrives through its on_failure
# destination instead.
resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  for_each = { for key, name in local.lambda_log_groups : key => name if key != "start-ingestion" }

  alarm_name          = "${each.value}-errors"
  alarm_description   = "La Lambda ${each.key} registró errores."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = each.value }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "api_5xx" {
  alarm_name          = "${local.lambda_name}-5xx"
  alarm_description   = "La API de embedding devolvió errores 5xx."
  namespace           = "AWS/ApiGateway"
  metric_name         = "5xx"
  dimensions          = { ApiId = aws_apigatewayv2_api.embedding_api.id, Stage = "$default" }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 5
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "spice_ingestion_errors" {
  for_each = toset([
    aws_quicksight_data_set.sales.data_set_id,
    aws_quicksight_data_set.comparativo.data_set_id,
  ])

  alarm_name          = "${each.value}-spice-ingestion-errors"
  alarm_description   = "Un refresco de SPICE falló: el chat y el dashboard quedan con datos viejos."
  namespace           = "AWS/QuickSight"
  metric_name         = "IngestionErrorCount"
  dimensions          = { DatasetId = each.value }
  statistic           = "Sum"
  period              = 3600
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

# Glue writes to <custom-logGroup-prefix>/output and /error. They already exist,
# so they are imported and given the same retention.
import {
  for_each = toset(["output", "error"])
  to       = aws_cloudwatch_log_group.glue[each.key]
  id       = "/dashboards-dinamicos/dev/glue/${each.key}"
}

resource "aws_cloudwatch_log_group" "glue" {
  for_each = toset(["output", "error"])

  name              = "/dashboards-dinamicos/dev/glue/${each.key}"
  retention_in_days = local.log_retention_days
  skip_destroy      = true
}
