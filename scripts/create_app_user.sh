#!/usr/bin/env bash
# Crea un usuario de la app (Cognito) con usuario y contraseña.
#
# Qué datos ve la persona lo decide el DOMINIO del correo (docs/ACCESOS.md):
#   @infile.com         -> identidad app-infile-real    -> datos reales de INFILE
#   cualquier otro      -> identidad app-demo-sintetico -> demo con datos sintéticos
# No hay que tocar QuickSight ni licencias: las dos identidades ya existen.
#
# Uso:
#   ./scripts/create_app_user.sh persona@infile.com
#       Cognito envía al correo una contraseña temporal; la cambia al entrar.
#
#   ./scripts/create_app_user.sh persona@infile.com --password 'Clave-Segura-2026!'
#       Sin correo: tú fijas la contraseña (temporal, la cambia al entrar).
#
#   ./scripts/create_app_user.sh persona@infile.com --password 'Clave-Segura-2026!' --permanent
#       Igual, pero la contraseña queda definitiva (no pide cambio).
#
# Requisitos de contraseña del pool: 12+ caracteres, mayúscula, minúscula, número y símbolo.
# Revocar: ./scripts/create_app_user.sh persona@infile.com --delete
set -euo pipefail

PROFILE="${AWS_PROFILE:-dashboards-dev-infile}"
REGION="${AWS_REGION:-us-east-1}"
USER_POOL_ID="${USER_POOL_ID:-us-east-1_Di1X9vNSS}"
APP_URL="https://d3ocvrp9ma213b.cloudfront.net"

EMAIL="${1:-}"
PASSWORD=""
PERMANENT=0
DELETE=0
shift || true
while [ $# -gt 0 ]; do
  case "$1" in
    --password) PASSWORD="$2"; shift 2 ;;
    --permanent) PERMANENT=1; shift ;;
    --delete) DELETE=1; shift ;;
    *) echo "Opción desconocida: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$EMAIL" ] || [[ "$EMAIL" != *@*.* ]]; then
  echo "Uso: $0 correo@dominio.com [--password 'Clave'] [--permanent] [--delete]" >&2
  exit 2
fi
EMAIL=$(printf '%s' "$EMAIL" | tr '[:upper:]' '[:lower:]')
DOMAIN="${EMAIL##*@}"

cog() { aws cognito-idp "$@" --user-pool-id "$USER_POOL_ID" --profile "$PROFILE" --region "$REGION"; }

if [ "$DELETE" = 1 ]; then
  cog admin-delete-user --username "$EMAIL"
  echo "Acceso revocado: $EMAIL (la sesión abierta muere al vencer su token, máx. 1 h)."
  exit 0
fi

if [ "$DOMAIN" = "infile.com" ]; then
  VERA="DATOS REALES de INFILE (identidad app-infile-real)"
else
  VERA="la DEMO con datos sintéticos (identidad app-demo-sintetico)"
fi

if [ -z "$PASSWORD" ]; then
  cog admin-create-user --username "$EMAIL" \
    --user-attributes Name=email,Value="$EMAIL" Name=email_verified,Value=true \
    --desired-delivery-mediums EMAIL >/dev/null
  ENTREGA="Cognito envió a $EMAIL un correo con la contraseña temporal."
else
  cog admin-create-user --username "$EMAIL" \
    --user-attributes Name=email,Value="$EMAIL" Name=email_verified,Value=true \
    --message-action SUPPRESS >/dev/null
  if [ "$PERMANENT" = 1 ]; then
    cog admin-set-user-password --username "$EMAIL" --password "$PASSWORD" --permanent
    ENTREGA="Contraseña definitiva fijada (no pedirá cambio)."
  else
    cog admin-set-user-password --username "$EMAIL" --password "$PASSWORD"
    ENTREGA="Contraseña temporal fijada: al entrar le pedirá poner una nueva."
  fi
fi

cat <<EOF

======================================================================
  Usuario creado: $EMAIL
  Verá:           $VERA
  App:            $APP_URL
  $ENTREGA

  Revocar:        $0 $EMAIL --delete
======================================================================
EOF
