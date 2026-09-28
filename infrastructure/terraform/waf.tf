/**
 * Web ACL in front of the CloudFront distribution (scope CLOUDFRONT, which
 * must live in us-east-1, the region of this provider).
 *
 *   1. AWS common rule set: OWASP-style protections (XSS, LFI, bad bots...)
 *   2. Known bad inputs: exploit patterns such as Log4Shell
 *   3. Amazon IP reputation list: sources AWS has seen attacking
 *   4. Rate limit: 1,000 requests per 5 minutes per IP; the SPA loads a handful
 *      of files per visit, so only abuse reaches it.
 *
 * The API (API Gateway HTTP API) keeps its own JWT authorizer and throttling;
 * HTTP APIs do not accept a WAF association.
 */
resource "aws_wafv2_web_acl" "web" {
  name        = "dashboards-dinamicos-web-dev"
  description = "Proteccion de la app Ventas Inteligentes"
  scope       = "CLOUDFRONT"

  default_action {
    allow {}
  }

  rule {
    name     = "aws-common"
    priority = 1

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesCommonRuleSet"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "aws-common"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "aws-known-bad-inputs"
    priority = 2

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "aws-known-bad-inputs"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "aws-ip-reputation"
    priority = 3

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesAmazonIpReputationList"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "aws-ip-reputation"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "rate-limit-per-ip"
    priority = 4

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = 1000
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "rate-limit-per-ip"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "dashboards-dinamicos-web-dev"
    sampled_requests_enabled   = true
  }
}

# WAF only writes to log groups whose name starts with aws-waf-logs-.
resource "aws_cloudwatch_log_group" "waf" {
  name              = "aws-waf-logs-dashboards-dinamicos-web-dev"
  retention_in_days = local.log_retention_days
  skip_destroy      = true
}

resource "aws_wafv2_web_acl_logging_configuration" "web" {
  resource_arn            = aws_wafv2_web_acl.web.arn
  log_destination_configs = [aws_cloudwatch_log_group.waf.arn]

  # Tokens never reach the logs.
  redacted_fields {
    single_header {
      name = "authorization"
    }
  }

  redacted_fields {
    single_header {
      name = "cookie"
    }
  }
}
