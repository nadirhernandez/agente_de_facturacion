locals {
  web_bucket_name = "dashboards-dinamicos-web-${local.account_id}"
  lambda_name     = "dashboards-dinamicos-embedding-api-dev"
  cognito_domain  = "ventas-inteligentes-dev-${local.account_id}"
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
  http_version        = "http2and3"
  web_acl_id          = aws_wafv2_web_acl.web.arn

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

  # With the default *.cloudfront.net certificate CloudFront keeps its own TLS
  # floor and ignores minimum_protocol_version; TLS 1.2+ needs a custom domain
  # with an ACM certificate (supported by the tenant module).
  viewer_certificate {
    cloudfront_default_certificate = true
    # What AWS actually applies with the default certificate; declaring 1.2
    # here only produced a permanent diff. TLS 1.2+ requires a custom domain.
    minimum_protocol_version = "TLSv1"
  }
}

/**
 * Browser security headers. Wildcards for API Gateway and Cognito avoid a
 * dependency cycle (both reference the distribution's domain).
 *
 * The CSP below is drafted but NOT delivered (technical debt, see
 * docs/DEUDA_TECNICA.md). A Report-Only header without a report-to endpoint
 * protects nothing and floods the browser console with warnings, so it was
 * removed. Enabling it means: set enforce_csp = true, test the embedded
 * dashboard and Quick chat with a real login, and fix any blocked source.
 */
locals {
  enforce_csp = false

  content_security_policy = join("; ", [
    "default-src 'self'",
    "script-src 'self'",
    "style-src 'self' 'unsafe-inline'",
    "img-src 'self' data:",
    "font-src 'self' data:",
    "connect-src 'self' https://*.execute-api.${local.region}.amazonaws.com https://*.auth.${local.region}.amazoncognito.com https://cognito-idp.${local.region}.amazonaws.com",
    "frame-src https://*.quicksight.aws.amazon.com",
    "frame-ancestors 'none'",
    "base-uri 'self'",
    "form-action 'self' https://*.amazoncognito.com",
    "object-src 'none'",
  ])
}

