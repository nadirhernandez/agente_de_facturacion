#!/usr/bin/env bash
# Verify a freshly provisioned tenant account end to end, including a real data
# round trip. Run this before telling the client the solution is ready.
#
# Usage:
#   AWS_PROFILE=<perfil-cliente> ./scripts/verify_tenant.sh <tenant_id> <account_id> [--with-data]
#
# --with-data uploads a small sample of invoices and waits for the whole pipeline
# to complete. Without it, only configuration is checked.
set -uo pipefail

TENANT_ID="${1:?uso: verify_tenant.sh <tenant_id> <account_id> [--with-data]}"
ACCOUNT_ID="${2:?falta account_id}"
WITH_DATA="${3:-}"
REGION="${AWS_REGION:-us-east-1}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PREFIX="vi-${TENANT_ID}-${ENVIRONMENT:-prod}"
BUCKET="vi-${TENANT_ID}-data-${ACCOUNT_ID}"
DATABASE="ventas_${TENANT_ID//-/_}"
WORKGROUP="${PREFIX}"
GLUE_JOB="${PREFIX}-flatten-invoices"
WEB_BUCKET="vi-${TENANT_ID}-web-${ACCOUNT_ID}"
COGNITO_DOMAIN="vi-${TENANT_ID}-${ACCOUNT_ID}"
EMBEDDING_API="${PREFIX}-embedding-api"

passed=0
failed=0

check() {
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    printf '  ✓ %s\n' "$label"
    passed=$((passed + 1))
  else
    printf '  ✗ %s\n' "$label"
    failed=$((failed + 1))
  fi
}

aws_q() { aws "$@" --region "${REGION}"; }

echo "Verificando ${TENANT_ID} en la cuenta ${ACCOUNT_ID}"
echo
echo "Identidad"
actual="$(aws_q sts get-caller-identity --query Account --output text 2>/dev/null)"
if [ "${actual}" = "${ACCOUNT_ID}" ]; then
  printf '  ✓ sesión en la cuenta correcta\n'
  passed=$((passed + 1))
else
  printf '  ✗ sesión apunta a %s, se esperaba %s\n' "${actual:-ninguna}" "${ACCOUNT_ID}"
  echo "    Abortando: no verifiques un cliente con credenciales de otro."
  exit 1
fi

echo
echo "Almacenamiento"
check "bucket de datos existe" aws_q s3api head-bucket --bucket "${BUCKET}"
check "acceso público bloqueado" bash -c \
  "aws s3api get-public-access-block --bucket '${BUCKET}' --region '${REGION}' \
   --query 'PublicAccessBlockConfiguration.BlockPublicAcls' --output text | grep -q True"
check "cifrado en reposo" aws_q s3api get-bucket-encryption --bucket "${BUCKET}"
check "versionado activo" bash -c \
  "aws s3api get-bucket-versioning --bucket '${BUCKET}' --region '${REGION}' \
   --query Status --output text | grep -q Enabled"
check "eventos habilitados" bash -c \
  "aws s3api get-bucket-notification-configuration --bucket '${BUCKET}' --region '${REGION}' \
   --query EventBridgeConfiguration --output text | grep -qv None"

echo
echo "Catálogo y consulta"
check "base de datos Glue" aws_q glue get-database --name "${DATABASE}"
# Tablas y vistas salen de sql/model: la Lambda deploy-views las crea en el apply.
for table in fct_lineas_factura ctl_archivos_procesados agg_ventas_diario; do
  check "tabla Iceberg ${table}" bash -c \
    "aws glue get-table --database-name '${DATABASE}' --name '${table}' --region '${REGION}' \
     --query 'Table.Parameters.table_type' --output text | grep -qx ICEBERG"
done
for view in vw_ventas_comerciales vw_calendario vw_ventas_diario vw_ventas_comparativo; do
  check "vista ${view}" aws_q glue get-table --database-name "${DATABASE}" --name "${view}"
done
check "refresco incremental configurado" bash -c \
  "aws quicksight describe-data-set-refresh-properties --aws-account-id '${ACCOUNT_ID}' \
   --data-set-id '${PREFIX}-ventas' --region '${REGION}' \
   --query 'DataSetRefreshProperties.RefreshConfiguration.IncrementalRefresh.LookbackWindow.ColumnName' \
   --output text | grep -qx fecha"
check "workgroup de Athena" aws_q athena get-work-group --work-group "${WORKGROUP}"
check "job de transformación" aws_q glue get-job --job-name "${GLUE_JOB}"

