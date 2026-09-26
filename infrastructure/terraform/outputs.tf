output "data_bucket_name" {
  description = "Bucket privado que almacena datos crudos, Parquet curado, scripts Glue y resultados Athena."
  value       = aws_s3_bucket.data.bucket
}

output "athena_workgroup_name" {
  description = "Workgroup Athena con resultados cifrados en el bucket del proyecto."
  value       = aws_athena_workgroup.sales.name
}

output "glue_job_name" {
  description = "Job manual que transforma DTE JSONL a Parquet particionado."
  value       = aws_glue_job.flatten_invoices.name
}

output "glue_database_name" {
  description = "Base de datos Glue/Athena que QuickSight usará posteriormente."
  value       = aws_glue_catalog_database.sales.name
}

output "app_url" {
  description = "URL pública de la aplicación (CloudFront)."
  value       = "https://${aws_cloudfront_distribution.web.domain_name}"
}

output "embedding_api_url" {
  description = "HTTP API protegido con JWT de Cognito."
  value       = aws_apigatewayv2_stage.default.invoke_url
}

output "cognito_hosted_ui_domain" {
  description = "Dominio del Hosted UI de Cognito."
  value       = "https://${aws_cognito_user_pool_domain.app.domain}.auth.us-east-1.amazoncognito.com"
}

output "cognito_client_id" {
  description = "Client ID público del SPA (no es un secreto)."
  value       = aws_cognito_user_pool_client.web.id
}

output "web_bucket_name" {
  description = "Bucket privado que sirve el frontend mediante CloudFront."
  value       = aws_s3_bucket.web.bucket
}
