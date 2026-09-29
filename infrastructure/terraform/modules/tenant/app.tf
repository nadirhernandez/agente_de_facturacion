/**
 * Application layer for one tenant account: the branded app the client actually
 * opens. Without this file a tenant gets data, dashboard and chat, but would
 * have to enter through the QuickSight console.
 *
 *   Cognito (managed login v2) -> SPA on CloudFront -> API Gateway (JWT)
 *   -> Lambda -> GenerateEmbedUrlForRegisteredUser
 *
 * Ported from the pilot's application.tf, where the account id was hardcoded.
 * Differences from the pilot, on purpose:
 *
 *   - No SHARED_QUICKSIGHT_USER_ARN. In the pilot, a caller without their own
 *     QuickSight user inherited the administrator's identity. Here every app
 *     user gets a real QuickSight user (see aws_quicksight_user.app) and an
 *     unknown caller is rejected with 403.
 *   - The localhost origin is opt-in (var.enable_local_dev_origin), off by
 *     default. QuickSight rejects http://127.0.0.1 and only accepts http:// for
 *     the literal host "localhost", so local dev must use localhost:5173.
 *
 * Log groups live in observability.tf with skip_destroy: an organization SCP
 * forbids deleting them, so a destroy only forgets them.
 */

locals {
  web_bucket_name       = "vi-${var.tenant_id}-web-${var.account_id}"
  cognito_domain_prefix = "vi-${var.tenant_id}-${var.account_id}"
  embedding_lambda_name = "${local.prefix}-embedding-api"
  dashboard_id          = coalesce(var.dashboard_id, "${local.prefix}-pulso-facturacion")

  # QuickSight only accepts http:// for the literal host "localhost".
  local_dev_origin = "http://localhost:5173"

  custom_app_origins = [for domain in var.app_domain_aliases : "https://${domain}"]

  # Every origin allowed to call the API and to receive the embed URL.
  app_origins = distinct(concat(
    ["https://${aws_cloudfront_distribution.web.domain_name}"],
    local.custom_app_origins,
    var.enable_local_dev_origin ? [local.local_dev_origin] : [],
  ))

  # Canonical address of the app: the client's domain when there is one.
  app_url = length(local.custom_app_origins) > 0 ? local.custom_app_origins[0] : "https://${aws_cloudfront_distribution.web.domain_name}"
}

# ---------------------------------------------------------------------------
# Frontend hosting: private bucket, served only through CloudFront (OAC).
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "web" {
  bucket        = local.web_bucket_name
  force_destroy = false
  tags          = local.tags
}

