variable "tenant_id" {
  description = "Identificador corto y estable del cliente, usado en nombres de recursos."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,30}[a-z0-9]$", var.tenant_id))
    error_message = "tenant_id debe ser minúsculas, números y guiones, entre 3 y 32 caracteres."
  }
}

variable "tenant_name" {
  description = "Nombre comercial del cliente, visible en la aplicación."
  type        = string
}

variable "account_id" {
  description = "Cuenta AWS del cliente donde se despliega la solución."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id debe ser un ID de cuenta AWS de 12 dígitos."
  }
}

variable "region" {
  description = "Región del despliegue."
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Ambiente del despliegue."
  type        = string
  default     = "prod"
}

variable "nit_emisor" {
  description = "NIT del contribuyente emisor. Define qué datos recibe esta cuenta."
  type        = string
}

variable "country" {
  description = "Código de país de dos letras en minúsculas."
  type        = string
  default     = "gt"
}

variable "currency_prefix" {
  description = "Prefijo de moneda para formatear montos."
  type        = string
  default     = "Q"
}

variable "data_writer_principals" {
  description = <<-EOT
    Principals externos autorizados a depositar archivos JSON en raw/. Déjalo
    vacío si el sistema que entrega los datos ya opera dentro de esta cuenta.
  EOT
  type        = list(string)
  default     = []
}

variable "refresh_spice_on_load" {
  description = "Refresca SPICE automáticamente al terminar cada carga."
  type        = bool
  default     = true
}

variable "quicksight_admin_email" {
  description = "Correo del administrador de QuickSight en la cuenta del cliente."
  type        = string
}

variable "notification_email" {
  description = "Destino de las alertas de facturación."
  type        = string
}

variable "app_users" {
  description = "Usuarios iniciales de la aplicación, por correo."
  type        = list(string)
  default     = []
}

variable "manage_quicksight_subscription" {
  description = <<-EOT
    Crea la suscripción de QuickSight en la cuenta del cliente. Ponlo en false si
    la cuenta ya tenía QuickSight habilitado, porque la suscripción no se puede
    crear dos veces.
  EOT
  type        = bool
  default     = true
}

variable "quicksight_edition" {
  description = "Edición de QuickSight. ENTERPRISE es requerida para embedding y RLS."
  type        = string
  default     = "ENTERPRISE"
}

variable "spice_refresh_interval" {
  description = <<-EOT
    Frecuencia del refresco completo programado del dataset de períodos. Es una
    fila por período, así que un refresco completo cuesta poco. El dataset de
    líneas no usa esta variable: se refresca tras cada carga, más un incremental
    diario y un completo semanal.
  EOT
  type        = string
  default     = "HOURLY"
}

variable "spice_lookback_days" {
  description = <<-EOT
    Días que reemplaza un refresco incremental del dataset de líneas. Debe cubrir
    el plazo en que llegan reenvíos y anulaciones: una carga que toque un día más
    viejo dispara un refresco completo por sí sola.
  EOT
  type        = number
  default     = 7

  validation {
    condition     = var.spice_lookback_days >= 3 && var.spice_lookback_days <= 90
    error_message = "spice_lookback_days debe estar entre 3 y 90."
  }
}

variable "timezone" {
  description = "Zona horaria de los refrescos programados de SPICE."
  type        = string
  default     = "America/Guatemala"
}

variable "drop_threshold_pct" {
  description = "Caída porcentual que dispara una alerta de facturación."
  type        = number
  default     = 10
}

variable "glue_workers" {
  description = "Workers del job de transformación. Subir para volúmenes altos."
  type        = number
  default     = 2
}

variable "retain_data_on_destroy" {
  description = "Impide que terraform destroy borre los datos del cliente."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Etiquetas adicionales."
  type        = map(string)
  default     = {}
}

# --- Capa de aplicación ----------------------------------------------------

variable "dashboard_id" {
  description = <<-EOT
    Identificador del dashboard que abre la app. Por defecto
    "vi-<tenant_id>-<environment>-pulso-facturacion", que es el que crea el
    script de publicación del dashboard en la cuenta del cliente.
  EOT
  type        = string
  default     = null
}

variable "app_user_role" {
  description = <<-EOT
    Rol de QuickSight de los usuarios de la app. El chat con los datos requiere
    un rol Pro; READER basta si solo van a ver el dashboard.
  EOT
  type        = string
  default     = "READER_PRO"

  validation {
    condition     = contains(["READER", "READER_PRO", "AUTHOR", "AUTHOR_PRO"], var.app_user_role)
    error_message = "app_user_role debe ser READER, READER_PRO, AUTHOR o AUTHOR_PRO."
  }
}

variable "register_quicksight_app_users" {
  description = <<-EOT
    Crea un usuario de QuickSight por cada correo de app_users. Ponlo en false
    solo si esas identidades ya existen en la cuenta, porque sin usuario de
    QuickSight la app responde 403: no hay identidad de reserva.
  EOT
  type        = bool
  default     = true
}

variable "cognito_user_pool_tier" {
  description = <<-EOT
    Tier del user pool. PLUS añade protección contra amenazas; ESSENTIALS
    también soporta Managed Login v2 y cuesta menos. LITE no sirve.
  EOT
  type        = string
  default     = "PLUS"

  validation {
    condition     = contains(["ESSENTIALS", "PLUS"], var.cognito_user_pool_tier)
    error_message = "cognito_user_pool_tier debe ser ESSENTIALS o PLUS; Managed Login v2 no existe en LITE."
  }
}

variable "app_domain_aliases" {
  description = <<-EOT
    Dominios propios del cliente para la app, por ejemplo
    ["analitica.laestrella.com.gt"]. Requiere app_certificate_arn. Si lo dejas
    vacío la app queda en el dominio de CloudFront.
  EOT
  type        = list(string)
  default     = []
}

variable "app_certificate_arn" {
  description = <<-EOT
    Certificado ACM para app_domain_aliases. Debe estar emitido en us-east-1,
    sin importar la región del resto del despliegue.
  EOT
  type        = string
  default     = null
}

variable "cloudfront_price_class" {
  description = "Clase de precio de CloudFront. PriceClass_100 cubre América y Europa."
  type        = string
  default     = "PriceClass_100"
}

variable "enable_local_dev_origin" {
  description = <<-EOT
    Permite http://localhost:5173 como origen de la app, para desarrollo. En una
    cuenta de cliente déjalo en false. QuickSight rechaza http://127.0.0.1 y
    solo acepta http:// para el host literal "localhost".
  EOT
  type        = bool
  default     = false
}

variable "app_branding" {
  description = <<-EOT
    Marca del cliente en la pantalla de inicio de sesión. Sin esto, Cognito usa
    los valores por defecto de AWS. settings_json es el documento de Managed
    Login; assets son los archivos, con bytes en base64 (filebase64("logo.png")).
  EOT

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
