#!/usr/bin/env bash
# Run each statement of a SQL file against the project Athena workgroup.
#
# Variables opcionales (por defecto, el piloto):
#   ATHENA_WORKGROUP, ATHENA_DATABASE, AWS_PROFILE, AWS_REGION
#   ATHENA_TIMEOUT  segundos máximos por sentencia (600)
set -euo pipefail

FILE="${1:?uso: run_athena_sql.sh <archivo.sql>}"
WORKGROUP="${ATHENA_WORKGROUP:-dashboards-dinamicos-dev}"
DATABASE="${ATHENA_DATABASE:-sales_demo}"
PROFILE="${AWS_PROFILE:-dashboards-dev-infile}"
REGION="${AWS_REGION:-us-east-1}"
TIMEOUT="${ATHENA_TIMEOUT:-600}"
POLL_SECONDS=3

STATEMENTS="$(mktemp "${TMPDIR:-/tmp}/athena_statements.XXXXXX")"
trap 'rm -f "${STATEMENTS}"' EXIT

# Primero se quitan las líneas que son solo comentario (así un ';' dentro de un
# comentario no parte la sentencia) y luego se separa por ';'. Los saltos de
# línea se conservan: aplanarlos haría que un '--' al final de una línea se
# tragara el resto de la sentencia.
python3 - "$FILE" <<'PY' > "${STATEMENTS}"
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    lines = [line for line in handle.read().splitlines() if not line.strip().startswith("--")]
statements = [chunk.strip() for chunk in "\n".join(lines).split(";")]
print("\x1e".join(statement for statement in statements if statement))
PY

aws_q() { aws "$@" --profile "${PROFILE}" --region "${REGION}"; }

index=0
while IFS= read -r -d $'\x1e' statement || [ -n "$statement" ]; do
  [ -z "${statement//[[:space:]]/}" ] && continue
  index=$((index + 1))
  label="$(printf '%s' "$statement" | tr -s '[:space:]' ' ' | cut -c1-60)"
  echo "[$index] ${label}…"

  id="$(aws_q athena start-query-execution \
    --query-string "$statement" \
    --query-execution-context "Database=${DATABASE}" \
    --work-group "${WORKGROUP}" \
    --query QueryExecutionId --output text)"

  waited=0
  while true; do
    sleep "${POLL_SECONDS}"
    waited=$((waited + POLL_SECONDS))
    state="$(aws_q athena get-query-execution --query-execution-id "$id" \
      --query 'QueryExecution.Status.State' --output text)"
    case "$state" in
      SUCCEEDED|FAILED|CANCELLED) break ;;
    esac
    if [ "${waited}" -ge "${TIMEOUT}" ]; then
      echo "    TIEMPO AGOTADO: sigue en ${state} tras ${TIMEOUT}s; cancelando ${id}"
      aws_q athena stop-query-execution --query-execution-id "$id" || true
      exit 1
    fi
  done

  if [ "$state" != "SUCCEEDED" ]; then
    reason="$(aws_q athena get-query-execution --query-execution-id "$id" \
      --query 'QueryExecution.Status.StateChangeReason' --output text)"
    echo "    FALLÓ (${state}): $reason"
    exit 1
  fi
  echo "    ok"
done < "${STATEMENTS}"

echo "Listo: $index sentencia(s)."
