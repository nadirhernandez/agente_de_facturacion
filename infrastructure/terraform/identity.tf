/**
 * Account, region and partition come from the provider session instead of
 * being typed into every ARN. The provider's allowed_account_ids still locks
 * this stack to the pilot account.
 */
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region
  partition  = data.aws_partition.current.partition

  # Prefixes for ARNs of this account and region.
  arn_logs       = "arn:${local.partition}:logs:${local.region}:${local.account_id}"
  arn_glue       = "arn:${local.partition}:glue:${local.region}:${local.account_id}"
  arn_quicksight = "arn:${local.partition}:quicksight:${local.region}:${local.account_id}"
  arn_athena     = "arn:${local.partition}:athena:${local.region}:${local.account_id}"

  # Development convenience: when true, localhost:5173 is accepted by
  # Cognito, CORS and QuickSight embedding.
  enable_local_dev_origin = true
  local_dev_origins       = local.enable_local_dev_origin ? [local.local_dev_origin] : []
}

variable "app_admin_email" {
  description = "Administrador inicial de la app (usuario de Cognito). Va en terraform.tfvars, que no se versiona."
  type        = string

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.app_admin_email))
    error_message = "app_admin_email debe ser un correo válido."
  }
}

variable "alerts_email" {
  description = "Destino de las alertas del pipeline (SNS). Va en terraform.tfvars."
  type        = string

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.alerts_email))
    error_message = "alerts_email debe ser un correo válido."
  }
}

variable "app_client_name" {
  description = "Nombre comercial del cliente que ve la app (se muestra en grande en la interfaz). El piloto usa un nombre de demostración."
  type        = string
  default     = "Empresa Inteligente S.A."
}

# --- Correo de invitación de Cognito ------------------------------------------
# Por defecto Cognito envía desde no-reply@verificationemail.com (llega a cualquier
# destinatario). Para enviar desde una dirección de INFILE vía SES hay que salir
# del sandbox de SES primero; si no, los prospectos no reciben la invitación.
variable "cognito_email_via_ses" {
  description = "true para enviar los correos de Cognito desde una identidad SES de INFILE (requiere SES fuera de sandbox)."
  type        = bool
  default     = false
}

variable "cognito_ses_source_arn" {
  description = "ARN de la identidad SES (correo o dominio verificado) usada como remitente."
  type        = string
  default     = "arn:aws:ses:us-east-1:503561412084:identity/rnhernandez@infile.com"
}

variable "cognito_from_email" {
  description = "Remitente visible, con nombre. Debe pertenecer a la identidad SES."
  type        = string
  default     = "INsight by INFILE <rnhernandez@infile.com>"
}

variable "cognito_reply_to_email" {
  description = "Dirección a la que llegan las respuestas al correo de invitación."
  type        = string
  default     = "rnhernandez@infile.com"
}
