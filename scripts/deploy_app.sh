#!/usr/bin/env bash
# Publica el frontend en la cuenta de un cliente ya provisionado.
#
# Terraform crea el bucket, CloudFront y config.json, pero no el contenido del
# SPA. Sin este paso la app existe y sirve una página vacía.
#
# Uso:
#   AWS_PROFILE=<perfil-del-cliente> ./scripts/deploy_app.sh <tenant_id>
#
# Los outputs se leen del estado remoto, que vive en la cuenta del piloto y usa
# el perfil declarado en el backend. Las subidas van a la cuenta del cliente con
# AWS_PROFILE, igual que verify_tenant.sh.
set -euo pipefail

TENANT_ID="${1:?uso: deploy_app.sh <tenant_id>}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TENANT_DIR="${ROOT}/infrastructure/terraform/tenants/${TENANT_ID}"
TERRAFORM="${TERRAFORM:-terraform}"
REGION="${AWS_REGION:-us-east-1}"

if [ ! -d "${TENANT_DIR}" ]; then
  echo "No existe ${TENANT_DIR}. Provisiona primero con provision_tenant.sh." >&2
  exit 1
fi

web_bucket="$("${TERRAFORM}" -chdir="${TENANT_DIR}" output -raw web_bucket)"
distribution_id="$("${TERRAFORM}" -chdir="${TENANT_DIR}" output -raw cloudfront_distribution_id)"
app_url="$("${TERRAFORM}" -chdir="${TENANT_DIR}" output -raw app_url)"

# El bucket se llama vi-<tenant>-web-<account_id>: el sufijo es la cuenta dueña.
# Publicar con credenciales de otro cliente sería el peor error posible aquí.
account="$(aws sts get-caller-identity --query Account --output text)"
expected="${web_bucket##*-}"
if [ "${account}" != "${expected}" ]; then
  echo "Estás en la cuenta ${account} y el bucket pertenece a ${expected}." >&2
  echo "Exporta AWS_PROFILE del cliente antes de publicar." >&2
  exit 1
fi

echo "Compilando el frontend…"
npm --prefix "${ROOT}" run build --workspace @ventas-inteligentes/web

echo "Publicando en s3://${web_bucket}…"
# config.json lo gestiona Terraform: nunca se sobrescribe desde el build.
aws s3 sync "${ROOT}/apps/web/dist" "s3://${web_bucket}" \
  --exclude config.json --delete --region "${REGION}" --only-show-errors

echo "Invalidando la caché de CloudFront…"
aws cloudfront create-invalidation --distribution-id "${distribution_id}" \
  --paths '/*' --query 'Invalidation.Id' --output text

echo
echo "Listo. La app del cliente responde en ${app_url}"
