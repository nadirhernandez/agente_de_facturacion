/**
 * Self sign-up for the public test, open to any email address.
 *
 *   Managed Login "Create account" -> pre sign-up Lambda
 *   -> Cognito emails a verification code -> the user confirms -> signs in
 *
 * ALLOW_ANY_EMAIL is an explicit switch in the trigger. Email ownership is
 * still mandatory: an unverified account cannot call the embedding API.
 */

locals {
  allowed_email_domains = ["infile.com"]
  pre_signup_name       = "dashboards-dinamicos-cognito-pre-signup-dev"
}

data "archive_file" "cognito_pre_signup" {
  type        = "zip"
  source_file = "${path.module}/../../services/cognito-triggers/src/pre_signup.mjs"
  output_path = "${path.module}/../../build/cognito-pre-signup.zip"
}

resource "aws_iam_role" "cognito_pre_signup" {
  name = local.pre_signup_name

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

# Logs only; the trigger calls no AWS API.
resource "aws_iam_role_policy" "cognito_pre_signup" {
  name = local.pre_signup_name
  role = aws_iam_role.cognito_pre_signup.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "WriteLambdaLogs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.cognito_pre_signup.arn}:*"
      },
      {
        Sid      = "Tracing"
        Effect   = "Allow"
        Action   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
        Resource = "*"
      },
    ]
  })
}

resource "aws_cloudwatch_log_group" "cognito_pre_signup" {
  name              = "/aws/lambda/${local.pre_signup_name}"
  retention_in_days = local.log_retention_days
  skip_destroy      = true
}

resource "aws_lambda_function" "cognito_pre_signup" {
  function_name    = local.pre_signup_name
  role             = aws_iam_role.cognito_pre_signup.arn
  handler          = "pre_signup.handler"
  runtime          = "nodejs22.x"
  architectures    = ["arm64"]
  timeout          = 5
  memory_size      = 128
  filename         = data.archive_file.cognito_pre_signup.output_path
  source_code_hash = data.archive_file.cognito_pre_signup.output_base64sha256

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.cognito_pre_signup.name
  }

  tracing_config {
    mode = "Active"
  }

  environment {
    variables = {
      # Explicit opt-in: any syntactically valid email may register, but
      # Cognito still requires ownership confirmation with the emailed code.
      ALLOW_ANY_EMAIL       = "true"
      ALLOWED_EMAIL_DOMAINS = ""
    }
  }

  depends_on = [aws_iam_role_policy.cognito_pre_signup]
}

resource "aws_lambda_permission" "cognito_pre_signup" {
  statement_id  = "AllowCognitoPreSignUp"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.cognito_pre_signup.function_name
  principal     = "cognito-idp.amazonaws.com"
  source_arn    = aws_cognito_user_pool.app.arn
}

/**
 * What threat protection does (advanced_security_mode = ENFORCED):
 *   - a password found in public breaches is refused at sign-up, sign-in and
 *     password change;
 *   - a high-risk sign-in is blocked, a medium-risk one asks for MFA only if
 *     the user already set it up (MFA stays optional in this pilot).
 * No notification emails: they would need SES, and Cognito's default sender is
 * kept for the pilot.
 */
resource "aws_cognito_risk_configuration" "app" {
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
