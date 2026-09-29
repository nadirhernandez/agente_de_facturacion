#!/usr/bin/env bash
# Carga masiva controlada de facturas sintéticas en el piloto.
#
#   BLOCKS bloques de BLOCK facturas, en archivos de 5,000. Cada bloque espera
#   a Glue (--process) y valida en Athena conteo y duplicados antes de seguir.
#   Durante la carga se pausa la regla de ingesta por evento (cada archivo
#   dispararía un reintento y una alerta falsa); al salir se reactiva.
#
# Uso: START=120001 BLOCKS=10 BLOCK=100000 scripts/bulk_load_invoices.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
export AWS_PROFILE="${AWS_PROFILE:-dashboards-dev-infile}" AWS_REGION="${AWS_REGION:-us-east-1}"

RULE=dashboards-dinamicos-raw-object-created-dev
START="${START:?START: primer número de factura (debe ser mayor al máximo cargado)}"
BLOCKS="${BLOCKS:-10}"
BLOCK="${BLOCK:-100000}"

q() {
  local id s
  id=$(aws athena start-query-execution --work-group dashboards-dinamicos-dev \
    --query-execution-context Database=sales_demo --query-string "$1" \
    --query QueryExecutionId --output text) || return 1
  for _ in $(seq 1 90); do
    s=$(aws athena get-query-execution --query-execution-id "$id" --query QueryExecution.Status.State --output text)
    [ "$s" = SUCCEEDED ] && break
    [ "$s" = FAILED ] || [ "$s" = CANCELLED ] && return 1
    sleep 2
  done
  aws athena get-query-results --query-execution-id "$id" --query 'ResultSet.Rows[1].Data[].VarCharValue' --output text
}

restore_rule() { aws events enable-rule --name "$RULE" && echo "regla $RULE reactivada"; }
trap restore_rule EXIT

BASE_DOCS=$(q "SELECT count(DISTINCT doc_id) FROM fct_lineas_factura") || { echo "ERROR: no se pudo leer el conteo inicial"; exit 1; }
echo "facturas antes de la carga: $BASE_DOCS"

aws events disable-rule --name "$RULE" && echo "regla $RULE desactivada durante la carga"

for block in $(seq 1 "$BLOCKS"); do
  if ! timeout 30 aws sts get-caller-identity >/dev/null 2>&1; then
    echo "ERROR: la sesión de AWS expiró antes del bloque $block; detengo la carga"
    exit 1
  fi
  start=$((START + (block - 1) * BLOCK))
  echo "=== bloque $block/$BLOCKS: facturas desde $start ($(date +%H:%M:%S))"
  if ! python3 -u scripts/produce_invoices.py --count $BLOCK --batch-size 5000 \
      --start-number "$start" --seed $((3000 + block)) --pause 2 --process; then
    echo "ERROR: el productor falló en el bloque $block; detengo la carga"
    exit 1
  fi

  expected=$((BASE_DOCS + block * BLOCK))
  read -r docs dups <<<"$(q "SELECT count(DISTINCT doc_id), count(*) - count(DISTINCT doc_id || '#' || CAST(linea AS varchar)) FROM fct_lineas_factura")"
  echo "validación bloque $block: facturas=$docs esperado=$expected duplicados=$dups"
  if [ "$docs" != "$expected" ] || [ "$dups" != "0" ]; then
    echo "ERROR: conteo inesperado; detengo la carga"
    exit 1
  fi
done

echo "=== carga completa ($(date +%H:%M:%S))"
