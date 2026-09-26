# Despliegue por cuenta de cliente

Modelo: **una cuenta AWS por cliente**, dentro de tu organización. Tú despliegas y verificas; el
cliente paga su propio consumo. Tu sistema deposita los JSON en el bucket del cliente y de ahí todo
ocurre solo.

```text
Tu sistema (fuera de este proyecto)
        │  deposita JSON
        ▼
s3://vi-<cliente>-data-<cuenta>/raw/dte/country=gt/ingest_date=YYYY-MM-DD/*.jsonl
        │  EventBridge
        ▼
Glue: lee solo archivos nuevos, aplana items[], MERGE en Iceberg, recalcula los días tocados
        │  EventBridge (job SUCCEEDED)
        ▼
deploy-views: despliega sql/model (tablas faltantes, vistas)
        │  al terminar
        ▼
refresh-spice: incremental si la carga fue reciente, completo si tocó días viejos
        ▼
El cliente ya puede chatear con su data
```

Todo lo que está debajo de "deposita JSON" se despliega con IaC y funciona sin intervención.

## ¿Se puede automatizar todo? Sí

| Componente | Cómo |
|---|---|
| Cuenta AWS | `aws_organizations_account` o Control Tower Account Factory |
| S3, Glue, Athena, EventBridge, Lambda, SNS | Terraform nativo |
| **Suscripción de QuickSight** | `aws_quicksight_account_subscription` |
| Data source, datasets SPICE, refrescos programados | Terraform nativo |
| **Tablas Iceberg y vistas de negocio** | `sql/model/`, desplegado por la Lambda `deploy-views` en el apply |
| **App del cliente**: Cognito, API Gateway, Lambda de embedding, CloudFront | `modules/tenant/app.tf` |
| Contenido del frontend | `scripts/deploy_app.sh` |
| Topic (capa semántica) | `scripts/quicksight/sync_topic.py` |
| Dashboard | `scripts/quicksight/build_dashboard_definition.py` (todavía fijo al piloto) |

Habilitar QuickSight y crear las vistas eran los dos pasos manuales del piloto. Ambos quedaron
automatizados. **No queda ningún paso de consola.**

Durante el `apply`, `aws_lambda_invocation` crea las tablas Iceberg vacías y las vistas sobre ellas,
antes que los datasets de SPICE, que dependen de esa invocación. Si una sentencia de `sql/model` falla,
el `apply` falla: un modelo roto no llega a un cliente en silencio. Cada carga vuelve a desplegar las
vistas antes de refrescar SPICE, así que un cambio en `sql/model` llega con el siguiente `apply`.

## Estructura

```text
infrastructure/terraform/
├── modules/tenant/          módulo reutilizable, un cliente completo
├── tenants/_template/       raíz a copiar por cliente
└── tenants/<cliente>/       terraform.tfvars + estado propio
```

Estado independiente por cliente:

```text
s3://dashboards-dinamicos-tfstate-503561412084/tenants/<cliente>/terraform.tfstate
```

Un error en un cliente no puede tocar a otro. Con miles de clientes esto no es opcional.

## Acceso sin credenciales guardadas

```hcl
assume_role {
  role_arn = "arn:aws:iam::${var.account_id}:role/VentasInteligentesDeployer"
}
```

El rol nace con la cuenta al aprovisionarla. No se almacenan llaves, y `allowed_account_ids` impide
desplegar en la cuenta equivocada.

## El flujo que pediste, paso a paso

### 1. El cliente acepta

Le pides una cuenta AWS dentro de tu organización, o la creas tú:

```hcl
resource "aws_organizations_account" "cliente" {
  name      = "Comercial La Estrella"
  email     = "aws+laestrella@tudominio.com"
  parent_id = aws_organizations_organizational_unit.clientes.id
  role_name = "VentasInteligentesDeployer"

  lifecycle { prevent_destroy = true }
}
```

Cada cuenta necesita un correo único; conviene usar alias `aws+<cliente>@tudominio.com`.

### 2. Despliegas

```bash
./scripts/provision_tenant.sh comercial-la-estrella          # crea la carpeta
# completar tenants/comercial-la-estrella/terraform.tfvars
./scripts/provision_tenant.sh comercial-la-estrella apply
```

### 3. Corres las comprobaciones

```bash
AWS_PROFILE=cliente-laestrella \
  ./scripts/verify_tenant.sh comercial-la-estrella 111122223333 --with-data
```

Verifica la configuración completa, incluidas las tablas Iceberg, las vistas, el refresco incremental
y la capa de aplicación, y con `--with-data` hace un
viaje completo: sube 200 facturas de prueba, espera la transformación, consulta la vista certificada
y confirma que SPICE se refrescó.

Dos comprobaciones de la app valen la pena por sí solas: que la API devuelva 401 sin token y que la
Lambda de embedding **no** tenga `FALLBACK_QUICKSIGHT_USER_ARN`. Esa variable existía en el piloto y
le daba identidad de administrador a cualquiera que iniciara sesión sin usuario propio.

