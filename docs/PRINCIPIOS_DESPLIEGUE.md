# Principios de despliegue por cliente

Decisiones fijas del proyecto. Cualquier cambio al módulo `tenant`, a los scripts o a la
documentación debe respetarlas. Si algo aquí deja de ser cierto, se cambia este documento primero.

## 1. El punto de partida son los JSON en el bucket del cliente

El proyecto **no** resuelve cómo llegan las facturas al cliente. Cuando empieza un despliegue ya
existe, en la cuenta del cliente:

- un bucket S3 (nombre conocido, creado por el cliente o por INFILE fuera de este repo);
- dentro, archivos **JSON Lines** de documentos DTE bajo un prefijo `raw/…` con
  `ingest_date=YYYY-MM-DD` en la ruta (formato en `docs/MULTI_TENANT.md`, "Requisitos del archivo").

Desde ahí, este repo construye **todo lo demás**:

```text
raw/ (JSONL, ya existe)
  → Glue flatten_invoices.py       promoción y aplanado, cuarentena de inválidos
  → Iceberg (fct_lineas_factura…)  modelo analítico, MERGE idempotente
  → vistas Athena (sql/model)      capa de negocio
  → SPICE (datasets)               copia para QuickSight, refresco incremental
  → dashboard + Topic + agente     visualización y chat
  → Cognito + API + CloudFront     la app que ve el cliente
```

Por eso el módulo debe **recibir** el bucket y el prefijo como variables, no crearlos. Si el bucket
no cumple algo que el pipeline necesita (EventBridge habilitado, cifrado, política TLS-only), el
módulo lo configura sobre el bucket existente; no lo reemplaza.

## 2. Cada cliente es una cuenta de AWS completa e independiente

Todo lo del cliente vive en **su** cuenta: datos, Glue, Athena, QuickSight (suscripción, datasets,
dashboard, Topic, agente), Cognito, API, CloudFront, alarmas, logs **y el estado de Terraform**.

Lo que está **prohibido**, porque acopla clientes a INFILE y multiplica el radio de impacto:

| Prohibido | Por qué |
|---|---|
| Estado de Terraform de un cliente en el bucket `dashboards-dinamicos-tfstate-503561412084` | Un incidente o un candado en la cuenta piloto bloquea a todos los clientes |
| `profile = "dashboards-dev-infile"` o cualquier perfil SSO de INFILE en un backend o provider de cliente | El despliegue de un cliente dependería de la sesión personal de alguien en INFILE |
| `assume_role` desde la cuenta piloto hacia la del cliente como mecanismo estándar | Convierte a la piloto en punto único de fallo y de acceso a todos los datos |
| Un "router central" que reparta archivos a los clientes desde una cuenta de INFILE | El punto de partida es que los archivos **ya están** en el bucket del cliente |
| Cualquier recurso compartido entre cuentas de clientes | Un cliente no debe poder afectar a otro |

Cómo se opera un cliente, entonces: con credenciales **de esa cuenta** (un rol de despliegue que el
cliente otorga, o un perfil propio del operador para esa cuenta), estado en un bucket de esa cuenta,
y nada que apunte fuera de ella. La cuenta piloto `503561412084` es únicamente la demo de INFILE.

## 3. Todo reproducible por código o por script parametrizado

- Terraform para infraestructura, incluido lo de QuickSight que el provider soporte (suscripción,
  data source, datasets, refrescos, usuarios, y **dashboard vía template**, pendiente).
- Scripts en `scripts/` para lo que Terraform no cubre (Topic, agente de Quick, publicación del
  frontend). Reciben cuenta, región, perfil e ids **por parámetro**; ningún default apunta al piloto.
- Nada se hace en consola. Si algo requiere consola hoy, es deuda registrada en
  `docs/DEUDA_TECNICA.md`, no un paso del procedimiento.

## 4. Orden de despliegue de un cliente nuevo

Entradas: `tenant_id`, nombre comercial, `account_id`, región, bucket y prefijo de raw, correo del
administrador de QuickSight, correo de alertas, lista de usuarios de la app, credenciales de la
cuenta del cliente.

1. Bucket de estado en la cuenta del cliente (bootstrap mínimo, una vez).
2. `terraform apply` del tenant: pipeline, modelo Iceberg y vistas (deploy-views en el apply),
   QuickSight (suscripción, data source, datasets, refrescos, usuarios), Cognito, API, CloudFront, WAF.
3. Primera carga: disparar el job de Glue sobre el `raw/` existente (o dejar que la regla de
   EventBridge lo haga con el siguiente archivo) y confirmar el refresco de SPICE.
4. Dashboard (template → dashboard con el id que espera la app), Topic y agente de Quick, todos en
   la cuenta del cliente y con parámetros del cliente.
5. `quick_chat_agent_id` en el tfvars y re-apply para que `config.json` lo publique.
6. `deploy_app.sh <tenant>` con credenciales del cliente.
7. `verify_tenant.sh <tenant> <account_id>` (debe cubrir también dashboard, Topic y agente).
8. Entregar `app_url`, confirmar suscripción SNS, dominio propio si aplica (ACM en us-east-1 + CNAME).

## 5. Estado actual frente a estos principios

El módulo `modules/tenant` ya es autocontenido en cuanto a recursos, pero **todavía no cumple los
puntos 1 y 2**: crea el bucket de datos en vez de recibirlo, el template lleva el estado a la cuenta
piloto con el perfil de INFILE y asume un rol desde ella, y los scripts de QuickSight tienen
defaults del piloto. El detalle y el orden para corregirlo están en `docs/DEUDA_TECNICA.md`
(puntos 9 a 11). Hasta que eso se cierre, la respuesta a "¿se puede desplegar un cliente completo
en otra cuenta con Terraform?" es **no**.
