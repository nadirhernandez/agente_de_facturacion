# Estado del proyecto y pendientes

Documento de continuidad. Léelo primero al retomar en una sesión nueva.

## Qué es esto

Solución de analítica de facturación para Guatemala: los DTE en JSON se convierten en Parquet
particionado, se consultan con Athena, se cargan en SPICE y el usuario **chatea con sus datos** en
Amazon Quick, además de ver el dashboard **Pulso de Facturación**.

Dos entregas distintas conviven en el repositorio:

| Entrega | Dónde | Estado |
|---|---|---|
| **Piloto** en la cuenta `dev-infile` | `infrastructure/terraform/*.tf` | Desplegado y funcionando |
| **Producto** por cuenta de cliente | `infrastructure/terraform/modules/tenant/` | Completo con app incluida, validado, nunca aplicado |

## Cuenta y acceso

```text
Cuenta:   dev-infile — 503561412084
Región:   us-east-1
Perfil:   dashboards-dev-infile   (SSO, expira; renovar con aws sso login)
Terraform: 1.16.4 ARM nativo en /opt/homebrew/bin/terraform
           (el de /usr/local es Intel y falla en este Mac)
Estado:   s3://dashboards-dinamicos-tfstate-503561412084/dev/ventas-inteligentes.tfstate
```

Restricción de la organización: **una SCP prohíbe eliminar recursos de CloudWatch.** Terraform no
administra ningún log group en ninguna parte del proyecto, solo concede permisos de escritura. No lo
cambies.

## Piloto desplegado

```text
App:        https://d3ocvrp9ma213b.cloudfront.net
API:        https://przb6i4xl5.execute-api.us-east-1.amazonaws.com
Cognito:    https://ventas-inteligentes-dev-503561412084.auth.us-east-1.amazoncognito.com
Client ID:  33onu8vmtitrcaegfq88gpssie
Usuario:    rnhernandez@infile.com
Contraseña: ~/.ventas-inteligentes-dev-password  (cambiarla y borrar el archivo)
```

Recursos: bucket `dashboards-dinamicos-dev-503561412084`, base Glue `sales_demo`, workgroup
`dashboards-dinamicos-dev`, job `dashboards-dinamicos-flatten-invoices-dev`, dashboard
`pulso-facturacion-dev`, datasets `ventas-comerciales-dev` y `ventas-comparativo-dev`.

Datos actuales: 10,720 facturas, 23,410 líneas, 22,866 filas en SPICE.

## La capa de aplicación ya está en el módulo

**Era el pendiente principal y quedó hecho.** `modules/tenant/app.tf` despliega la app del cliente
completa, parametrizada por `tenant_id` y `account_id`. Un cliente nuevo entra por su propia app, no
por la consola de QuickSight.

| Recurso | Cómo quedó |
|---|---|
| `aws_cognito_user_pool` | Invite only, MFA opcional, tier por `var.cognito_user_pool_tier` (PLUS por defecto) |
| `aws_cognito_user_pool_domain` | `managed_login_version = 2`, prefijo `vi-<tenant>-<cuenta>` |
| `aws_cognito_managed_login_branding` | Valores de AWS por defecto; `var.app_branding` pone logo y colores del cliente |
| `aws_cognito_user_pool_client` | PKCE, sin secreto, callbacks derivados de los orígenes reales |
| `aws_cognito_user` | Uno por correo de `var.app_users` |
| `aws_quicksight_user` | **Nuevo.** La misma gente como identidad de QuickSight, rol `READER_PRO` |
| `aws_apigatewayv2_api` + autorizador JWT | `GET /embed` y `GET /status`, ambas con JWT |
| `aws_lambda_function` embedding | Bundle en `build/embedding-api`, sin identidad de reserva |
| `aws_s3_bucket` + `aws_cloudfront_distribution` con OAC | Bucket privado; `app_domain_aliases` + `app_certificate_arn` para dominio propio |
| `aws_s3_object` `config.json` | Config de runtime que consume el SPA |

Dos diferencias deliberadas contra el piloto:

- **No existe `SHARED_QUICKSIGHT_USER_ARN`.** En el piloto, quien iniciaba sesión sin usuario
  propio de QuickSight heredaba la identidad del administrador. Aquí cada usuario de la app tiene su
  `aws_quicksight_user`, y un desconocido recibe 403. `verify_tenant.sh` comprueba que la variable no
  exista.
