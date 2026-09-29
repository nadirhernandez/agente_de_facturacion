#!/usr/bin/env bash
# Genera un link de acceso temporal para que un invitado pruebe la demo sin crear cuenta.
#
# Uso:
#   ./scripts/create_guest_link.sh                           # guest@infile-demo.com
#   GUEST_EMAIL=cliente@empresa.com ./scripts/create_guest_link.sh
#   GUEST_EMAIL=demo@test.com HOURS=6 ./scripts/create_guest_link.sh
#
# Qué hace:
#   1. Crea un usuario de Cognito temporal con contraseña aleatoria.
#   2. Obtiene sus tokens con AdminInitiateAuth.
#   3. Genera una URL de la forma https://app/#_gt=<base64url(tokens)>.
#   4. Imprime la URL y el comando para revocar el acceso cuando ya no se necesite.
#
# El invitado hace clic en el link, entra directo a la app y la sesión expira sola
# cuando el refresh token vence (24 horas por defecto en el piloto).
# Puedes forzar el fin de la sesión antes con el comando de revocación que se imprime.
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
APP_URL="https://d3ocvrp9ma213b.cloudfront.net"

# Lee la config de la app para obtener User Pool y Client ID.
CONFIG_JSON=$(aws s3 cp "s3://dashboards-dinamicos-web-503561412084/config.json" - 2>/dev/null \
  || curl -s "${APP_URL}/config.json")
COGNITO_DOMAIN=$(echo "$CONFIG_JSON" | node -pe "JSON.parse(require('fs').readFileSync(0,'utf8')).cognitoDomain")
CLIENT_ID=$(echo "$CONFIG_JSON" | node -pe "JSON.parse(require('fs').readFileSync(0,'utf8')).cognitoClientId")

# User Pool ID: busca el pool cuyo dominio del custom domain coincide con el prefijo del cognitoDomain.
# El domain se almacena en UserPool.Domain (sin el sufijo .auth.<region>.amazoncognito.com).
DOMAIN_PREFIX="${COGNITO_DOMAIN#https://}"
DOMAIN_PREFIX="${DOMAIN_PREFIX%%.auth.*}"
USER_POOL_ID=$(aws cognito-idp list-user-pools --max-results 20 --region "$REGION" \
  --query "UserPools[].Id" --output text | tr '\t' '\n' | while read -r id; do
    D=$(aws cognito-idp describe-user-pool --user-pool-id "$id" --query "UserPool.Domain" --output text --region "$REGION" 2>/dev/null)
    [ "$D" = "$DOMAIN_PREFIX" ] && echo "$id" && break
  done)
if [ -z "$USER_POOL_ID" ]; then
  echo "No se encontró el User Pool para el dominio ${DOMAIN_PREFIX}." >&2; exit 1
fi

# Identidad del invitado.
RANDOM_SUFFIX=$(openssl rand -hex 4)
GUEST_EMAIL="${GUEST_EMAIL:-guest-${RANDOM_SUFFIX}@infile-demo.com}"
# secrets.token_urlsafe generates URL-safe chars; appending fixed chars satisfies
# Cognito's uppercase + digit + symbol requirements.
GUEST_PASSWORD=$(python3 -c "import secrets; print(secrets.token_urlsafe(12)+'A1!')")

echo "Creando usuario temporal: ${GUEST_EMAIL}"
aws cognito-idp admin-create-user \
  --user-pool-id "$USER_POOL_ID" \
  --username "$GUEST_EMAIL" \
  --temporary-password "$GUEST_PASSWORD" \
  --message-action SUPPRESS \
  --region "$REGION" >/dev/null

aws cognito-idp admin-set-user-password \
  --user-pool-id "$USER_POOL_ID" \
  --username "$GUEST_EMAIL" \
  --password "$GUEST_PASSWORD" \
  --permanent \
  --region "$REGION"

echo "Obteniendo tokens..."
TOKENS=$(aws cognito-idp admin-initiate-auth \
  --user-pool-id "$USER_POOL_ID" \
  --client-id "$CLIENT_ID" \
  --auth-flow ADMIN_USER_PASSWORD_AUTH \
  --auth-parameters "USERNAME=${GUEST_EMAIL},PASSWORD=${GUEST_PASSWORD}" \
  --region "$REGION" \
  --query "AuthenticationResult" \
  --output json)

ID_TOKEN=$(echo "$TOKENS" | node -pe "JSON.parse(require('fs').readFileSync(0,'utf8')).IdToken")
REFRESH_TOKEN=$(echo "$TOKENS" | node -pe "JSON.parse(require('fs').readFileSync(0,'utf8')).RefreshToken")

# Codifica los tokens en base64url (sin padding) — nunca se envían al servidor.
PAYLOAD=$(node -e "
  const p=JSON.stringify({idToken:'${ID_TOKEN}',refreshToken:'${REFRESH_TOKEN}'});
  const b=Buffer.from(p).toString('base64').replace(/\+/g,'-').replace(/\//g,'_').replace(/=+$/,'');
  console.log(b);
")

MAGIC_LINK="${APP_URL}/#_gt=${PAYLOAD}"

echo
echo "======================================================================"
echo "  Link de invitado listo"
echo "======================================================================"
echo
echo "  URL:"
echo "  ${MAGIC_LINK}"
echo
echo "  Válido: 24 horas (el refresh token expira solo)"
echo "  Usuario Cognito: ${GUEST_EMAIL}"
echo
echo "  Para revocar el acceso antes:"
echo "  aws cognito-idp admin-delete-user \\"
echo "    --user-pool-id ${USER_POOL_ID} \\"
echo "    --username '${GUEST_EMAIL}' \\"
echo "    --region ${REGION}"
echo "======================================================================"