resource "aws_s3_bucket_public_access_block" "web" {
  bucket                  = aws_s3_bucket.web.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "web" {
  bucket = aws_s3_bucket.web.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_versioning" "web" {
  bucket = aws_s3_bucket.web.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_ownership_controls" "web" {
  bucket = aws_s3_bucket.web.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# Each deploy replaces the build; old versions are kept 30 days for rollback.
resource "aws_s3_bucket_lifecycle_configuration" "web" {
  bucket = aws_s3_bucket.web.id

  rule {
    id     = "noncurrent-versions"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.web]
}

resource "aws_cloudfront_origin_access_control" "web" {
  name                              = "${local.prefix}-web-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "web" {
  enabled             = true
  comment             = "Ventas Inteligentes - ${var.tenant_name}"
  default_root_object = "index.html"
  price_class         = var.cloudfront_price_class
  http_version        = "http2and3"
  web_acl_id          = var.enable_waf ? aws_wafv2_web_acl.web[0].arn : null
  aliases             = var.app_domain_aliases
  tags                = local.tags

  origin {
    domain_name              = aws_s3_bucket.web.bucket_regional_domain_name
    origin_id                = "web-bucket"
    origin_access_control_id = aws_cloudfront_origin_access_control.web.id
  }

  default_cache_behavior {
    target_origin_id       = "web-bucket"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    # Managed-CachingOptimized
    cache_policy_id            = "658327ea-f89d-4fab-a63d-7e88639e58f6"
    response_headers_policy_id = aws_cloudfront_response_headers_policy.web.id
  }

  # Single-page application routing.
  custom_error_response {
    error_code            = 403
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 10
  }

  custom_error_response {
    error_code            = 404
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 10
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  # Note: with the default *.cloudfront.net certificate CloudFront keeps its own
  # TLS floor; minimum_protocol_version only applies with app_certificate_arn.
  viewer_certificate {
    cloudfront_default_certificate = var.app_certificate_arn == null
    acm_certificate_arn            = var.app_certificate_arn
    ssl_support_method             = var.app_certificate_arn == null ? null : "sni-only"
    # With the default certificate AWS always applies TLSv1; TLS 1.2+ is
    # enforced only with a custom domain and its ACM certificate.
    minimum_protocol_version = var.app_certificate_arn == null ? "TLSv1" : "TLSv1.2_2021"
  }

  lifecycle {
    precondition {
      condition     = length(var.app_domain_aliases) == 0 || var.app_certificate_arn != null
      error_message = "app_domain_aliases requiere app_certificate_arn: un certificado ACM en us-east-1 para esos nombres."
    }
  }
}

/**
 * Browser security headers. Wildcards for API Gateway and Cognito avoid a
 * dependency cycle (both reference the distribution's domain). The CSP starts
 * in report-only mode: violations show in the browser console without breaking
 * the embedded dashboard or chat; enforce it once they are clean.
 */
locals {
  content_security_policy = join("; ", [
    "default-src 'self'",
    "script-src 'self'",
    "style-src 'self' 'unsafe-inline'",
    "img-src 'self' data:",
    "font-src 'self' data:",
    "connect-src 'self' https://*.execute-api.${var.region}.amazonaws.com https://*.auth.${var.region}.amazoncognito.com https://cognito-idp.${var.region}.amazonaws.com",
    "frame-src https://*.quicksight.aws.amazon.com",
    "frame-ancestors 'none'",
    "base-uri 'self'",
    "form-action 'self' https://*.amazoncognito.com",
    "object-src 'none'",
  ])
}

resource "aws_cloudfront_response_headers_policy" "web" {
  name    = "${local.prefix}-web-security"
  comment = "Security headers for the Ventas Inteligentes SPA"

  security_headers_config {
    strict_transport_security {
      access_control_max_age_sec = 63072000
      include_subdomains         = true
      override                   = true
    }

    content_type_options {
      override = true
    }

    frame_options {
      frame_option = "DENY"
      override     = true
    }

    referrer_policy {
      referrer_policy = "strict-origin-when-cross-origin"
      override        = true
    }

    dynamic "content_security_policy" {
      for_each = var.content_security_policy_enforced ? [1] : []
      content {
        content_security_policy = local.content_security_policy
        override                = true
      }
    }
  }

  dynamic "custom_headers_config" {
    for_each = var.content_security_policy_enforced ? [] : [1]
    content {
      items {
        header   = "Content-Security-Policy-Report-Only"
        value    = local.content_security_policy
        override = true
      }
    }
  }
}

data "aws_iam_policy_document" "web_bucket" {
  statement {
    sid    = "AllowCloudFrontOACRead"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.web.arn}/*"]

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.web.arn]
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
      aws_s3_bucket.web.arn,
      "${aws_s3_bucket.web.arn}/*",
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "web" {
  bucket = aws_s3_bucket.web.id
  policy = data.aws_iam_policy_document.web_bucket.json

  depends_on = [aws_s3_bucket_public_access_block.web]
}

# ---------------------------------------------------------------------------
# Identity: Cognito with self sign-up disabled (invite only).
# ---------------------------------------------------------------------------
resource "aws_cognito_user_pool" "app" {
  name = "${local.prefix}-app"
  tags = local.tags

  # Managed Login and threat protection require Essentials or Plus.
  user_pool_tier           = var.cognito_user_pool_tier
  mfa_configuration        = "OPTIONAL"
  auto_verified_attributes = ["email"]
  deletion_protection      = "ACTIVE"

  admin_create_user_config {
    allow_admin_create_user_only = true
  }

  # A changed email only takes effect once verified; until then the old,
  # verified address stays in the token. The embedding API maps identity by it.
  user_attribute_update_settings {
    attributes_require_verification_before_update = ["email"]
  }

  software_token_mfa_configuration {
    enabled = true
  }

  password_policy {
    minimum_length                   = 12
    require_lowercase                = true
    require_uppercase                = true
    require_numbers                  = true
    require_symbols                  = true
    temporary_password_validity_days = 3
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  schema {
    name                = "email"
    attribute_data_type = "String"
    required            = true
    mutable             = true

    string_attribute_constraints {
      min_length = 5
      max_length = 256
    }
  }

  # Threat protection needs the Plus tier; with Essentials it stays off.
  user_pool_add_ons {
    advanced_security_mode = var.cognito_user_pool_tier == "PLUS" ? "ENFORCED" : "OFF"
  }
}

resource "aws_cognito_user_pool_domain" "app" {
  domain       = local.cognito_domain_prefix
  user_pool_id = aws_cognito_user_pool.app.id

  # Managed Login v2: current AWS sign-in experience, not the classic Hosted UI.
  managed_login_version = 2
}

/**
 * Sign-in branding. With var.app_branding unset the pool uses the AWS defaults,
 * same as the pilot. Pass a settings document and assets to put the client's
 * logo and colors on the login page.
 */
resource "aws_cognito_managed_login_branding" "app" {
  user_pool_id = aws_cognito_user_pool.app.id
  client_id    = aws_cognito_user_pool_client.web.id

  use_cognito_provided_values = var.app_branding == null
  settings                    = try(var.app_branding.settings_json, null)

  dynamic "asset" {
    for_each = var.app_branding == null ? [] : var.app_branding.assets

    content {
      category    = asset.value.category
      color_mode  = asset.value.color_mode
      extension   = asset.value.extension
      bytes       = asset.value.bytes
      resource_id = asset.value.resource_id
    }
  }
}

resource "aws_cognito_user_pool_client" "web" {
  name         = "${local.prefix}-web"
  user_pool_id = aws_cognito_user_pool.app.id

  # Public SPA client: no secret, authorization code flow with PKCE.
  generate_secret                      = false
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["openid", "email", "profile"]
  supported_identity_providers         = ["COGNITO"]

  callback_urls = [for origin in local.app_origins : "${origin}/"]
  logout_urls   = [for origin in local.app_origins : "${origin}/"]

  # Browser sign-in uses Managed Login with PKCE. Password-based admin auth
  # stays disabled so AWS credentials alone cannot mint user tokens.
  explicit_auth_flows = ["ALLOW_REFRESH_TOKEN_AUTH", "ALLOW_USER_SRP_AUTH"]

  access_token_validity  = 60
  id_token_validity      = 60
  refresh_token_validity = 1

  token_validity_units {
    access_token  = "minutes"
    id_token      = "minutes"
    refresh_token = "days"
  }

  prevent_user_existence_errors = "ENABLED"
  enable_token_revocation       = true
}

# Invited users of the app. Cognito emails the temporary password.
resource "aws_cognito_user" "app" {
  for_each = toset(var.app_users)

  user_pool_id = aws_cognito_user_pool.app.id
  username     = each.value

  attributes = {
    email          = each.value
    email_verified = true
  }

  desired_delivery_mediums = ["EMAIL"]
}

/**
 * The same people as QuickSight identities. The embedding Lambda resolves the
 * caller by the token's email claim, so without this a valid Cognito login
 * would still get a 403. Pro roles are required for the chat experience.
 */
resource "aws_quicksight_user" "app" {
  for_each = var.register_quicksight_app_users ? toset(var.app_users) : toset([])

  aws_account_id = var.account_id
  namespace      = "default"
  identity_type  = "QUICKSIGHT"
  user_name      = each.value
  email          = each.value
  user_role      = var.app_user_role

  depends_on = [aws_quicksight_account_subscription.tenant]
}

# ---------------------------------------------------------------------------
# Embedding API: Lambda with least-privilege QuickSight permissions.
# ---------------------------------------------------------------------------
data "archive_file" "embedding_api" {
  type        = "zip"
  source_dir  = "${path.module}/../../../../build/embedding-api"
  output_path = "${path.module}/../../../../build/tenant-embedding-api.zip"
}

resource "aws_iam_role" "embedding_api" {
  name = local.embedding_lambda_name
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

# The log group is declared in observability.tf (retention, skip_destroy), so
# the function only writes to it.
resource "aws_iam_role_policy" "embedding_api" {
  name = local.embedding_lambda_name
  role = aws_iam_role.embedding_api.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "WriteLambdaLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "${aws_cloudwatch_log_group.lambda["embedding-api"].arn}:*"
      },
      {
        Sid      = "Tracing"
        Effect   = "Allow"
        Action   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
        Resource = "*"
      },
      {
        # Any user in the default namespace, so each person embeds with their own
        # QuickSight identity instead of a shared account.
        Sid    = "GenerateQuickSightEmbedUrls"
        Effect = "Allow"
        Action = ["quicksight:GenerateEmbedUrlForRegisteredUser"]
        Resource = [
          "arn:aws:quicksight:${var.region}:${var.account_id}:user/default/*",
          "arn:aws:quicksight:${var.region}:${var.account_id}:dashboard/${local.dashboard_id}",
        ]
      },
      {
        Sid      = "ResolveCallerIdentity"
        Effect   = "Allow"
        Action   = ["quicksight:ListUsers"]
        Resource = "arn:aws:quicksight:${var.region}:${var.account_id}:user/default/*"
      },
      {
        # Read-only: lets the UI show when SPICE was last refreshed.
        Sid    = "ReadDatasetFreshness"
        Effect = "Allow"
        Action = ["quicksight:ListIngestions"]
        Resource = [
          "arn:aws:quicksight:${var.region}:${var.account_id}:dataset/${aws_quicksight_data_set.sales.data_set_id}/ingestion/*",
          "arn:aws:quicksight:${var.region}:${var.account_id}:dataset/${aws_quicksight_data_set.periods.data_set_id}/ingestion/*",
        ]
      },
    ]
  })
}

resource "aws_lambda_function" "embedding_api" {
  function_name    = local.embedding_lambda_name
  role             = aws_iam_role.embedding_api.arn
  handler          = "handler.handler"
  runtime          = "nodejs22.x"
  architectures    = ["arm64"]
  timeout          = 15
  memory_size      = 512
  filename         = data.archive_file.embedding_api.output_path
  source_code_hash = data.archive_file.embedding_api.output_base64sha256
  tags             = local.tags

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.lambda["embedding-api"].name
  }

  tracing_config {
    mode = "Active"
  }

  environment {
    variables = {
      # AWS_ACCOUNT_ID is a reserved name and cannot be set on a Lambda.
      QUICKSIGHT_ACCOUNT_ID = var.account_id
      DASHBOARD_ID          = local.dashboard_id
      DATA_SET_IDS = join(",", [
        aws_quicksight_data_set.sales.data_set_id,
        aws_quicksight_data_set.periods.data_set_id,
      ])

      # No SHARED_QUICKSIGHT_USER_ARN here: a caller with no QuickSight user
      # of their own must be rejected, not promoted to the admin identity.
      ALLOWED_DOMAINS = join(",", local.app_origins)
      CORS_ORIGIN     = local.app_url
      NODE_OPTIONS    = "--enable-source-maps"
    }
  }
}