- **El origen `localhost` es opcional** (`enable_local_dev_origin`, `false` por defecto). En una
  cuenta de cliente no tiene por qué estar.

Detalles que ya costaron trabajo descubrir, ahora escritos en el código como comentarios:

- **QuickSight rechaza `http://127.0.0.1`.** Solo acepta `http://` para el host literal `localhost`.
  Por eso el dev local corre en `http://localhost:5173`.
- `AWS_ACCOUNT_ID` no sirve como variable de entorno de Lambda; se usa `QUICKSIGHT_ACCOUNT_ID`.
- El permiso de invocación de API Gateway debe ser `execution_arn/*/*`, no por ruta, o la segunda
  ruta falla.
- El chat requiere un rol Pro de QuickSight. `READER` alcanza solo para ver el dashboard.

Validación hecha: `terraform fmt`, `validate` y un `plan` completo con credenciales ficticias sobre
el módulo entero. Son 69 recursos, sin ciclos ni errores de tipo. **Sigue sin aplicarse en una cuenta
real.**

## PENDIENTE PRINCIPAL: publicar dashboard y Topic por cuenta de cliente

`scripts/quicksight/sync_topic.py` y `scripts/quicksight/build_dashboard_definition.py` tienen la
cuenta `503561412084`, el perfil `dashboards-dev-infile` y el `ANALYSIS_ID` del piloto escritos a
mano. El módulo ya expone el id que la app espera:

```bash
terraform -chdir=infrastructure/terraform/tenants/<cliente> output -raw dashboard_id
# vi-<cliente>-prod-pulso-facturacion
```

Falta parametrizar los dos scripts por cuenta, perfil y nombres de dataset para que el dashboard se
cree con ese id. Mientras no se haga, la app de un cliente nuevo carga y autentica, pero la vista de
dashboard queda vacía porque el id no existe en su cuenta.

## Modelo en Iceberg

Migrado en el piloto y portado al módulo. El flujo, sin intervención humana:

```text
raw/*.jsonl -> start-ingestion -> Glue (MERGE en Iceberg) -> deploy-views (sql/model) -> refresh-spice
```

| Pieza | Qué hace |
|---|---|
| `sql/model/tables/` | `fct_lineas_factura` (partición `day(fecha)`), `ctl_archivos_procesados`, `agg_ventas_diario` |
| `sql/model/views/` | Las cuatro vistas; calendario y diario leen el agregado, no el detalle |
| `deploy_views.mjs` | Crea las tablas que falten y reemplaza las vistas. Falla fuerte si algo no compila |
| `flatten_invoices.py` | Lee solo archivos nuevos, `MERGE` por `(doc_id, linea)` limitado a los días del lote, recalcula esos días del agregado |
| `refresh_spice.mjs` | Incremental si la fecha más vieja de la carga cae dentro de la ventana (7 días, margen de 2); si no, completo |

Horarios del dataset de líneas: incremental diario 02:00 y completo los domingos 03:00, hora de
Guatemala. El de períodos sigue con refresco completo cada hora.

Cómo se verificó en el piloto:

- Iceberg contra Parquet, fila por fila: 23,410 líneas y 10,720 documentos, cero diferencias en
  ambos sentidos, cero claves duplicadas, y el agregado cuadra con el detalle en los 541 días.
- Foto de números certificados antes y después, incluyendo las 639 filas del comparativo: idéntica.
- Reenvío real de 2 documentos recientes por la cadena automática: eligió incremental, SPICE leyó 219
  filas en 45 s y quedó en 22,866, igual que antes.

Pendientes de esta migración:

1. **Quitar la tabla vieja `ventas_lineas`.** Ya nada la lee ni la escribe; está marcada `LEGACY` en
   `analytics.tf` como vía de regreso. Para revertir: volver `vw_ventas_comerciales` a esa tabla y el
   job al script anterior. Solo tiene los datos hasta la migración.
2. **Mantenimiento de Iceberg.** Programar `OPTIMIZE` y `VACUUM` semanales sobre `fct_lineas_factura`.
   Con el volumen del piloto no urge; con millones de líneas al mes, sí.
3. **Prueba de carga con 3.5 M de registros al mes.** Medir `MERGE` y el refresco incremental antes de
   ofrecerlo a un cliente de ese tamaño.

