# Runbook — Ventas Inteligentes (dev)

## Accesos desplegados

| Qué | Dónde |
|---|---|
| Aplicación | https://d3ocvrp9ma213b.cloudfront.net |
| API de embedding | https://przb6i4xl5.execute-api.us-east-1.amazonaws.com |
| Hosted UI Cognito | https://ventas-inteligentes-dev-503561412084.auth.us-east-1.amazoncognito.com |
| Client ID (público) | `33onu8vmtitrcaegfq88gpssie` |
| Usuario inicial | `rnhernandez@infile.com` |

Cognito envía la contraseña temporal por correo. En el primer ingreso pide cambiarla.

## Fecha de negocio: UTC-06:00

Todas las fechas del modelo son fechas civiles de Guatemala (UTC-06:00, sin horario de verano):
Glue corre su sesión en `-06:00`, `fecha_emision` guarda la hora local y `fecha` el día local. Una
factura emitida a las 19:30 pertenece a ese día. Las vistas usan `current_timestamp AT TIME ZONE
'-06:00'` para saber qué período está en curso.

Después de desplegar este cambio hay que **reprocesar una vez** el histórico, porque las cargas
anteriores usaban UTC y movían al día siguiente lo emitido desde las 18:00:

```bash
aws glue start-job-run --job-name dashboards-dinamicos-flatten-invoices-dev \
  --arguments '{"--REPROCESS_ALL":"true"}' --profile dashboards-dev-infile --region us-east-1
```

El reproceso empareja líneas por `(doc_id, linea)` en toda la tabla, así que una línea que cambia
de día se mueve (no se duplica) y se recalculan los totales del día que deja y del que recibe. Al
terminar, la cadena normal despliega vistas y refresca SPICE completo.

Registros que no se pueden confiar (JSON inválido, sin `doc_id`, fecha ilegible, estado desconocido,
línea sin número o monto) no entran al modelo: van a `quarantine/run=<id>/` y llega un correo con el
detalle (`quarantine/_avisos/`).

## Entrega interna: autoregistro @infile.com e identidad compartida

- Cualquier persona con correo `@infile.com` crea su cuenta desde **Crear cuenta** en la app.
  Cognito le envía un código al correo y, al confirmarlo, ya puede entrar. Otros dominios se
  rechazan en el registro (Lambda `dashboards-dinamicos-cognito-pre-signup-dev`) y de nuevo en la
  API (`ALLOWED_EMAIL_DOMAINS`).
- Todos abren el dashboard y el chat **como el mismo usuario de QuickSight** (el dueño del
  dashboard y del agente), vía `SHARED_QUICKSIGHT_USER_ARN` en la Lambda de embedding. Comparten sus
  permisos y su historial de chat. La persistencia de filtros del dashboard se desactiva en este
  modo para que los filtros de uno no aparezcan en la sesión de otro.
- Quién abrió qué queda en el log de la Lambda de embedding (`Embed URL issued`, campo `caller` =
  `sub` de Cognito).
- El correo de Cognito sale del remitente por defecto (`no-reply@verificationemail.com`, límite de
  50 correos al día). Si no llega, revisar spam.
- Para volver a una identidad por persona: quitar `SHARED_QUICKSIGHT_USER_ARN` de
  `application.tf`, crear un usuario de QuickSight por correo y aplicar.

## Primer uso

1. Abrir la aplicación.
2. Elegir **Iniciar sesión**; redirige al Hosted UI de Cognito.
3. Autenticarse y volver a la app (intercambio de código con PKCE).
4. **Pulso comercial** muestra el dashboard embebido.
5. **Preguntar a mis datos** abre Amazon Quick chat embebido.

## Paso a paso del despliegue

