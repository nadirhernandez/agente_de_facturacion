#!/usr/bin/env bash
# Prueba de humo del usuario de la app contra la API de embedding autenticada.
#
#   1. Restablece la contraseña del usuario (pide confirmación, o --yes).
#   2. Inicia sesión con ADMIN_USER_PASSWORD_AUTH y obtiene el IdToken.
#   3. Pide una URL de embedding para el dashboard y para el chat.
#
# LIMITACIÓN CONOCIDA: el app client que crea Terraform solo permite
# ALLOW_USER_SRP_AUTH y ALLOW_REFRESH_TOKEN_AUTH. Con esa configuración el paso 2
# no puede funcionar: Cognito rechaza ADMIN_USER_PASSWORD_AUTH. El script lo
# comprueba ANTES de tocar la contraseña y se detiene con un mensaje claro; en ese
# caso prueba el inicio de sesión desde el navegador (la app usa SRP).
# Además la API exige que el email del token esté verificado y sea del dominio
# infile.com; un usuario fuera de ese dominio recibirá un rechazo en el paso 3.
#
# Uso:
#   ./scripts/provision_app_user.sh [--yes]
#
# Variables de entorno (por defecto, los valores del piloto):
#   POOL_ID, CLIENT_ID, APP_USERNAME, API, AWS_PROFILE, AWS_REGION
#   SAVE_PASSWORD=1  guarda la nueva contraseña en ~/.ventas-inteligentes-dev-password
#                    (solo legible por tu usuario). Sin esto no se guarda en disco.
set -euo pipefail

POOL_ID="${POOL_ID:-us-east-1_Di1X9vNSS}"
CLIENT_ID="${CLIENT_ID:-33onu8vmtitrcaegfq88gpssie}"
APP_USERNAME="${APP_USERNAME:-rnhernandez@infile.com}"
API="${API:-https://przb6i4xl5.execute-api.us-east-1.amazonaws.com}"
PROFILE="${AWS_PROFILE:-dashboards-dev-infile}"
REGION="${AWS_REGION:-us-east-1}"
PW_FILE="${HOME}/.ventas-inteligentes-dev-password"
SAVE_PASSWORD="${SAVE_PASSWORD:-0}"

ASSUME_YES=0
for arg in "$@"; do
  case "${arg}" in
    --yes|-y) ASSUME_YES=1 ;;
    *) echo "Argumento desconocido: ${arg}" >&2; echo "uso: provision_app_user.sh [--yes]" >&2; exit 2 ;;
  esac
done

# Todo lo sensible (contraseña, token, respuestas) vive en un directorio privado
# que se borra al salir, pase lo que pase.
umask 077
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/vi-smoke.XXXXXX")"
trap 'rm -rf "${WORK_DIR}"' EXIT
chmod 700 "${WORK_DIR}"

aws_q() { aws "$@" --profile "${PROFILE}" --region "${REGION}"; }

echo "Pool ${POOL_ID} · client ${CLIENT_ID} · usuario ${APP_USERNAME}"
echo "API ${API} · perfil ${PROFILE} · región ${REGION}"
echo

# 0. Sin el flujo de administrador habilitado, restablecer la contraseña solo
#    dejaría al usuario con una credencial nueva que este script no puede usar.
flows="$(aws_q cognito-idp describe-user-pool-client \
  --user-pool-id "${POOL_ID}" --client-id "${CLIENT_ID}" \
  --query 'UserPoolClient.ExplicitAuthFlows' --output text | tr '\t' ' ')"
case " ${flows} " in
  *" ALLOW_ADMIN_USER_PASSWORD_AUTH "*|*" ADMIN_NO_SRP_AUTH "*) ;;
  *)
    echo "El app client no permite ADMIN_USER_PASSWORD_AUTH (flujos: ${flows:-ninguno})." >&2
    echo "No se tocó la contraseña. Prueba el inicio de sesión desde el navegador:" >&2
    echo "la app usa SRP, que es lo que Terraform habilita." >&2
    exit 3
    ;;
esac