resource "aws_apigatewayv2_api" "embedding_api" {
  name          = local.embedding_lambda_name
  protocol_type = "HTTP"
  tags          = local.tags

  cors_configuration {
    allow_origins = local.app_origins
    allow_methods = ["GET", "OPTIONS"]
    allow_headers = ["authorization", "content-type"]
    max_age       = 300
  }
}

resource "aws_apigatewayv2_authorizer" "cognito" {
  api_id           = aws_apigatewayv2_api.embedding_api.id
  authorizer_type  = "JWT"
  identity_sources = ["$request.header.Authorization"]
  name             = "cognito-jwt"

  jwt_configuration {
    audience = [aws_cognito_user_pool_client.web.id]
    issuer   = "https://${aws_cognito_user_pool.app.endpoint}"
  }
}

resource "aws_apigatewayv2_integration" "embedding_api" {
  api_id                 = aws_apigatewayv2_api.embedding_api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.embedding_api.invoke_arn
  payload_format_version = "2.0"
}

# Every route requires a valid Cognito JWT. There is no anonymous route.
resource "aws_apigatewayv2_route" "embed" {
  api_id             = aws_apigatewayv2_api.embedding_api.id
  route_key          = "GET /embed"
  target             = "integrations/${aws_apigatewayv2_integration.embedding_api.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito.id
}

