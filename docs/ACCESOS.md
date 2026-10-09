# Accesos a la app: quién entra y qué ve

Guía operativa, pensada para copiar y pegar. Todos los comandos se corren desde la **raíz del
proyecto** con el perfil `dashboards-dev-infile` ya autenticado (`aws sso login --profile
dashboards-dev-infile` si expiró).

App: https://d3ocvrp9ma213b.cloudfront.net

## La regla: el dominio del correo decide qué datos ve la persona

| Correo | Identidad de Quick que recibe | Qué ve |
|---|---|---|
| `@infile.com` | `app-infile-real` | **datos reales de INFILE** (agente "Analista de Ventas", dashboard real) |
| cualquier otro dominio | `app-demo-sintetico` | **demo con datos sintéticos** (agente "Analista de Ventas (Demo)", dashboard demo) |

La decisión la toma el servidor a partir del correo verificado por Cognito; la persona no puede
cambiarla. Cada identidad solo tiene permiso sobre sus propios datos en Quick, así que un prospecto
no puede llegar a los datos de INFILE ni manipulando la app. Detalle y barreras en
`APP_SECURITY.md`, sección "dos identidades".

**No hay que tocar QuickSight ni comprar licencias para dar acceso.** Las dos identidades ya existen
(2 licencias Reader Pro fijas). Dar acceso es solo crear el usuario en Cognito.

## Crear una cuenta con usuario y contraseña

```bash
# Persona de INFILE (verá datos reales). Cognito le envía la contraseña temporal por correo.
./scripts/create_app_user.sh persona@infile.com

# Igual, pero tú fijas la contraseña (sin correo). Temporal: la cambia al entrar.
./scripts/create_app_user.sh persona@infile.com --password 'Clave-Segura-2026!'

# Contraseña definitiva (no pide cambio). Útil para pruebas.
./scripts/create_app_user.sh persona@infile.com --password 'Clave-Segura-2026!' --permanent

# Prospecto (verá la demo sintética). Mismo comando, otro dominio.
./scripts/create_app_user.sh contacto@suempresa.com
```

Requisitos de contraseña: 12+ caracteres, mayúscula, minúscula, número y símbolo.

El script imprime qué va a ver la persona (real o demo) para que lo confirmes antes de avisarle.

## Cuenta demo permanente (compartible)

Para enseñar la demo sin generar links: una cuenta fija, sin vencimiento, que ve solo datos
sintéticos. Creada el 2026-10-08 con `--permanent`.

| Usuario | Contraseña | Ve |
|---|---|---|
| `demo@insight-demo.com` | `INsight-Demo-2026!` | demo sintética |

Cualquiera con estas credenciales entra; si hay que cerrarla, `./scripts/create_app_user.sh
demo@insight-demo.com --delete` (o cambiar la clave con `aws cognito-idp admin-set-user-password`).

## Link de invitado (sin cuenta, un solo uso)

```bash
bash scripts/create_guest_link.sh
```

Imprime una URL. El invitado la abre y entra directo, sin contraseña. El usuario es
`guest-xxxxxxxx@infile-demo.com`: dominio distinto de `infile.com`, así que **siempre ve la demo
sintética**. Nunca datos reales.

Duración:

- **Link sin abrir:** 24 horas, luego se borra solo de S3.
- **Un solo uso:** al abrirlo se consume; reenviado ya no sirve.
- **Sesión una vez dentro:** 24 horas (el refresh token dura 1 día); luego muere y no hay reingreso.

Los usuarios `guest-…` **no se borran solos** al expirar; se acumulan en Cognito. Limpieza en
`ACCESO_INVITADOS.md`.

## Revocar un acceso

```bash
./scripts/create_app_user.sh persona@infile.com --delete
```

Si la persona tiene la app abierta, su sesión muere al vencer el token (máximo 1 hora).

## Ver quién tiene acceso

```bash
aws cognito-idp list-users --user-pool-id us-east-1_Di1X9vNSS \
  --query 'Users[].{usuario:Username,estado:UserStatus,habilitado:Enabled}' \
  --output table --profile dashboards-dev-infile --region us-east-1
```

## Comprobar que la separación sigue intacta

Correr después de cualquier cambio en Quick (datasets, agentes, permisos):

```bash
python3 scripts/quicksight/grant_chat_access.py --set demo --principal app-demo-sintetico --audit
python3 scripts/quicksight/grant_chat_access.py --set real --principal app-infile-real --audit
```

Cada uno debe terminar en `OK: la identidad ve solo su juego.` Si falla, señala exactamente qué
recurso está de más o de menos.

## Límites de este modelo (prototipo)

- Las personas de INFILE comparten la identidad `app-infile-real`: no ven las conversaciones de
  otros (modo privado, sin historial), pero no hay historial individual. Para eso: un usuario de
  Quick por correo, como hace el módulo de clientes.
- Sirve para **un** conjunto de datos reales. Un segundo cliente real va en su propia cuenta AWS
  (`PRINCIPIOS_DESPLIEGUE.md`), no en una tercera identidad.
- El registro público está deshabilitado a propósito: solo un administrador crea usuarios.

## El correo de invitación

Cuando se crea una cuenta sin `--password`, Cognito envía la invitación con la plantilla de
INsight (asunto "Su acceso a INsight by INFILE", HTML con marca, usuario, contraseña temporal y
botón a la app). La plantilla vive en `infrastructure/terraform/application.tf`
(`local.invite_email_html`); al cambiarla, `terraform apply -target=aws_cognito_user_pool.app`.

Para reenviar la invitación a alguien que aún no ha entrado:

```bash
aws cognito-idp admin-create-user --user-pool-id us-east-1_Di1X9vNSS \
  --username persona@infile.com --message-action RESEND --desired-delivery-mediums EMAIL \
  --profile dashboards-dev-infile --region us-east-1
```

**Remitente.** Hoy sale de `no-reply@verificationemail.com` (el de Cognito): llega a cualquier
destinatario, límite 50 correos/día. Para que salga de una dirección de INFILE vía SES:

1. Sacar la cuenta de SES del sandbox (consola SES → "Request production access"; ~24 h). En
   sandbox SES solo entrega a direcciones verificadas, por eso **no se activa antes**: los
   prospectos no recibirían la invitación. Conviene verificar el dominio `infile.com` en SES para
   poder usar un remitente como `insight@infile.com`.
2. En Terraform poner `cognito_email_via_ses = true` (y ajustar `cognito_from_email` /
   `cognito_ses_source_arn` si se usa otra identidad) y aplicar el pool.

**Probar cómo le llega a alguien.** Si el correo de INFILE es Google Workspace, crear la cuenta
con un alias propio (`rnhernandez+prueba@infile.com`): Google lo entrega al buzón de
`rnhernandez@infile.com`, pero para Cognito es un usuario distinto, así se ve la invitación
completa sin tocar la cuenta real. Borrarlo después con `--delete`.