Comportamiento a conocer: una línea se empareja solo dentro de los días del lote. Un DTE reenviado
conserva su fecha de emisión, así que funciona; si un reenvío cambiara la fecha, la línea vieja se
quedaría en su día original. Era igual con Parquet.

Cambiar el esquema de una tabla existente requiere un `ALTER TABLE` propio: el `CREATE TABLE` solo
corre cuando la tabla no existe.

## Agente de chat ligado a las ventas

Creado en dev por API: space `ventas-inteligentes` (Topic + dashboard) y agente
`ventas-inteligentes-analista`, `PUBLISHED` y `ACTIVE`, ligado solo a ese space. La app lo usa si
`config.json` trae `quickChatAgentId`; hoy solo el de desarrollo local lo tiene. CloudFront sigue
igual. Detalle, permisos y cómo revertir en `docs/CHAT_TUNING.md`, sección "Agente de chat propio".

Verificado en navegador: `fixedAgentId` fija el agente. La primera prueba cargaba en blanco con un
401, porque crear el agente por API no le da acceso al usuario de QuickSight; el script ahora le
concede permisos de dueño. Siguiente paso: agregar `quickChatAgentId` al `config.json` que publica
Terraform y al módulo tenant.

## Otros pendientes

1. **Aplicar el módulo en una cuenta real.** Valida, pero validar no es desplegar.
2. **Quitar `SHARED_QUICKSIGHT_USER_ARN` del piloto.** El módulo ya no lo tiene, pero
   `infrastructure/terraform/application.tf` sigue apuntando al administrador. Hay que quitarlo antes
   de dar acceso a usuarios reales en `dev-infile`.
3. **Row-Level Security.** No aplica en el modelo de cuenta por cliente (el aislamiento es la cuenta),
   pero sí si alguna vez se comparte una cuenta entre áreas.
4. **Margen bruto.** Estructura lista en `sql/athena/02_margen.sql`; faltan costos reales. El JSON de
   factura no los trae. Plantilla en `data/reference/costos_producto.csv.template`.
5. **Categoría de producto inventada.** El job Glue la deriva del código con un `CASE`. Con datos
   reales debe venir de una dimensión de producto o el dashboard mentirá con elegancia.
6. **Guardar conversación como dashboard.** Descartado por decisión: Amazon Quick no expone la
   estructura del visual que genera. No insistir.
7. **Confirmar la suscripción SNS de alertas** desde el correo (está en `PendingConfirmation`).
8. **Dimensionar Glue por cliente.** `glue_workers = 2` sirve para decenas de miles de facturas.
9. **Verificar con AWS el cargo fijo de Amazon Quick por cuenta.** Multiplicado por miles de cuentas,
   es el número que define el modelo de negocio.
10. **Confirmar que `READER_PRO` es aceptado por `RegisterUser`.** El provider no valida el valor, lo
    valida la API en el apply. Si lo rechaza, bajar `app_user_role` a `READER` y el chat queda fuera.

## Decisiones tomadas, no volver a discutir

- **SPICE, no Direct Query.** El chat es exploratorio; Direct Query cobra y espera en cada
  repregunta. La frescura se resuelve con un refresco tras cada carga (incremental o completo según
  los días que tocó), más un incremental diario y un completo semanal de respaldo.
- **Iceberg para los hechos.** `MERGE` en lugar de reescribir meses, partición por día y tabla de
  control. Detalle en "Modelo en Iceberg".
- **Una sola fuente del modelo:** `sql/model/`. Ni Terraform, ni Glue, ni scripts definen tablas o
  vistas.
- **Semana de lunes a domingo.** Comparativo contra el **período anterior inmediato**.
- **Días sin venta valen cero**, vía `vw_calendario`. Sin eso, un promedio diario divide entre los
  días que vendieron y una caída total se ve como dato ausente.
- **`es_periodo_completo`** excluye períodos en curso de los comparativos. Sin esto, cada lunes el
  chat reportaría una caída falsa.
- **Dos datasets con granularidad distinta:** líneas de factura y períodos. Mezclarlos duplica
  conteos.
- **La vista Q&A se eliminó.** No aportaba sobre el chat completo.
- **El dashboard se construye por API**, no con el generador visual de la consola, que falla en esta
  cuenta con `Error al traducir IR a una configuración visual`.