echo
echo "Automatización"
for fn in start-ingestion refresh-spice sales-alerts deploy-views; do
  check "lambda ${fn}" aws_q lambda get-function --function-name "${PREFIX}-${fn}"
done
check "regla de archivo nuevo" aws_q events describe-rule --name "${PREFIX}-raw-created"
check "regla de carga completada" aws_q events describe-rule --name "${PREFIX}-glue-succeeded"
check "revisión semanal" aws_q events describe-rule --name "${PREFIX}-weekly-review"

echo
echo "QuickSight"
check "suscripción activa" aws_q quicksight describe-account-settings --aws-account-id "${ACCOUNT_ID}"
check "origen de datos Athena" aws_q quicksight describe-data-source \
  --aws-account-id "${ACCOUNT_ID}" --data-source-id "${PREFIX}-athena"
check "dataset de ventas" aws_q quicksight describe-data-set \
  --aws-account-id "${ACCOUNT_ID}" --data-set-id "${PREFIX}-ventas"
check "dataset por periodo" aws_q quicksight describe-data-set \
  --aws-account-id "${ACCOUNT_ID}" --data-set-id "${PREFIX}-periodos"

echo
echo "Aplicación"
check "bucket del frontend" aws_q s3api head-bucket --bucket "${WEB_BUCKET}"
check "frontend sin acceso público" bash -c \
  "aws s3api get-public-access-block --bucket '${WEB_BUCKET}' --region '${REGION}' \
   --query 'PublicAccessBlockConfiguration.BlockPublicAcls' --output text | grep -q True"
check "config.json publicado por Terraform" aws_q s3api head-object \
  --bucket "${WEB_BUCKET}" --key config.json
# Sin esto la app existe pero sirve una página vacía: falta scripts/deploy_app.sh.
check "SPA publicado (index.html)" aws_q s3api head-object \
  --bucket "${WEB_BUCKET}" --key index.html
check "user pool de la app" bash -c \
  "aws cognito-idp list-user-pools --max-results 60 --region '${REGION}' \
   --query \"UserPools[?Name=='${PREFIX}-app'].Id\" --output text | grep -q ."
check "dominio de inicio de sesión activo" bash -c \
  "aws cognito-idp describe-user-pool-domain --domain '${COGNITO_DOMAIN}' --region '${REGION}' \
   --query DomainDescription.Status --output text | grep -q ACTIVE"
check "API de embedding" bash -c \
  "aws apigatewayv2 get-apis --region '${REGION}' \
   --query \"Items[?Name=='${EMBEDDING_API}'].ApiId\" --output text | grep -q ."
check "lambda de embedding" aws_q lambda get-function --function-name "${EMBEDDING_API}"
# La identidad de reserva del piloto daba permisos de administrador a cualquiera
# que iniciara sesión sin usuario propio de QuickSight. No debe existir aquí.
check "sin identidad de QuickSight de reserva" bash -c \
  "aws lambda get-function-configuration --function-name '${EMBEDDING_API}' --region '${REGION}' \
   --query 'Environment.Variables.FALLBACK_QUICKSIGHT_USER_ARN' --output text | grep -qx None"

# La distribución se identifica por su origen, que es el bucket del frontend.
app_domain="$(aws_q cloudfront list-distributions \
  --query "DistributionList.Items[?Origins.Items[0].DomainName=='${WEB_BUCKET}.s3.${REGION}.amazonaws.com'].DomainName | [0]" \
  --output text 2>/dev/null)"

if [ -n "${app_domain}" ] && [ "${app_domain}" != "None" ]; then
  printf '  ✓ distribución de CloudFront: %s\n' "${app_domain}"
  passed=$((passed + 1))
  check "la app responde por HTTPS" bash -c \
    "curl -fsS -o /dev/null --max-time 15 'https://${app_domain}/'"
else
  printf '  ✗ no se encontró la distribución de CloudFront del frontend\n'
  failed=$((failed + 1))
fi

api_endpoint="$(aws_q apigatewayv2 get-apis \
  --query "Items[?Name=='${EMBEDDING_API}'].ApiEndpoint | [0]" --output text 2>/dev/null)"
if [ -n "${api_endpoint}" ] && [ "${api_endpoint}" != "None" ]; then
  # Toda ruta exige JWT. Un 200 aquí sería una fuga de URLs de embedding.
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "${api_endpoint}/status")"
  if [ "${code}" = "401" ]; then
    printf '  ✓ la API rechaza peticiones sin token (401)\n'
    passed=$((passed + 1))
  else
    printf '  ✗ la API respondió %s sin token, se esperaba 401\n' "${code}"
    failed=$((failed + 1))
  fi