# 1. Restablecer la contraseña es destructivo: la anterior deja de servir.
if [ "${ASSUME_YES}" -ne 1 ]; then
  if [ ! -t 0 ]; then
    echo "Sin terminal interactiva: usa --yes para confirmar el cambio de contraseña." >&2
    exit 2
  fi
  echo "Se va a RESTABLECER la contraseña de ${APP_USERNAME}; la actual dejará de funcionar."
  if [ "${SAVE_PASSWORD}" = "1" ]; then
    echo "La nueva se guardará en ${PW_FILE}."
  else
    echo "La nueva NO se guardará (usa SAVE_PASSWORD=1 si la necesitas)."
  fi
  read -r -p "¿Continuar? [s/N] " answer
  case "${answer}" in
    s|S|si|SI|Si|sí|Sí|SÍ) ;;
    *) echo "Cancelado. No se hizo ningún cambio."; exit 1 ;;
  esac
fi

# La contraseña se genera y se escribe directo en los JSON de entrada del CLI:
# nunca pasa por argv ni por una variable de bash.
save_target=""
if [ "${SAVE_PASSWORD}" = "1" ]; then
  save_target="${PW_FILE}"
fi
python3 - "${WORK_DIR}" "${POOL_ID}" "${CLIENT_ID}" "${APP_USERNAME}" "${save_target}" <<'PY'
import json, os, secrets, string, sys

work_dir, pool_id, client_id, username, pw_file = sys.argv[1:6]
alphabet = string.ascii_letters + string.digits
password = "Vi." + "".join(secrets.choice(alphabet) for _ in range(14)) + "_9"


def write_private(path, text):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(text)
    os.chmod(path, 0o600)


write_private(os.path.join(work_dir, "set-password.json"), json.dumps({
    "UserPoolId": pool_id,
    "Username": username,
    "Password": password,
    "Permanent": True,
}))
write_private(os.path.join(work_dir, "auth.json"), json.dumps({
    "UserPoolId": pool_id,
    "ClientId": client_id,
    "AuthFlow": "ADMIN_USER_PASSWORD_AUTH",
    "AuthParameters": {"USERNAME": username, "PASSWORD": password},
}))
if pw_file:
    write_private(pw_file, password + "\n")
PY

aws_q cognito-idp admin-set-user-password \
  --cli-input-json "file://${WORK_DIR}/set-password.json"
echo "1/3 credencial establecida"

# 2. Inicio de sesión. Si falla, no hay nada más que probar por esta vía.
if ! TOKEN="$(aws_q cognito-idp admin-initiate-auth \
    --cli-input-json "file://${WORK_DIR}/auth.json" \
    --query 'AuthenticationResult.IdToken' --output text 2>"${WORK_DIR}/auth.err")" \
   || [ -z "${TOKEN}" ] || [ "${TOKEN}" = "None" ]; then
  echo "2/3 FALLÓ el inicio de sesión con ADMIN_USER_PASSWORD_AUTH." >&2
  sed 's/^/    /' "${WORK_DIR}/auth.err" >&2 || true
  echo "    Prueba el inicio de sesión desde el navegador (flujo SRP de la app)." >&2
  exit 4
fi
rm -f "${WORK_DIR}/auth.json" "${WORK_DIR}/set-password.json"
echo "2/3 login correcto, token emitido"

# El token va en un archivo de cabeceras para que no aparezca en `ps`.
printf 'Authorization: Bearer %s\n' "${TOKEN}" > "${WORK_DIR}/headers"
unset TOKEN

failures=0
for experience in dashboard chat; do
  response="$(mktemp "${WORK_DIR}/embed.XXXXXX")"
  code="$(curl -sS --max-time 20 -o "${response}" -w '%{http_code}' \
    -H "@${WORK_DIR}/headers" \
    "${API}/embed?experience=${experience}")" || code="${code:-000}"
  printf '3/3 %s: HTTP %s ' "${experience}" "${code}"
  if ! python3 - "${response}" <<'PY'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        data = json.load(handle)
except (OSError, ValueError):
    print("respuesta no es JSON")
    sys.exit(1)
if isinstance(data, dict) and data.get("embedUrl"):
    print("embedUrl OK")
else:
    print(data)
    sys.exit(1)
PY
  then
    failures=$((failures + 1))
  fi
done

if [ "${SAVE_PASSWORD}" = "1" ]; then
  echo "Credencial guardada en ${PW_FILE}"
else
  echo "La credencial no se guardó. Si la necesitas, usa \"Olvidé mi contraseña\" en la app."
fi

if [ "${failures}" -gt 0 ]; then
  echo "La API no devolvió embedUrl en ${failures} experiencia(s)." >&2
  echo "Recuerda: el email del token debe estar verificado y ser de infile.com." >&2
  exit 1
fi