```bash
# 0. Sesión AWS (expira; repetir cuando Terraform falle con InvalidGrantException)
aws sso login --profile dashboards-dev-infile
aws sts get-caller-identity --profile dashboards-dev-infile

# 1. Empaquetar la Lambda (incluye su dependencia del SDK)
NPM_BIN=/opt/homebrew/bin/npm ./scripts/build_lambda_bundle.sh

# 2. Infraestructura. Usar el binario arm64 (/opt/homebrew/bin/terraform): el caché
#    de providers de .terraform es darwin_arm64. terraform.tfvars (no versionado)
#    lleva app_admin_email y alerts_email; ver terraform.tfvars.example.
TF=/opt/homebrew/bin/terraform
$TF -chdir=infrastructure/terraform init
$TF -chdir=infrastructure/terraform plan -out=app.tfplan
$TF -chdir=infrastructure/terraform apply app.tfplan
rm infrastructure/terraform/app.tfplan   # el plan guarda valores del state en claro

# 3. Frontend (config.json lo gestiona Terraform: excluirlo del sync)
npm run build --workspace @ventas-inteligentes/web
aws s3 sync apps/web/dist s3://dashboards-dinamicos-web-503561412084 \
  --exclude config.json --delete --profile dashboards-dev-infile

# 4. Invalidar caché de CloudFront tras cambios de frontend
aws cloudfront create-invalidation --distribution-id <ID> --paths '/*' \
  --profile dashboards-dev-infile
```

Los pasos 3 y 4 son para el piloto. En una cuenta de cliente lo hace un solo comando, que lee el
bucket y la distribución de los outputs del tenant:

```bash
AWS_PROFILE=<perfil-cliente> ./scripts/deploy_app.sh <tenant_id>
```

## Refrescar datos

Subir el archivo es lo único manual. Glue, las vistas y SPICE corren solos, en ese orden:

```bash
aws s3 cp facturas.jsonl \
  s3://dashboards-dinamicos-dev-503561412084/raw/dte/country=gt/ingest_date=$(date +%F)/ \
  --profile dashboards-dev-infile
```

Para forzar un refresco completo de ambos datasets sin esperar una carga:

```bash
aws lambda invoke --function-name dashboards-dinamicos-refresh-spice-dev --payload '{}' \
  --cli-binary-format raw-in-base64-out /dev/stdout --profile dashboards-dev-infile --region us-east-1
```

Sin `jobRunId` en el evento, la Lambda siempre pide refresco completo. Qué decidió en cada carga
queda en su log, en el campo `decision`.

## Desarrollo local

`npm run dev:web` sirve en `http://localhost:5173`, que está en las callback URLs de Cognito y en `ALLOWED_DOMAINS` de la Lambda. El `config.json` local está en `apps/web/public/`.

Usa `localhost`, no `127.0.0.1`: QuickSight solo acepta `http://` para el host literal `localhost` y rechaza el resto con `Input contains invalid domains`.

## Controles verificados en el despliegue

| Control | Resultado |
|---|---|
| `GET /embed` sin token | HTTP 401 |
| `GET /embed` con token inválido | HTTP 401 |
| App vía CloudFront | HTTP 200 |
| Bucket del frontend directo | HTTP 403 |
| Buckets públicos | Bloqueados, cifrado SSE-S3, versionado |
| Tráfico no TLS al bucket web | Denegado por política |
| Registro público en Cognito | Deshabilitado (solo invitación) |
| Log groups en Terraform | Ninguno gestionado (SCP de CloudWatch respetada) |

## Modificar visuales del dashboard

El generador visual por lenguaje natural de la consola falla en esta cuenta. El dashboard se construye por API:

```bash
python3 scripts/quicksight/build_dashboard_definition.py
aws quicksight update-analysis \
  --cli-input-json file://infrastructure/quicksight/generated/update-analysis.json \
  --profile dashboards-dev-infile --region us-east-1
```

Eso actualiza el análisis. Para que la app (que embebe el dashboard `pulso-facturacion-dev`) lo
vea, se publica la misma definición en el dashboard, sin `QueryExecutionOptions` (solo válido en
análisis): `update-dashboard` con esa `Definition` y luego `update-dashboard-published-version`
con la versión nueva. Los montos llevan formato con prefijo `Q` y dos decimales; las unidades,
enteros; nunca `$`.

Notas aprendidas de la API: `ColumnName` usa el nombre físico del dataset, el identificador lógico va en `DataSetIdentifier`, y todo campo de fecha exige `HierarchyId` con una `DateTimeHierarchy` declarada.

## Deuda conocida antes de masificar

1. **Los embeds usan el usuario QuickSight administrador.** Es aceptable para validar UX con usuarios internos; no abrir a más usuarios sin aprovisionar un usuario QuickSight por persona.
2. Row-Level Security por región, cartera o cliente.
3. Estado de Terraform en S3 cifrado con bloqueo (hoy es local).
4. WAF, dominio propio con ACM y límites de gasto.
5. CI/CD con OIDC en lugar de sesiones SSO manuales.
6. Refresh SPICE programado y alertas de fallo de Glue.

