#!/usr/bin/env bash
# Provision one tenant: create the account directory, deploy infrastructure,
# publish the Athena views and sync the semantic layer.
#
# Usage:
#   ./scripts/provision_tenant.sh <tenant_id> [plan|apply]
#
# Prerequisite: the AWS account already exists in the organization and has the
# VentasInteligentesDeployer role. Account creation is a separate, deliberate
# step (see docs/MULTI_TENANT.md) because it is not reversible.
set -euo pipefail

TENANT_ID="${1:?uso: provision_tenant.sh <tenant_id> [plan|apply]}"
ACTION="${2:-plan}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TENANT_DIR="${ROOT}/infrastructure/terraform/tenants/${TENANT_ID}"
TEMPLATE_DIR="${ROOT}/infrastructure/terraform/tenants/_template"
TERRAFORM="${TERRAFORM:-terraform}"

if [ ! -d "${TENANT_DIR}" ]; then
  echo "Creando configuración para ${TENANT_ID}…"
  cp -R "${TEMPLATE_DIR}" "${TENANT_DIR}"
  sed -i '' "s/REEMPLAZAR-TENANT/${TENANT_ID}/" "${TENANT_DIR}/main.tf"
  mv "${TENANT_DIR}/terraform.tfvars.example" "${TENANT_DIR}/terraform.tfvars"
  echo
  echo "Completa ${TENANT_DIR}/terraform.tfvars y vuelve a ejecutar."
  exit 0
fi

if [ ! -f "${TENANT_DIR}/terraform.tfvars" ]; then
  echo "Falta ${TENANT_DIR}/terraform.tfvars" >&2
  exit 1
fi

# Terraform empaqueta las Lambdas desde build/. Si falta alguna, el plan falla
# con un error de archivo inexistente en lugar de algo comprensible.
for bundle in embedding-api pipeline-automation views-bootstrap; do
  if [ ! -d "${ROOT}/build/${bundle}" ]; then
    echo "Falta build/${bundle}; generando los bundles…"
    "${ROOT}/scripts/build_lambda_bundle.sh"
    break
  fi
done

cd "${TENANT_DIR}"
"${TERRAFORM}" init -input=false
"${TERRAFORM}" validate

if [ "${ACTION}" = "apply" ]; then
  "${TERRAFORM}" apply -input=false -auto-approve
  echo
  echo "Infraestructura lista. Pasos que siguen, en orden:"
  echo "  1. Publicar vistas de Athena en la cuenta del cliente."
  echo "  2. Sincronizar el Topic (capa semántica)."
  echo "  3. Publicar el dashboard con el id que espera la app:"
  echo "       $("${TERRAFORM}" output -raw dashboard_id)"
  echo "  4. Publicar el frontend en la cuenta del cliente:"
  echo "       AWS_PROFILE=<perfil-cliente> ./scripts/deploy_app.sh ${TENANT_ID}"
  echo "  5. Entregar la dirección de la app al cliente:"
  echo "       $("${TERRAFORM}" output -raw app_url)"
  echo "  6. Registrar el destino de datos en el router central:"
  "${TERRAFORM}" output -raw raw_delivery_uri
  echo
else
  "${TERRAFORM}" plan -input=false
fi