resource "aws_cloudfront_response_headers_policy" "web" {
  name    = "dashboards-dinamicos-web-security-dev"
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
      for_each = local.enforce_csp ? [1] : []
      content {
        content_security_policy = local.content_security_policy
        override                = true
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
  name = "ventas-inteligentes-dev"

  # Managed Login and threat protection require Essentials or Plus.
  user_pool_tier           = "PLUS"
  mfa_configuration        = "OPTIONAL"
  auto_verified_attributes = ["email"]
  deletion_protection      = "ACTIVE"

  # Invite only: solo un administrador crea usuarios; no hay autorregistro. Se
  # deshabilitó el self sign-up para que ningún prospecto externo pueda crear
  # una cuenta por su cuenta en esta cuenta piloto (que además tiene datos
  # reales de INFILE). El pre sign-up trigger (cognito_signup.tf) sigue
  # filtrando dominio como segunda barrera para los usuarios que cree el admin.
  admin_create_user_config {
    allow_admin_create_user_only = true

    # What a new user receives when an admin creates their account
    # (scripts/create_app_user.sh). {username} and {####} are filled by Cognito.
    invite_message_template {
      email_subject = "Su acceso a INsight by INFILE"
      email_message = local.invite_email_html
      sms_message   = "INsight by INFILE: su usuario es {username} y su contraseña temporal es {####}"
    }
  }

  # Who the email comes from. COGNITO_DEFAULT sends from no-reply@verificationemail.com
  # (works for any recipient, 50 emails/day). DEVELOPER sends from an SES identity
  # of INFILE, but while the SES account is in sandbox it can only deliver to
  # verified addresses, so prospects would never get their invitation. Flip
  # var.cognito_email_via_ses to true once SES production access is granted.
  dynamic "email_configuration" {
    for_each = var.cognito_email_via_ses ? [1] : []
    content {
      email_sending_account  = "DEVELOPER"
      source_arn             = var.cognito_ses_source_arn
      from_email_address     = var.cognito_from_email
      reply_to_email_address = var.cognito_reply_to_email
    }
  }

  lambda_config {
    pre_sign_up = aws_lambda_function.cognito_pre_signup.arn
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

  # Threat protection enforced (Plus tier): the risk configuration below
  # decides what happens with compromised passwords and risky sign-ins.
  user_pool_add_ons {
    advanced_security_mode = "ENFORCED"
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

  callback_urls = concat(
    ["https://${aws_cloudfront_distribution.web.domain_name}/"],
    [for origin in local.local_dev_origins : "${origin}/"],
  )

  logout_urls = concat(
    ["https://${aws_cloudfront_distribution.web.domain_name}/"],
    [for origin in local.local_dev_origins : "${origin}/"],
  )

  # Browser sign-in uses the Hosted UI with PKCE. Password-based admin auth
  # stays disabled so AWS credentials alone cannot mint user tokens.
  # ALLOW_ADMIN_USER_PASSWORD_AUTH is server-side only (needs admin credentials):
  # scripts/create_guest_link.sh signs a guest in with it to mint one-time links.
  explicit_auth_flows = [
    "ALLOW_REFRESH_TOKEN_AUTH",
    "ALLOW_USER_SRP_AUTH",
    "ALLOW_ADMIN_USER_PASSWORD_AUTH",
  ]

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
  username     = var.app_admin_email

  attributes = {
    email          = var.app_admin_email
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
        # QuickSight identity instead of a shared admin account.
        Sid    = "GenerateQuickSightEmbedUrls"
        Effect = "Allow"
        Action = ["quicksight:GenerateEmbedUrlForRegisteredUser"]
        Resource = [
          "${local.arn_quicksight}:user/default/*",
          "${local.arn_quicksight}:dashboard/${local.app_chat.demo.dashboard_id}",
          "${local.arn_quicksight}:dashboard/${local.app_chat.real.dashboard_id}",
        ]
      },
      {
        Sid      = "ResolveCallerIdentity"
        Effect   = "Allow"
        Action   = ["quicksight:ListUsers"]
        Resource = "${local.arn_quicksight}:user/default/*"
      },
      {
        # Guest links: read the parked tokens once and delete them (one-time use).
        Sid      = "ExchangeGuestTokens"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:DeleteObject"]
        Resource = "${aws_s3_bucket.data.arn}/guest-tokens/*"
      },
      {
        # Read-only: lets the UI show when SPICE was last refreshed.
        Sid    = "ReadDatasetFreshness"
        Effect = "Allow"
        Action = ["quicksight:ListIngestions"]
        Resource = [
          for id in concat(local.app_chat.demo.data_set_ids, local.app_chat.real.data_set_ids) :
          "${local.arn_quicksight}:dataset/${id}/ingestion/*"
        ]
      },
    ]
  })
}

