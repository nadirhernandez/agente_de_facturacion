# Acceso para invitados (demo sin cuenta)

Genera un link que permite a cualquier persona entrar a la app directamente,
sin que tenga que crear una cuenta ni escribir contraseña. Útil para demos,
revisiones con clientes o acceso temporal a un piloto.

## Cómo generar el link

```bash
export AWS_PROFILE=dashboards-dev-infile
bash scripts/create_guest_link.sh
```

El script imprime algo así:

```
Creando usuario temporal: guest-74bcffa5@infile-demo.com
Obteniendo tokens...
======================================================================
  Link de invitado listo
======================================================================

  URL:
  https://d3ocvrp9ma213b.cloudfront.net/#_gt=eyJpZFRv...

  Válido: 24 horas (el refresh token expira solo)
  Usuario Cognito: guest-74bcffa5@infile-demo.com

  Para revocar el acceso antes:
  aws cognito-idp admin-delete-user \
    --user-pool-id us-east-1_Di1X9vNSS \
    --username 'guest-74bcffa5@infile-demo.com' \
    --region us-east-1
======================================================================
```

Copia la URL y envíasela al invitado por el canal que prefieras (correo, chat, WhatsApp).

## Opciones

| Variable de entorno | Para qué | Ejemplo |
|---|---|---|
| `GUEST_EMAIL` | Usar un correo identificable en vez del generado al azar | `GUEST_EMAIL=cliente@empresa.com bash scripts/create_guest_link.sh` |

## Comportamiento del link

- El invitado hace **un solo clic** y entra directamente a la pantalla de chat.
- La sesión se renueva sola cada vez que el invitado siga activo; no hay un mensaje de "sesión a punto de expirar" a menos que lleve más de 5 minutos sin actividad cerca del vencimiento.
- El link funciona **una sola vez por navegador**: al abrirlo, la app guarda los tokens en `sessionStorage` y limpia el fragmento de la URL. Si el invitado lo envía a una tercera persona, esa persona puede usarlo en su propio navegador mientras los tokens sigan vigentes (máximo 60 minutos desde que se generó el link; para entrar después necesita que el link original se abra en el navegador donde fue generado… es decir, no es reutilizable de forma indefinida).
- Si el invitado pulsa **Cerrar sesión**, su sesión termina y no puede volver a entrar con ese link.

## Cuándo expira

| Qué | Cuándo |
|---|---|
| Sesión activa con renovación automática | Se renueva sola hasta que expira el refresh token |
| Refresh token | 24 horas desde que se generó el link |
| Forzar fin inmediato | Eliminar el usuario de Cognito (ver comando de revocación) |

> El piloto tiene `refresh_token_validity = 1 day`. Si en el futuro necesitas links de 6 horas exactas, cambia ese parámetro en `infrastructure/terraform/application.tf` y aplica.

## Revocar el acceso

Usa el comando que imprimió el script:

```bash
aws cognito-idp admin-delete-user \
  --user-pool-id us-east-1_Di1X9vNSS \
  --username 'guest-XXXXXXXX@infile-demo.com' \
  --region us-east-1 \
  --profile dashboards-dev-infile
```

Al eliminar el usuario de Cognito, la siguiente llamada a la API (cada 60 minutos) devolverá 401
y la app cerrará la sesión automáticamente.

## Listar usuarios de invitado activos

```bash
aws cognito-idp list-users \
  --user-pool-id us-east-1_Di1X9vNSS \
  --filter 'email ^= "guest-"' \
  --query 'Users[].{email:Username,creado:UserCreateDate,estado:UserStatus}' \
  --output table \
  --region us-east-1 \
  --profile dashboards-dev-infile
```

## Eliminar todos los invitados de una vez

```bash
aws cognito-idp list-users \
  --user-pool-id us-east-1_Di1X9vNSS \
  --filter 'email ^= "guest-"' \
  --query 'Users[].Username' \
  --output text \
  --region us-east-1 \
  --profile dashboards-dev-infile \
| tr '\t' '\n' \
| while read -r u; do
  aws cognito-idp admin-delete-user \
    --user-pool-id us-east-1_Di1X9vNSS \
    --username "$u" \
    --region us-east-1 \
    --profile dashboards-dev-infile
  echo "eliminado: $u"
done
```

## Cómo funciona (para quien quiera entender el mecanismo)

```text
scripts/create_guest_link.sh
  └─ admin-create-user (Cognito)          crea un usuario temporal
  └─ admin-set-user-password              contraseña aleatoria, permanente
  └─ AdminInitiateAuth                    obtiene id_token + refresh_token
  └─ base64url({idToken, refreshToken})   empaqueta los tokens
  └─ https://app/#_gt=<payload>           los mete en el fragmento de la URL

El navegador del invitado:
  └─ carga la app (CloudFront sirve el JS)
  └─ resolveSession() lee window.location.hash
  └─ decodifica el payload → guarda en sessionStorage
  └─ limpia el fragmento de la URL (history.replaceState)
  └─ la app sigue su flujo normal: llama a /embed, muestra el chat
```

Los tokens van en el **fragmento** (`#...`) de la URL, no en el query string. Los fragmentos
nunca se envían al servidor, por lo que no aparecen en los logs de CloudFront, API Gateway ni
ningún proxy intermedio.

## Seguridad

| Aspecto | Estado |
|---|---|
| Tokens en logs de servidor | ✅ No (fragmento de URL, nunca llega al servidor) |
| Contraseña del usuario temporal | ✅ Aleatoria, 15 caracteres, descartada tras obtener los tokens |
| Aislamiento entre invitados | ⚠️ Piloto usa identidad compartida de QuickSight; los invitados ven los mismos datos y (si coinciden) comparten la sesión del chat. Esto es aceptable para una demo con datos sintéticos. |
| Reutilización del link | ⚠️ Un link puede usarse una segunda vez en otro navegador mientras el id_token no haya expirado (máximo 60 minutos). Para una demo única, genera un link justo antes de enviarlo. |
| Eliminar acceso tras la demo | Ver "Revocar el acceso" arriba. |
