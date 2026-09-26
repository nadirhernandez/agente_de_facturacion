#!/usr/bin/env bash
# Provision the initial app user and smoke-test the authenticated embed API.
set -euo pipefail

POOL_ID="us-east-1_Di1X9vNSS"
CLIENT_ID="33onu8vmtitrcaegfq88gpssie"
USERNAME="rnhernandez@infile.com"
API="https://przb6i4xl5.execute-api.us-east-1.amazonaws.com"
PROFILE="dashboards-dev-infile"
REGION="us-east-1"
PW_FILE="${HOME}/.ventas-inteligentes-dev-password"

PASSWORD="$(python3 -c "import secrets,string; a=string.ascii_letters+string.digits; print('Vi.' + ''.join(secrets.choice(a) for _ in range(14)) + '_9')")"

umask 077
printf '%s\n' "${PASSWORD}" > "${PW_FILE}"

aws cognito-idp admin-set-user-password \
  --user-pool-id "${POOL_ID}" --username "${USERNAME}" \
  --password "${PASSWORD}" --permanent \
  --profile "${PROFILE}" --region "${REGION}"
echo "1/3 credencial establecida"

TOKEN="$(aws cognito-idp admin-initiate-auth \
  --user-pool-id "${POOL_ID}" --client-id "${CLIENT_ID}" \
  --auth-flow ADMIN_USER_PASSWORD_AUTH \
  --auth-parameters "USERNAME=${USERNAME},PASSWORD=${PASSWORD}" \
  --profile "${PROFILE}" --region "${REGION}" \
  --query 'AuthenticationResult.IdToken' --output text)"
echo "2/3 login correcto, token emitido"

for experience in dashboard chat; do
  code="$(curl -s -o /tmp/vi_embed.json -w '%{http_code}' \
    -H "Authorization: Bearer ${TOKEN}" \
    "${API}/embed?experience=${experience}")"
  result="$(python3 -c "import json;d=json.load(open('/tmp/vi_embed.json'));print('embedUrl OK' if d.get('embedUrl') else d)")"
  echo "3/3 ${experience}: HTTP ${code} ${result}"
done

echo "Credencial guardada en ${PW_FILE}"
