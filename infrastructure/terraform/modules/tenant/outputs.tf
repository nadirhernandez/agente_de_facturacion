output "tenant_id" {
  description = "Identificador del cliente."
  value       = var.tenant_id
}

output "data_bucket" {
  description = "Bucket de datos del cliente."
  value       = aws_s3_bucket.data.bucket
}

output "raw_delivery_uri" {
  description = "Destino donde tu sistema debe depositar los archivos JSON."
  value       = "s3://${aws_s3_bucket.data.bucket}/${local.raw_prefix}country=${var.country}/ingest_date=<YYYY-MM-DD>/"
}

output "glue_database" {
  description = "Base de datos del catálogo."
  value       = aws_glue_catalog_database.sales.name
}

output "glue_job_name" {
  description = "Job de transformación incremental."
  value       = aws_glue_job.flatten_invoices.name
}

output "athena_workgroup" {
  description = "Workgroup de Athena del cliente."
  value       = aws_athena_workgroup.sales.name
}

output "dataset_ids" {
  description = "Datasets SPICE creados."
  value = {
    sales   = aws_quicksight_data_set.sales.data_set_id
    periods = aws_quicksight_data_set.periods.data_set_id
  }
}

output "quicksight_role_arn" {
  description = "Rol que QuickSight usa para leer datos."
  value       = aws_iam_role.quicksight.arn
}

# --- Capa de aplicación ----------------------------------------------------

output "app_url" {
  description = "Dirección que se entrega al cliente."
  value       = local.app_url
}

output "cloudfront_domain" {
  description = "Dominio de CloudFront, útil para crear el CNAME del dominio propio."
  value       = aws_cloudfront_distribution.web.domain_name
}

output "cloudfront_distribution_id" {
  description = "Distribución a invalidar al publicar una versión nueva del frontend."
  value       = aws_cloudfront_distribution.web.id
}

output "web_bucket" {
  description = "Bucket privado del frontend. Sincroniza aquí el build del SPA."
  value       = aws_s3_bucket.web.bucket
}

output "api_base_url" {
  description = "Endpoint de la API de embedding."
  value       = aws_apigatewayv2_stage.default.invoke_url
}

output "cognito_domain" {
  description = "Dominio de inicio de sesión (Managed Login v2)."
  value       = "https://${aws_cognito_user_pool_domain.app.domain}.auth.${var.region}.amazoncognito.com"
}

output "cognito_user_pool_id" {
  description = "User pool de la app."
  value       = aws_cognito_user_pool.app.id
}

output "cognito_client_id" {
  description = "Cliente público del SPA (sin secreto, PKCE)."
  value       = aws_cognito_user_pool_client.web.id
}

output "dashboard_id" {
  description = "Dashboard que abre la app. El script de publicación debe crearlo con este id."
  value       = local.dashboard_id
}

output "app_users" {
  description = "Usuarios creados en Cognito y en QuickSight."
  value       = var.app_users
}
