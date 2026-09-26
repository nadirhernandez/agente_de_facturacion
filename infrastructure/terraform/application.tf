locals {
  web_bucket_name = "dashboards-dinamicos-web-503561412084"
  lambda_name     = "dashboards-dinamicos-embedding-api-dev"
  cognito_domain  = "ventas-inteligentes-dev-503561412084"
  # QuickSight only accepts http:// for the literal "localhost" host.
  local_dev_origin = "http://localhost:5173"
}

# ---------------------------------------------------------------------------
# Frontend hosting: private bucket, served only through CloudFront (OAC).
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "web" {
  bucket        = local.web_bucket_name
  force_destroy = false
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
  }
}

resource "aws_s3_bucket_versioning" "web" {
  bucket = aws_s3_bucket.web.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_cloudfront_origin_access_control" "web" {
  name                              = "dashboards-dinamicos-web-oac-dev"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "web" {
  enabled             = true
  comment             = "Ventas Inteligentes MLP (dev)"
  default_root_object = "index.html"
  price_class         = "PriceClass_100"

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
    cache_policy_id = "658327ea-f89d-4fab-a63d-7e88639e58f6"
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

  viewer_certificate {
    cloudfront_default_certificate = true
    minimum_protocol_version       = "TLSv1.2_2021"
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
  name = "ventas-inteligentes-dev"

  # Managed Login and threat protection require Essentials or Plus.
  user_pool_tier           = "PLUS"
  mfa_configuration        = "OPTIONAL"
  auto_verified_attributes = ["email"]
  deletion_protection      = "ACTIVE"

  admin_create_user_config {
    allow_admin_create_user_only = true
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

  user_pool_add_ons {
    advanced_security_mode = "AUDIT"
  }
}

resource "aws_cognito_user_pool_domain" "app" {
  domain       = local.cognito_domain
  user_pool_id = aws_cognito_user_pool.app.id

  # Managed Login v2: current AWS sign-in experience, not the classic Hosted UI.
  managed_login_version = 2
}

resource "aws_cognito_managed_login_branding" "app" {
  user_pool_id = aws_cognito_user_pool.app.id
  client_id    = aws_cognito_user_pool_client.web.id

  # Modern defaults now; swap for a custom settings document to apply brand
  # colors, logo and favicon.
  use_cognito_provided_values = true
}

resource "aws_cognito_user_pool_client" "web" {
  name         = "ventas-inteligentes-web-dev"
  user_pool_id = aws_cognito_user_pool.app.id

  # Public SPA client: no secret, authorization code flow with PKCE.
  generate_secret                      = false
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["openid", "email", "profile"]
  supported_identity_providers         = ["COGNITO"]

  callback_urls = [
    "https://${aws_cloudfront_distribution.web.domain_name}/",
    "${local.local_dev_origin}/",
  ]

  logout_urls = [
    "https://${aws_cloudfront_distribution.web.domain_name}/",
    "${local.local_dev_origin}/",
  ]

  # Browser sign-in uses the Hosted UI with PKCE. Password-based admin auth
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

resource "aws_cognito_user" "initial_admin" {
  user_pool_id = aws_cognito_user_pool.app.id
  username     = "rnhernandez@infile.com"

  attributes = {
    email          = "rnhernandez@infile.com"
    email_verified = true
  }

  desired_delivery_mediums = ["EMAIL"]
}

# ---------------------------------------------------------------------------
# Embedding API: Lambda with least-privilege QuickSight permissions.
# ---------------------------------------------------------------------------
data "archive_file" "embedding_api" {
  type        = "zip"
  source_dir  = "${path.module}/../../build/embedding-api"
  output_path = "${path.module}/../../build/embedding-api.zip"
}

resource "aws_iam_role" "embedding_api" {
  name = "dashboards-dinamicos-embedding-api-dev"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

# Log creation only. Terraform never manages or deletes log groups
# because an organization SCP forbids CloudWatch deletions.
resource "aws_iam_role_policy" "embedding_api" {
  name = "dashboards-dinamicos-embedding-api-dev"
  role = aws_iam_role.embedding_api.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "WriteLambdaLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "arn:aws:logs:us-east-1:503561412084:log-group:/aws/lambda/${local.lambda_name}:*"
      },
      {
        # Any user in the default namespace, so each person embeds with their own
        # QuickSight identity instead of a shared admin account.
        Sid    = "GenerateQuickSightEmbedUrls"
        Effect = "Allow"
        Action = ["quicksight:GenerateEmbedUrlForRegisteredUser"]
        Resource = [
          "arn:aws:quicksight:us-east-1:503561412084:user/default/*",
          "arn:aws:quicksight:us-east-1:503561412084:dashboard/pulso-facturacion-dev",
        ]
      },
      {
        Sid      = "ResolveCallerIdentity"
        Effect   = "Allow"
        Action   = ["quicksight:ListUsers"]
        Resource = "arn:aws:quicksight:us-east-1:503561412084:user/default/*"
      },
      {
        # Read-only: lets the UI show when SPICE was last refreshed.
        Sid    = "ReadDatasetFreshness"
        Effect = "Allow"
        Action = ["quicksight:ListIngestions"]
        Resource = [
          "arn:aws:quicksight:us-east-1:503561412084:dataset/${aws_quicksight_data_set.sales.data_set_id}/ingestion/*",
          "arn:aws:quicksight:us-east-1:503561412084:dataset/${aws_quicksight_data_set.comparativo.data_set_id}/ingestion/*",
        ]
      },
    ]
  })
}

resource "aws_lambda_function" "embedding_api" {
  function_name    = local.lambda_name
  role             = aws_iam_role.embedding_api.arn
  handler          = "handler.handler"
  runtime          = "nodejs22.x"
  architectures    = ["arm64"]
  timeout          = 15
  memory_size      = 512
  filename         = data.archive_file.embedding_api.output_path
  source_code_hash = data.archive_file.embedding_api.output_base64sha256

  environment {
    variables = {
      QUICKSIGHT_ACCOUNT_ID = local.quicksight_account_id
      DASHBOARD_ID          = "pulso-facturacion-dev"
      DATA_SET_IDS = join(",", [
        aws_quicksight_data_set.sales.data_set_id,
        aws_quicksight_data_set.comparativo.data_set_id,
      ])

      # Single-tenant development: callers without their own QuickSight user
      # fall back to this identity. Remove it before onboarding real users.
      FALLBACK_QUICKSIGHT_USER_ARN = local.quicksight_admin_principal
      ALLOWED_DOMAINS              = "https://${aws_cloudfront_distribution.web.domain_name},${local.local_dev_origin}"
      CORS_ORIGIN                  = "https://${aws_cloudfront_distribution.web.domain_name}"
      NODE_OPTIONS                 = "--enable-source-maps"
    }
  }
}

resource "aws_apigatewayv2_api" "embedding_api" {
  name          = "dashboards-dinamicos-embedding-api-dev"
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins = [
      "https://${aws_cloudfront_distribution.web.domain_name}",
      local.local_dev_origin,
    ]
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

  default_route_settings {
    throttling_burst_limit = 20
    throttling_rate_limit  = 50
  }
}

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

  content = jsonencode({
    apiBaseUrl      = aws_apigatewayv2_stage.default.invoke_url
    cognitoDomain   = "https://${aws_cognito_user_pool_domain.app.domain}.auth.us-east-1.amazoncognito.com"
    cognitoClientId = aws_cognito_user_pool_client.web.id
    region          = "us-east-1"
  })
}
