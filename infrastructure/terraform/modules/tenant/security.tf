/**
 * Web ACL in front of the CloudFront distribution (scope CLOUDFRONT, which
 * must be created in us-east-1: the tenant provider must use us-east-1, or
 * set enable_waf = false and attach a Web ACL created elsewhere).
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
  count = var.enable_waf ? 1 : 0

  name        = "${local.prefix}-web"
  tags        = local.tags
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
    metric_name                = "${local.prefix}-web"
    sampled_requests_enabled   = true
  }
}

# WAF only writes to log groups whose name starts with aws-waf-logs-.
resource "aws_cloudwatch_log_group" "waf" {
  count = var.enable_waf ? 1 : 0

  name              = "aws-waf-logs-${local.prefix}-web"
  retention_in_days = var.log_retention_days
  skip_destroy      = true
  tags              = local.tags
}

resource "aws_wafv2_web_acl_logging_configuration" "web" {
  count = var.enable_waf ? 1 : 0

  resource_arn            = aws_wafv2_web_acl.web[0].arn
  log_destination_configs = [aws_cloudwatch_log_group.waf[0].arn]

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

/**
 * What threat protection does (advanced_security_mode = ENFORCED):
 *   - a password found in public breaches is refused at sign-up, sign-in and
 *     password change;
 *   - a high-risk sign-in is blocked, a medium-risk one asks for MFA only if
 *     the user already set it up (MFA stays optional).
 * No notification emails: they would need SES, and Cognito's default sender is
 * kept.
 */
resource "aws_cognito_risk_configuration" "app" {
  count = var.cognito_user_pool_tier == "PLUS" ? 1 : 0

  user_pool_id = aws_cognito_user_pool.app.id

  compromised_credentials_risk_configuration {
    event_filter = ["SIGN_IN", "SIGN_UP", "PASSWORD_CHANGE"]
    actions {
      event_action = "BLOCK"
    }
  }

  account_takeover_risk_configuration {
    actions {
      low_action {
        event_action = "NO_ACTION"
        notify       = false
      }
      medium_action {
        event_action = "MFA_IF_CONFIGURED"
        notify       = false
      }
      high_action {
        event_action = "BLOCK"
        notify       = false
      }
    }
  }
}