resource "aws_apigatewayv2_route" "status" {
  api_id             = aws_apigatewayv2_api.embedding_api.id
  route_key          = "GET /status"
  target             = "integrations/${aws_apigatewayv2_integration.embedding_api.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito.id
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.embedding_api.id
  name        = "$default"
  auto_deploy = true
  tags        = local.tags

  default_route_settings {
    throttling_burst_limit = 20
    throttling_rate_limit  = 50
  }

  # Who called, which route, the result and why an authorizer rejected it.
  # The caller is the Cognito sub, never the email.
  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_access.arn
    format          = local.api_access_log_format
  }
}

# Account-wide permission (execution_arn/*/*), not per route: scoping it to one
# route makes the second route fail with 500.
resource "aws_lambda_permission" "api_gateway" {
  statement_id  = "AllowExecutionFromHttpApi"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.embedding_api.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.embedding_api.execution_arn}/*/*"
}

# ---------------------------------------------------------------------------
# Runtime configuration consumed by the SPA (no secrets, no AWS credentials).
# ---------------------------------------------------------------------------
resource "aws_s3_object" "web_runtime_config" {
  bucket        = aws_s3_bucket.web.id
  key           = "config.json"
  content_type  = "application/json"
  cache_control = "no-store"

  content = jsonencode(merge(
    {
      apiBaseUrl      = aws_apigatewayv2_stage.default.invoke_url
      cognitoDomain   = "https://${aws_cognito_user_pool_domain.app.domain}.auth.${var.region}.amazoncognito.com"
      cognitoClientId = aws_cognito_user_pool_client.web.id
      region          = var.region
    },
    # Pins the embedded chat to the tenant's agent. Omitted, the app falls back
    # to the default Quick chat.
    var.quick_chat_agent_id == null ? {} : { quickChatAgentId = var.quick_chat_agent_id },
  ))
}