Lo primero que valida es que la sesión apunte a la cuenta correcta, y aborta si no. Verificar un
cliente con credenciales de otro sería peor que no verificar.

### 4. Capa semántica y dashboard

```bash
AWS_PROFILE=cliente-laestrella python3 scripts/quicksight/sync_topic.py
AWS_PROFILE=cliente-laestrella python3 scripts/quicksight/build_dashboard_definition.py
```

El dashboard tiene que quedar con el id que espera la app, que el apply imprime:

```bash
terraform -chdir=infrastructure/terraform/tenants/comercial-la-estrella output -raw dashboard_id
# vi-comercial-la-estrella-prod-pulso-facturacion
```

### 5. Publicas el frontend

Terraform crea el bucket, CloudFront y `config.json`, pero no el contenido del SPA:

```bash
AWS_PROFILE=cliente-laestrella ./scripts/deploy_app.sh comercial-la-estrella
```

El script compila, sincroniza excluyendo `config.json` (lo gestiona Terraform) e invalida la caché.
Antes de subir compara la cuenta de la sesión con el sufijo del bucket: publicar el frontend de un
cliente en la cuenta de otro sería el peor error posible aquí.

Para dominio propio, `app_domain_aliases` más `app_certificate_arn` (certificado ACM en us-east-1) y
un CNAME al output `cloudfront_domain`. La marca del login va en `app_branding`.

### 6. Le dices que está listo

El `apply` imprime el destino exacto:

```text
s3://vi-comercial-la-estrella-data-111122223333/raw/dte/country=gt/ingest_date=<YYYY-MM-DD>/
```

Desde el momento en que tu sistema deposita ahí, el cliente puede consultar y chatear.

## Requisitos del archivo que depositas

- JSON Lines: un documento DTE por línea.
- Campos obligatorios: `doc_id`, `fecha_emision`, `estado`, `country`, `anio`, `mes`,
  `nit_receptor`, `nombre_receptor`, `establecimiento_codigo`, `establecimiento_nombre`,
  `departamento`, `municipio`, `gran_total` y el arreglo `items[]`.
- Cada ítem con `linea`, `codigo_producto`, `descripcion`, `cantidad`, `precio_unitario`, `monto` e
  `impuestos[0]` con `monto_gravable` y `monto_impuesto`.
- La ruta debe incluir `ingest_date=YYYY-MM-DD`: cuando llega el mismo DTE dos veces, gana la
  ingesta más reciente. El control de qué archivos ya se cargaron es por archivo.
- **Un archivo por lote, no uno gigante.** Lotes de 500 a 2,000 documentos paralelizan mejor y un
  lote defectuoso no arrastra a los demás.

Reenviar el mismo documento es seguro: el pipeline deduplica por `(doc_id, linea)` y conserva la
ingesta más reciente. Sin eso, un reenvío de DTE inflaría la facturación sin que nadie lo note.

## Lo que este modelo resuelve

| Modelo compartido | Cuenta por cliente |
|---|---|
| Miles de usuarios QuickSight en tu factura | Cada cliente paga su suscripción |
| Límite de 1,000 M de filas en SPICE | Un SPICE por cliente |
| RLS por etiquetas en cada consulta | Aislamiento por cuenta |
| Un error afecta a todos | Radio de impacto de un cliente |
| Un Topic admite 12 datasets | Un Topic por cliente |

El aislamiento por cuenta es más fuerte que cualquier RLS: no existe una configuración que, mal
puesta, deje a un cliente ver datos de otro.

## Lo que falta antes de vender el primero

1. **El dashboard y el Topic se publican con scripts fijos al piloto.** `sync_topic.py` y
   `build_dashboard_definition.py` tienen la cuenta, el perfil y el id del análisis escritos a mano.
   El módulo ya expone el `dashboard_id` que la app espera; falta parametrizar los scripts para que
   escriban ahí.
2. **El módulo nunca se ha aplicado.** Valida correctamente, pero validar no es desplegar. Hay que
   probarlo en una cuenta real antes de ofrecerlo; ajustar el módulo con 200 clientes desplegados es
   mucho más caro.
3. **Dimensionar por cliente.** `glue_workers = 2` sirve para decenas de miles de facturas, no para
   millones. Conviene definir planes por volumen.
4. **La categoría de producto es derivada.** El job la infiere del código con un `CASE`. Si el JSON
   del cliente trae categoría real, hay que usarla; si no, el cliente verá una clasificación que no
   es la suya.

## Costo por cliente

| Concepto | Orden de magnitud |
|---|---|
| S3, Glue, Athena, Lambda, EventBridge | unos pocos dólares al mes |
| SPICE | US$0.38/GB/mes |
| Autor de QuickSight | desde US$24/usuario/mes |
| Lector de QuickSight | desde US$3/usuario/mes |
| Amazon Quick (chat generativo) | cargo fijo por cuenta más suscripción |

El cargo fijo de Amazon Quick por cuenta es el número que decide si el chat va en todos los planes o
solo en uno premium. Multiplicado por miles de cuentas es la cifra más relevante de tu modelo de
negocio: confírmala con AWS antes de fijar precios.
