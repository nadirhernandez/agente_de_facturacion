/**
 * Logs, failure notifications and alarms for one tenant.
 *
 * Log groups are declared so they get a retention period (without this,
 * Lambda creates them with "never expire"). skip_destroy = true because an
 * organization SCP forbids deleting log groups: a destroy only removes them
 * from state.
 *
 * Every failure path ends in the tenant's alerts topic:
 *   - Glue run FAILED / TIMEOUT / STOPPED / ERROR  -> EventBridge -> SNS
 *   - async Lambda invocation exhausted its retries -> on_failure  -> SNS
 *   - Lambda errors, API 5xx, SPICE ingestion errors -> CloudWatch alarm -> SNS
 */

locals {
  lambda_keys = ["embedding-api", "start-ingestion", "refresh-spice", "sales-alerts", "deploy-views"]

  # Invoked asynchronously (EventBridge or Lambda Event): a failure after the
  # built-in retries would otherwise disappear.
  async_lambdas = {
    start-ingestion = aws_lambda_function.start_ingestion.function_name
    refresh-spice   = aws_lambda_function.refresh_spice.function_name
    sales-alerts    = aws_lambda_function.sales_alerts.function_name
    deploy-views    = aws_lambda_function.deploy_views.function_name
  }

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

resource "aws_cloudwatch_log_group" "lambda" {
  for_each = toset(local.lambda_keys)

  name              = "/aws/lambda/${local.prefix}-${each.key}"
  retention_in_days = var.log_retention_days
  skip_destroy      = true
  tags              = local.tags
}

resource "aws_cloudwatch_log_group" "api_access" {
  name              = "/aws/apigateway/${local.embedding_lambda_name}"
  retention_in_days = var.log_retention_days
  skip_destroy      = true
  tags              = local.tags
}

# --- Failure notifications -------------------------------------------------
resource "aws_lambda_function_event_invoke_config" "async" {
  for_each = local.async_lambdas

  function_name                = each.value
  maximum_retry_attempts       = 2
  maximum_event_age_in_seconds = 3600

  destination_config {
    on_failure {
      # The automation role already has sns:Publish on this topic.
      destination = aws_sns_topic.alerts.arn
    }
  }
}

resource "aws_cloudwatch_event_rule" "glue_failed" {
  name        = "${local.prefix}-glue-failed"
  description = "La transformación de Glue falló: avisar, porque SPICE no se va a refrescar."
  tags        = local.tags

  event_pattern = jsonencode({
    source        = ["aws.glue"]
    "detail-type" = ["Glue Job State Change"]
    detail = {
      jobName = [aws_glue_job.flatten_invoices.name]
      state   = ["FAILED", "TIMEOUT", "STOPPED", "ERROR"]
    }
  })
}

resource "aws_cloudwatch_event_target" "glue_failed" {
  rule = aws_cloudwatch_event_rule.glue_failed.name
  arn  = aws_sns_topic.alerts.arn
}

# --- Alarms ----------------------------------------------------------------
# start-ingestion is left out on purpose: it fails by design while Glue is
# busy so that Lambda retries it; a real loss arrives through on_failure.
resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  for_each = toset([for key in local.lambda_keys : key if key != "start-ingestion"])

  alarm_name          = "${local.prefix}-${each.key}-errors"
  alarm_description   = "La Lambda ${each.key} registró errores."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = "${local.prefix}-${each.key}" }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  tags                = local.tags
}

resource "aws_cloudwatch_metric_alarm" "api_5xx" {
  alarm_name          = "${local.prefix}-embedding-api-5xx"
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
  tags                = local.tags
}

resource "aws_cloudwatch_metric_alarm" "spice_ingestion_errors" {
  for_each = toset([local.sales_data_set_id, local.periods_data_set_id])

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
  tags                = local.tags
}

# Glue writes to <custom-logGroup-prefix>/output and /error; declared here so
# they get a retention period before the first run.
resource "aws_cloudwatch_log_group" "glue" {
  for_each = toset(["output", "error"])

  name              = "/ventas-inteligentes/${var.tenant_id}/glue/${each.key}"
  retention_in_days = var.log_retention_days
  skip_destroy      = true
  tags              = local.tags
}
