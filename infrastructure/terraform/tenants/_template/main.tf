/**
 * Root configuration for one tenant account.
 *
 * Copy this directory to tenants/<tenant_id>/, fill terraform.tfvars and apply.
 * Each tenant has its own state file, so a mistake in one client never touches
 * another.
 */

terraform {
  required_version = "= 1.16.4"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "= 6.60.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "= 2.7.1"
    }
  }

  backend "s3" {
    bucket       = "dashboards-dinamicos-tfstate-503561412084"
    key          = "tenants/REEMPLAZAR-TENANT/terraform.tfstate"
    region       = "us-east-1"
    profile      = "dashboards-dev-infile"
    encrypt      = true
    use_lockfile = true
  }
}

variable "tenant_id" { type = string }
variable "tenant_name" { type = string }
variable "account_id" { type = string }
variable "nit_emisor" { type = string }
variable "quicksight_admin_email" { type = string }
variable "notification_email" { type = string }
variable "app_users" {
  type    = list(string)
  default = []
}
variable "region" {
  type    = string
  default = "us-east-1"
}
variable "manage_quicksight_subscription" {
  type    = bool
  default = true
}
variable "glue_workers" {
  type    = number
  default = 2
}

variable "data_writer_principals" {
  description = "Principals externos autorizados a depositar JSON en raw/."
  type        = list(string)
  default     = []
}

# --- Capa de aplicación ----------------------------------------------------
variable "app_user_role" {
  description = "Rol de QuickSight de los usuarios de la app. El chat requiere un rol Pro."
  type        = string
  default     = "READER_PRO"
}

variable "app_domain_aliases" {
  description = "Dominios propios del cliente para la app. Requiere app_certificate_arn."
  type        = list(string)
  default     = []
}

variable "app_certificate_arn" {
  description = "Certificado ACM en us-east-1 para app_domain_aliases."
  type        = string
  default     = null
}

variable "app_branding" {
  description = "Marca del cliente en la pantalla de inicio de sesión."
  type = object({
    settings_json = optional(string)
    assets = optional(list(object({
      category    = string
      color_mode  = string
      extension   = string
      bytes       = optional(string)
      resource_id = optional(string)
    })), [])
  })
  default = null
}

/**
 * Terraform assumes a role inside the tenant account. The role is created by the
 * organization when the account is vended, so no credentials are ever stored.
 */
provider "aws" {
  region              = var.region
  allowed_account_ids = [var.account_id]

  assume_role {
    role_arn     = "arn:aws:iam::${var.account_id}:role/VentasInteligentesDeployer"
    session_name = "terraform-${var.tenant_id}"
  }

  default_tags {
    tags = {
      Project   = "ventas-inteligentes"
      Tenant    = var.tenant_id
      ManagedBy = "terraform"
    }
  }
}

module "tenant" {
  source = "../../modules/tenant"

  tenant_id   = var.tenant_id
  tenant_name = var.tenant_name
  account_id  = var.account_id
  region      = var.region
  nit_emisor  = var.nit_emisor

  quicksight_admin_email         = var.quicksight_admin_email
  notification_email             = var.notification_email
  app_users                      = var.app_users
  manage_quicksight_subscription = var.manage_quicksight_subscription
  glue_workers                   = var.glue_workers

  data_writer_principals = var.data_writer_principals

  app_user_role       = var.app_user_role
  app_domain_aliases  = var.app_domain_aliases
  app_certificate_arn = var.app_certificate_arn
  app_branding        = var.app_branding
}

output "raw_delivery_uri" {
  description = "Registrar este destino en el router de datos de la cuenta central."
  value       = module.tenant.raw_delivery_uri
}

output "data_bucket" {
  value = module.tenant.data_bucket
}

output "dataset_ids" {
  value = module.tenant.dataset_ids
}

output "glue_job_name" {
  value = module.tenant.glue_job_name
}

# --- Entrega al cliente ----------------------------------------------------
output "app_url" {
  description = "Dirección que se entrega al cliente."
  value       = module.tenant.app_url
}

output "cognito_domain" {
  value = module.tenant.cognito_domain
}

output "cloudfront_domain" {
  description = "Destino del CNAME si el cliente usa su propio dominio."
  value       = module.tenant.cloudfront_domain
}

output "cloudfront_distribution_id" {
  value = module.tenant.cloudfront_distribution_id
}

output "web_bucket" {
  value = module.tenant.web_bucket
}

output "api_base_url" {
  value = module.tenant.api_base_url
}

output "dashboard_id" {
  value = module.tenant.dashboard_id
}
