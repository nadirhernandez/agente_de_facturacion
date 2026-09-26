#!/usr/bin/env bash
# Build a self-contained deployment bundle for the embedding API Lambda.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NPM_BIN="${NPM_BIN:-npm}"

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

  (cd "${build_dir}" && "${NPM_BIN}" install --omit=dev --no-audit --no-fund --silent)
  echo "bundle ready: ${build_dir}"
}

bundle embedding-api
bundle pipeline-automation
bundle views-bootstrap
