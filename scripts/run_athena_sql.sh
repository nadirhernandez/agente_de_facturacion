#!/usr/bin/env bash
# Run each statement of a SQL file against the project Athena workgroup.
set -euo pipefail

FILE="${1:?uso: run_athena_sql.sh <archivo.sql>}"
WORKGROUP="dashboards-dinamicos-dev"
DATABASE="sales_demo"
PROFILE="dashboards-dev-infile"
REGION="us-east-1"

# Statements are separated by ';' at end of line, ignoring comment-only chunks.
python3 - "$FILE" <<'PY' > /tmp/athena_statements.txt
import re, sys
raw = open(sys.argv[1], encoding="utf-8").read()
statements = []
for chunk in raw.split(";"):
    lines = [l for l in chunk.splitlines() if not l.strip().startswith("--")]
    body = "\n".join(lines).strip()
    if body:
        statements.append(body.replace("\n", " "))
print("\x1e".join(statements))
PY

index=0
while IFS= read -r -d $'\x1e' statement || [ -n "$statement" ]; do
  [ -z "${statement// }" ] && continue
  index=$((index + 1))
  label="$(echo "$statement" | cut -c1-60)"
  echo "[$index] ${label}…"

  id="$(aws athena start-query-execution \
    --query-string "$statement" \
    --query-execution-context "Database=${DATABASE}" \
    --work-group "${WORKGROUP}" \
    --profile "${PROFILE}" --region "${REGION}" \
    --query QueryExecutionId --output text)"

  while true; do
    sleep 3
    state="$(aws athena get-query-execution --query-execution-id "$id" \
      --profile "${PROFILE}" --region "${REGION}" \
      --query 'QueryExecution.Status.State' --output text)"
    [ "$state" != "RUNNING" ] && [ "$state" != "QUEUED" ] && break
  done

  if [ "$state" != "SUCCEEDED" ]; then
    reason="$(aws athena get-query-execution --query-execution-id "$id" \
      --profile "${PROFILE}" --region "${REGION}" \
      --query 'QueryExecution.Status.StateChangeReason' --output text)"
    echo "    FALLÓ: $reason"
    exit 1
  fi
  echo "    ok"
done < /tmp/athena_statements.txt

echo "Listo: $index sentencia(s)."
