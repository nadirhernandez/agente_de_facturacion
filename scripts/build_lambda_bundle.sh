#!/usr/bin/env bash
# Genera en build/ los tres bundles autocontenidos que Terraform empaqueta:
#   - embedding-api:        API de embedding de QuickSight para la app.
#   - pipeline-automation:  start-ingestion, refresh-spice y sales-alerts.
#   - views-bootstrap:      despliegue de tablas y vistas desde sql/model.
#
# Las versiones del AWS SDK están fijadas exactamente (sin ^ ni ~) en el
# package.json de cada servicio, así que dos builds instalan lo mismo aunque no
# exista un lockfile por servicio.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NPM_BIN="${NPM_BIN:-npm}"

# Con el lockfile del monorepo presente, la caché local ya suele tener los
# paquetes resueltos: --prefer-offline la usa antes de ir al registro.
NPM_FLAGS=(--omit=dev --no-audit --no-fund --silent)
if [ -f "${ROOT}/package-lock.json" ]; then
  NPM_FLAGS+=(--prefer-offline)
fi

bundle() {
  local service="$1"
  local service_dir="${ROOT}/services/${service}"
  local build_dir="${ROOT}/build/${service}"

  rm -rf "${build_dir}"
  mkdir -p "${build_dir}"

  cp "${service_dir}"/src/*.mjs "${build_dir}/"
  cp "${service_dir}/package.json" "${build_dir}/package.json"

  # The model deployer ships the only copy of the SQL model (sql/model), so the
  # pilot and every tenant deploy exactly the same tables and views.
  if [ "${service}" = "views-bootstrap" ]; then
    mkdir -p "${build_dir}/sql"
    cp -R "${ROOT}/sql/model/tables" "${ROOT}/sql/model/views" "${build_dir}/sql/"
  fi

  (cd "${build_dir}" && "${NPM_BIN}" install "${NPM_FLAGS[@]}")
  echo "bundle ready: ${build_dir}"
}

bundle embedding-api
bundle pipeline-automation
bundle views-bootstrap