fi

if [ "${WITH_DATA}" = "--with-data" ]; then
  echo
  echo "Prueba de datos de punta a punta"
  sample="/tmp/verify-${TENANT_ID}.jsonl"
  python3 "${ROOT}/scripts/produce_invoices.py" --count 200 --batch-size 200 --seed 99 --dry-run >/dev/null 2>&1
  python3 - "$sample" <<'PY'
import json, random, sys
sys.path.insert(0, "scripts")
import generate_sales_demo as factory
from datetime import date, timedelta
factory.RANDOM = random.Random(99)
today = date.today()
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    for number in range(1, 201):
        issue = today - timedelta(days=random.randint(0, 120))
        invoice, _l, _d = factory.create_invoice(900000 + number, issue)
        handle.write(json.dumps(invoice, ensure_ascii=False) + "\n")
PY

  key="raw/dte/country=gt/ingest_date=$(date +%F)/verify-$(date +%s).jsonl"
  if aws_q s3 cp "$sample" "s3://${BUCKET}/${key}" --only-show-errors; then
    printf '  ✓ archivo de prueba depositado\n'
    passed=$((passed + 1))
  else
    printf '  ✗ no se pudo depositar el archivo de prueba\n'
    failed=$((failed + 1))
  fi

  printf '  · esperando la transformación automática'
  state=""
  for _ in $(seq 1 30); do
    sleep 20
    printf '.'
    state="$(aws_q glue get-job-runs --job-name "${GLUE_JOB}" --max-results 1 \
      --query 'JobRuns[0].JobRunState' --output text 2>/dev/null)"
    [ "${state}" = "SUCCEEDED" ] && break
    [ "${state}" = "FAILED" ] && break
  done
  echo

  if [ "${state}" = "SUCCEEDED" ]; then
    printf '  ✓ transformación completada\n'
    passed=$((passed + 1))
  else
    printf '  ✗ transformación en estado %s\n' "${state:-desconocido}"
    failed=$((failed + 1))
  fi

  echo "  · consultando la vista certificada"
  qid="$(aws_q athena start-query-execution \
    --query-string "SELECT count(*) AS lineas, count(DISTINCT factura_id) AS facturas FROM ${DATABASE}.vw_ventas_comerciales" \
    --query-execution-context "Database=${DATABASE}" --work-group "${WORKGROUP}" \
    --query QueryExecutionId --output text 2>/dev/null)"
  sleep 12
  result="$(aws_q athena get-query-results --query-execution-id "${qid}" \
    --query 'ResultSet.Rows[1].Data[].VarCharValue' --output text 2>/dev/null)"

  if [ -n "${result}" ]; then
    printf '  ✓ datos consultables: %s\n' "${result}"
    passed=$((passed + 1))
  else
    printf '  ✗ la vista no devolvió datos\n'
    failed=$((failed + 1))
  fi

  printf '  · esperando el refresco de SPICE'
  for _ in $(seq 1 15); do
    sleep 20
    printf '.'
    status="$(aws_q quicksight list-ingestions --aws-account-id "${ACCOUNT_ID}" \
      --data-set-id "${PREFIX}-ventas" --query 'Ingestions[0].IngestionStatus' --output text 2>/dev/null)"
    [ "${status}" = "COMPLETED" ] && break
  done
  echo

  if [ "${status}" = "COMPLETED" ]; then
    rows="$(aws_q quicksight list-ingestions --aws-account-id "${ACCOUNT_ID}" \
      --data-set-id "${PREFIX}-ventas" --query 'Ingestions[0].RowInfo.RowsIngested' --output text)"
    printf '  ✓ SPICE actualizado con %s filas\n' "${rows}"
    passed=$((passed + 1))
  else
    printf '  ✗ SPICE en estado %s\n' "${status:-desconocido}"
    failed=$((failed + 1))
  fi
fi

echo
echo "Resultado: ${passed} correctas, ${failed} con problema"

if [ "${failed}" -gt 0 ]; then
  echo "No entregues la cuenta al cliente hasta resolver lo marcado."
  exit 1
fi

echo "Cuenta lista. Al depositar archivos en s3://${BUCKET}/raw/dte/ el cliente ya puede consultar sus datos."

if [ -n "${app_domain}" ] && [ "${app_domain}" != "None" ]; then
  echo "La app del cliente responde en https://${app_domain}/"
fi