# ---------------------------------------------------------------------------
# App identities in Quick. The chat is the product, so the security boundary is
# "which Quick identity embeds, and what that identity can see". Two shared
# identities, both Reader Pro (the chat agent needs Pro):
#
#   app_demo  -> prospects (any email outside REAL_EMAIL_DOMAINS). Only the
#                synthetic agent/space/topic/datasets are shared with it.
#   app_real  -> INFILE staff (@infile.com). Only the real agent/space/topic/
#                datasets are shared with it.
#
# The admin SSO user is no longer the identity the app embeds with: it owns
# the resources but is never handed to a browser. Which identity a caller gets
# is decided server-side in the embedding Lambda from the verified email
# domain in the Cognito token, so a visitor cannot pick the other one.
# Permissions are granted with scripts/quicksight/grant_chat_access.py.
# ---------------------------------------------------------------------------
locals {
  app_identities = {
    demo = {
      user_name = "app-demo-sintetico"
      email     = "rnhernandez+insight-demo@infile.com"
    }
    real = {
      user_name = "app-infile-real"
      email     = "rnhernandez+insight-real@infile.com"
    }
  }

  # Chat agents and dashboards per identity. Agents and topics are created by
  # scripts/quicksight/sync_topic.py and sync_agent.py (no Terraform resource
  # exists for them yet); dashboards -dev are Terraform, -real were loaded by
  # scripts/load_real_day.sh (see docs/CARGA_DATOS_REALES.md).
  app_chat = {
    demo = {
      agent_id     = "ventas-demo-analista"
      dashboard_id = "pulso-facturacion-dev"
      data_set_ids = [
        aws_quicksight_data_set.sales.data_set_id,
        aws_quicksight_data_set.comparativo.data_set_id,
      ]
    }
    real = {
      agent_id     = "ventas-inteligentes-analista"
      dashboard_id = "pulso-facturacion-real"
      data_set_ids = ["ventas-infile-real", "ventas-comparativo-real"]
    }
  }

  # Verified email domains that get the real identity. Everyone else is demo.
  real_email_domains = ["infile.com"]
}