## Aprendizajes de la API de QuickSight

- `ColumnName` usa el nombre físico del dataset; el identificador lógico va en `DataSetIdentifier`.
- Todo campo de fecha en un visual exige `HierarchyId` con una `DateTimeHierarchy` declarada.
- `ComparativeOrder.UseOrdering` solo acepta `GREATER_IS_BETTER`, `LESSER_IS_BETTER` o `SPECIFIED`.
- Los Topics creados en la consola con la experiencia nueva **no aparecen en `ListTopics`** y no se
  pueden gestionar por API. Por eso existe `ventas-inteligentes`, creado por script.
- `UpdateTopic` ignora las instrucciones personalizadas; tienen su propia API, que además falló al
  actualizar. Al cambiar instrucciones, revisarlas en la consola.

## Aprendizajes del pipeline

- El control incremental es **por archivo**, no por día. Con `ingest_date` un lote de 20 archivos
  del mismo día se trataba como uno solo y se perdían 19. Hoy lo lleva `ctl_archivos_procesados`,
  con la URI completa del archivo.
- **`input_file_name()` no sirve dentro de un `MERGE`.** Spark lo rechaza por no determinista; se
  usa `_metadata.file_path`.
- **Un refresco incremental de SPICE solo es correcto si la carga cayó dentro de la ventana.** Por eso
  `refresh-spice` lee la fecha más vieja que escribió la carga y, si queda fuera, pide uno completo.
- **Dos targets en una misma regla de EventBridge corren en paralelo.** SPICE podía leer una vista a
  medio reemplazar; ahora `deploy-views` termina y después invoca a `refresh-spice`.
- **QuickSight no admite un horario por hora junto a otros horarios** en el mismo dataset.
- **Nunca usar `sys.exit()` en un job de Glue.** Glue lo reporta como `FAILED`, lo que rompe la
  cadena de EventBridge que refresca SPICE.
- El job deduplica por `(doc_id, linea)`. Sin eso, un reenvío de DTE duplicó los datos (3,042 filas
  donde debían haber 1,521).
- El job corre con `max_concurrent_runs = 1`. El primer archivo dispara Glue; los que llegan mientras
  corre no disparan otra ejecución. Por eso `produce_invoices.py --process` espera y lanza una final.

## Scripts

```bash
scripts/produce_invoices.py            # genera y sube facturas por lotes
scripts/verify_tenant.sh               # comprobaciones de configuración + viaje de datos completo
scripts/provision_tenant.sh            # despliega un cliente nuevo
scripts/deploy_app.sh                  # publica el frontend en la cuenta del cliente
scripts/run_athena_sql.sh              # consultas sueltas en Athena; el modelo NO se despliega con esto
scripts/build_lambda_bundle.sh         # empaqueta las tres Lambdas
scripts/quicksight/sync_topic.py       # capa semántica por API, idempotente
scripts/quicksight/sync_agent.py       # agente de chat ligado solo a las ventas (--delete revierte)
scripts/quicksight/build_dashboard_definition.py   # dashboard por API
scripts/provision_app_user.sh          # usuario inicial de la app
```

## Documentación

| Archivo | Contenido |
|---|---|
| `docs/MULTI_TENANT.md` | Despliegue por cuenta de cliente, el flujo comercial completo |
| `docs/CHAT_TUNING.md` | SPICE vs Direct Query, modelo temporal, instrucciones del Topic |
| `docs/RUNBOOK.md` | Operación diaria, productor de datos, desarrollo local |
| `docs/PRODUCTION.md` | Qué se resolvió y qué falta, con el detalle de cada tema |
| `docs/APP_SECURITY.md` | Modelo de seguridad de la app y del login |
| `docs/MLP_OPERATIONS.md` | Arquitectura y métricas certificadas |

## Métricas certificadas

| Concepto | Definición |
|---|---|
| Facturación total | `SUM(facturacion_total_linea)`, incluye IVA |
| Ventas sin IVA | `SUM(ventas_sin_iva_linea)` |
| IVA | `SUM(iva_linea)` |
| Facturas | `COUNT(DISTINCT factura_id)` |
| Unidades | `SUM(unidades_vendidas)` |
| Ticket promedio | Facturación / facturas |

Solo documentos con `estado = 'emitido'`. No hay costos, margen, inventario ni metas: no inventarlos.
