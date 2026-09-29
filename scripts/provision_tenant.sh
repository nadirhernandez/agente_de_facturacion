#!/usr/bin/env bash
# Provision one tenant: create the account directory, deploy infrastructure,
# publish the Athena views and sync the semantic layer.
#
# Usage:
#   ./scripts/provision_tenant.sh <tenant_id> [plan|apply] [--yes]
#
# Por defecto solo hace plan. Con apply guarda el plan, lo muestra, pide
# confirmación (o --yes) y aplica exactamente ese plan.
#
# Prerequisite: the AWS account already exists in the organization and has the
# VentasInteligentesDeployer role. Account creation is a separate, deliberate
# step (see docs/MULTI_TENANT.md) because it is not reversible.
set -euo pipefail

usage="uso: provision_tenant.sh <tenant_id> [plan|apply] [--yes]"
TENANT_ID="${1:?${usage}}"
shift
ACTION="plan"
ASSUME_YES=0
for arg in "$@"; do
  case "${arg}" in
    plan|apply) ACTION="${arg}" ;;
    --yes|-y) ASSUME_YES=1 ;;
    *) echo "Argumento desconocido: ${arg}" >&2; echo "${usage}" >&2; exit 2 ;;
  esac
done

if ! [[ "${TENANT_ID}" =~ ^[a-z0-9-]+$ ]]; then
  echo "tenant_id inválido: '${TENANT_ID}' (solo minúsculas, dígitos y guiones)" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TENANT_DIR="${ROOT}/infrastructure/terraform/tenants/${TENANT_ID}"
TEMPLATE_DIR="${ROOT}/infrastructure/terraform/tenants/_template"
TERRAFORM="${TERRAFORM:-terraform}"

if [ ! -d "${TENANT_DIR}" ]; then
  echo "Creando configuración para ${TENANT_ID}…"
  cp -R "${TEMPLATE_DIR}" "${TENANT_DIR}"
  # -i.bak funciona igual con el sed de macOS y con el de GNU.
  sed -i.bak "s/REEMPLAZAR-TENANT/${TENANT_ID}/g" "${TENANT_DIR}/main.tf" \
    && rm -f "${TENANT_DIR}/main.tf.bak"
  mv "${TENANT_DIR}/terraform.tfvars.example" "${TENANT_DIR}/terraform.tfvars"
  echo
  echo "Completa ${TENANT_DIR}/terraform.tfvars y vuelve a ejecutar."
  exit 0
fi

TFVARS="${TENANT_DIR}/terraform.tfvars"
if [ ! -f "${TFVARS}" ]; then
  echo "Falta ${TFVARS}" >&2
  exit 1
fi

# --- Cuenta destino --------------------------------------------------------
EXPECTED_ACCOUNT="$(sed -n 's/^[[:space:]]*account_id[[:space:]]*=[[:space:]]*"\([0-9]\{12\}\)".*/\1/p' "${TFVARS}" | head -n 1)"
if [ -z "${EXPECTED_ACCOUNT}" ]; then
  echo "No se pudo leer account_id (12 dígitos entre comillas) de ${TFVARS}." >&2
  echo "Complétalo antes de continuar." >&2
  exit 1
fi

# Terraform opera en la cuenta del cliente asumiendo VentasInteligentesDeployer
# desde la sesión actual (el provider además la fija con allowed_account_ids).
# Se acepta una sesión ya dentro de la cuenta del cliente o una que pueda asumir
# ese rol y termine en ella; cualquier otra cosa se detiene aquí.
caller_account="$(aws sts get-caller-identity --query Account --output text)"
if [ "${caller_account}" = "${EXPECTED_ACCOUNT}" ]; then
  echo "Sesión en la cuenta del cliente ${EXPECTED_ACCOUNT}."
else
  role_arn="arn:aws:iam::${EXPECTED_ACCOUNT}:role/VentasInteligentesDeployer"
  assumed_arn="$(aws sts assume-role --role-arn "${role_arn}" \
    --role-session-name "check-${TENANT_ID}" --duration-seconds 900 \
    --query 'AssumedRoleUser.Arn' --output text 2>/dev/null || true)"
  assumed_account="$(printf '%s' "${assumed_arn}" | cut -d: -f5)"
  if [ "${assumed_account}" != "${EXPECTED_ACCOUNT}" ]; then
    echo "La sesión actual (cuenta ${caller_account}) no puede operar en ${EXPECTED_ACCOUNT}:" >&2
    echo "no se pudo asumir ${role_arn}." >&2
    echo "Revisa AWS_PROFILE y el account_id de ${TFVARS}." >&2
    exit 1
  fi
  echo "Sesión en ${caller_account}; asume ${role_arn} correctamente."
fi

# Terraform empaqueta las Lambdas desde build/. Se regeneran siempre para no
# desplegar un bundle viejo que ya no corresponde al código.
echo "Generando los bundles de Lambda…"
"${ROOT}/scripts/build_lambda_bundle.sh"

cd "${TENANT_DIR}"
"${TERRAFORM}" init -input=false
"${TERRAFORM}" validate

if [ "${ACTION}" != "apply" ]; then
  "${TERRAFORM}" plan -input=false
  exit 0
fi

# El plan guardado contiene valores del estado en claro: vive en un directorio
# privado fuera del repo y se borra al salir.
PLAN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/vi-plan-${TENANT_ID}.XXXXXX")"
trap 'rm -rf "${PLAN_DIR}"' EXIT
PLAN_FILE="${PLAN_DIR}/tfplan"

"${TERRAFORM}" plan -input=false -out="${PLAN_FILE}"

if [ "${ASSUME_YES}" -ne 1 ]; then
  if [ ! -t 0 ]; then
    echo "Sin terminal interactiva: usa --yes para aplicar el plan." >&2
    exit 1
  fi
  echo
  read -r -p "¿Aplicar este plan en la cuenta ${EXPECTED_ACCOUNT} (${TENANT_ID})? [s/N] " answer
  case "${answer}" in
    s|S|si|SI|Si|sí|Sí|SÍ) ;;
    *) echo "Cancelado. No se aplicó nada."; exit 1 ;;
  esac
fi

"${TERRAFORM}" apply -input=false "${PLAN_FILE}"
rm -f "${PLAN_FILE}"

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