## Usuario de la aplicación

El usuario `rnhernandez@infile.com` está en estado `CONFIRMED`. Su contraseña se generó con
`scripts/provision_app_user.sh` y quedó guardada localmente, solo legible por tu usuario del sistema:

```text
~/.ventas-inteligentes-dev-password
```

Cámbiala desde la app tras el primer ingreso y borra ese archivo.

### Verificación realizada con un token real

```text
login Cognito            -> token emitido
GET /embed?dashboard     -> HTTP 200 + embedUrl
GET /embed?chat          -> HTTP 200 + embedUrl
GET /embed sin token     -> HTTP 401
```

`ALLOW_ADMIN_USER_PASSWORD_AUTH` se habilitó solo para esa prueba y ya fue retirado: los flujos
activos son `ALLOW_USER_SRP_AUTH` y `ALLOW_REFRESH_TOKEN_AUTH`. Para repetir la prueba hay que
habilitarlo temporalmente en `application.tf`.

### Agregar más usuarios

```bash
aws cognito-idp admin-create-user --user-pool-id us-east-1_Di1X9vNSS \
  --username persona@empresa.com \
  --user-attributes Name=email,Value=persona@empresa.com Name=email_verified,Value=true \
  --desired-delivery-mediums EMAIL --profile dashboards-dev-infile --region us-east-1
```

Recuerda la limitación pendiente: todos los usuarios comparten el mismo usuario QuickSight, así que
verían los mismos datos con permisos de autor. No agregar usuarios de negocio antes de aprovisionar
un usuario QuickSight por persona y aplicar RLS.

## Productor de datos

`scripts/produce_invoices.py` genera facturas sintéticas y las sube por lotes. Escribe muchos
archivos pequeños en vez de un objeto gigante: Spark paraleliza mejor la lectura y un lote que
falle no arrastra a los demás.

```bash
# 10,000 facturas en lotes de 500, procesando al final
python3 scripts/produce_invoices.py --count 10000 --batch-size 500 --pause 1.5 --process

# Generar sin tocar AWS
python3 scripts/produce_invoices.py --count 1000 --dry-run

# Datos reproducibles
python3 scripts/produce_invoices.py --count 5000 --seed 2026 --process
```

| Opción | Para qué |
|---|---|
| `--count` | Total de facturas |
| `--batch-size` | Facturas por archivo (500 por defecto) |
| `--span-days` | Ventana de fechas hacia atrás, reparte las particiones |
| `--pause` | Segundos entre lotes, para no saturar |
| `--seed` | Datos reproducibles |
| `--process` | Espera y ejecuta Glue al final |
| `--dry-run` | Solo genera, no sube |

### Por qué `--process` importa

El primer archivo dispara Glue por EventBridge, y el job corre de uno en uno. Los archivos que
llegan mientras corre **no** disparan otra ejecución. Con `--process` el script espera a que la
ejecución en curso termine y lanza una final que barre lo que quedó pendiente.

Sin `--process` hay que lanzar el job manualmente al final, o algunos lotes se quedarían sin
procesar hasta la siguiente carga.

### Carga verificada

```text
10,000 facturas · 20 lotes de 500 · 21.2 MiB de JSON crudo
        ↓
23,410 líneas de venta · 10,720 facturas · 979.6 KiB de Parquet
        ↓
SPICE: 22,866 filas (solo documentos emitidos)
```

El JSON crudo pesa 21.2 MiB y el Parquet resultante 979.6 KiB: **22 veces menos**. Esa medición es
de la tabla Parquet anterior a Iceberg; los datos se migraron idénticos, fila por fila.

### Idempotencia

El job lleva el control por **archivo** en `ctl_archivos_procesados`, no por día, porque una carga
masiva escribe muchos archivos con el mismo `ingest_date`. Hace `MERGE` por `(doc_id, linea)`
conservando la ingesta más reciente, así que reenviar un DTE no infla la facturación. Si un run se
cae a medias, el siguiente reprocesa los mismos archivos y llega al mismo resultado.

Para recargar todos los archivos crudos, ignorando la tabla de control:

```bash
aws glue start-job-run --job-name dashboards-dinamicos-flatten-invoices-dev \
  --arguments '{"--REPROCESS_ALL":"true"}' --profile dashboards-dev-infile --region us-east-1
```