# Invitation email. Cognito requires the literal placeholders {username} and
# {####} somewhere in the body; the rest is free HTML (inline styles only, no
# external assets: most mail clients block them).
locals {
  app_public_url = "https://${aws_cloudfront_distribution.web.domain_name}"

  invite_email_html = <<-HTML
    <!doctype html>
    <html lang="es">
    <body style="margin:0;padding:0;background:#0f2238;font-family:-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;">
      <table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="background:#0f2238;padding:32px 16px;">
        <tr><td align="center">
          <table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="max-width:520px;background:#132b47;border-radius:14px;padding:36px 32px;color:#e8eef6;">
            <tr><td align="center" style="padding-bottom:20px;">
              <div style="font-size:34px;font-weight:800;letter-spacing:-0.5px;">
                <span style="color:#3b82f6;">IN</span><span style="color:#ffffff;">sight</span>
              </div>
              <div style="font-size:12px;color:#9fb3c8;letter-spacing:2px;text-transform:uppercase;">by INFILE</div>
            </td></tr>
            <tr><td style="font-size:16px;line-height:1.55;">
              <p style="margin:0 0 14px;">Hola,</p>
              <p style="margin:0 0 14px;">Le dimos acceso a <strong>INsight</strong>, el analista de ventas que responde, en lenguaje natural, sobre su facturación electrónica.</p>
              <table role="presentation" cellspacing="0" cellpadding="0" style="margin:18px 0;background:#0f2238;border-radius:10px;width:100%;">
                <tr><td style="padding:16px 18px;font-size:15px;">
                  <div style="color:#9fb3c8;font-size:12px;text-transform:uppercase;letter-spacing:1px;">Usuario</div>
                  <div style="font-weight:600;margin-bottom:12px;">{username}</div>
                  <div style="color:#9fb3c8;font-size:12px;text-transform:uppercase;letter-spacing:1px;">Contraseña temporal</div>
                  <div style="font-weight:600;font-family:Menlo,Consolas,monospace;">{####}</div>
                </td></tr>
              </table>
              <p style="margin:0 0 22px;">Al entrar por primera vez le pediremos elegir su propia contraseña.</p>
              <p style="margin:0 0 26px;text-align:center;">
                <a href="${local.app_public_url}" style="display:inline-block;background:#3b82f6;color:#ffffff;text-decoration:none;font-weight:700;padding:13px 26px;border-radius:10px;">Entrar a INsight</a>
              </p>
              <p style="margin:0;font-size:13px;color:#9fb3c8;line-height:1.5;">Si el botón no funciona, copie este enlace en su navegador:<br><a href="${local.app_public_url}" style="color:#7fb0ff;">${local.app_public_url}</a></p>
            </td></tr>
            <tr><td style="padding-top:26px;font-size:12px;color:#7f93a8;line-height:1.5;border-top:1px solid #1e3a5a;margin-top:20px;">
              Este acceso es personal. Si no esperaba este correo, puede ignorarlo.<br>INFILE, S.A. · Guatemala
            </td></tr>
          </table>
        </td></tr>
      </table>
    </body>
    </html>
  HTML
}

resource "aws_quicksight_user" "app" {
  for_each = local.app_identities

  aws_account_id = local.quicksight_account_id
  namespace      = "default"
  identity_type  = "QUICKSIGHT"
  user_name      = each.value.user_name
  email          = each.value.email
  user_role      = "READER_PRO"
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

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.lambda["embedding-api"].name
  }

  tracing_config {
    mode = "Active"
  }

  environment {
    variables = {
      QUICKSIGHT_ACCOUNT_ID = local.quicksight_account_id

      # Two shared identities, chosen server-side by the caller's verified
      # email domain (see locals.app_identities / app_chat above). The former
      # SHARED_QUICKSIGHT_USER_ARN (the admin) is gone on purpose: the admin
      # owns everything and must never be the identity a browser embeds with.
      REAL_EMAIL_DOMAINS = join(",", local.real_email_domains)

      DEMO_QUICKSIGHT_USER_ARN = aws_quicksight_user.app["demo"].arn
      DEMO_CHAT_AGENT_ID       = local.app_chat.demo.agent_id
      DEMO_DASHBOARD_ID        = local.app_chat.demo.dashboard_id
      DEMO_DATA_SET_IDS        = join(",", local.app_chat.demo.data_set_ids)

      REAL_QUICKSIGHT_USER_ARN = aws_quicksight_user.app["real"].arn
      REAL_CHAT_AGENT_ID       = local.app_chat.real.agent_id
      REAL_DASHBOARD_ID        = local.app_chat.real.dashboard_id
      REAL_DATA_SET_IDS        = join(",", local.app_chat.real.data_set_ids)

      # Kept for the handler's fallback path (per-user identity, as the tenant
      # module uses): dashboard and freshness when no shared identity applies.
      DASHBOARD_ID = local.app_chat.demo.dashboard_id
      DATA_SET_IDS = join(",", local.app_chat.demo.data_set_ids)

      # One-time guest links (scripts/create_guest_link.sh) park the guest's
      # tokens under guest-tokens/ in the data bucket; /guest reads and deletes.
      DATA_BUCKET = aws_s3_bucket.data.id

      # Self sign-up is disabled in the pool (admin creates users), so every
      # caller was invited; the domain gate decides demo vs real, not access.
      ALLOWED_EMAIL_DOMAINS = ""
      ALLOWED_DOMAINS       = join(",", concat(["https://${aws_cloudfront_distribution.web.domain_name}"], local.local_dev_origins))
      CORS_ORIGIN           = "https://${aws_cloudfront_distribution.web.domain_name}"
      NODE_OPTIONS          = "--enable-source-maps"
    }
  }
}

resource "aws_apigatewayv2_api" "embedding_api" {
  name          = "dashboards-dinamicos-embedding-api-dev"
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins = concat(
      ["https://${aws_cloudfront_distribution.web.domain_name}"],
      local.local_dev_origins,
    )
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

  # The caller is logged as the Cognito sub, never the email.
  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_access.arn
    format          = local.api_access_log_format
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
    cognitoDomain   = "https://${aws_cognito_user_pool_domain.app.domain}.auth.${local.region}.amazoncognito.com"
    cognitoClientId = aws_cognito_user_pool_client.web.id
    region          = local.region
    # Fallback only. The embedding API now returns the agent for the caller's
    # identity (demo vs real); this static value is used if the API omits it.
    # It must always be the demo agent: a stale frontend must never pin real.
    quickChatAgentId = local.app_chat.demo.agent_id
    # Shown large in the sidebar: the workspace belongs to the client, the
    # product (INsight by INFILE) stays in the footer.
    clientName = var.app_client_name
  })
}
