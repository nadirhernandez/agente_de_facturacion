# Modelo de despliegue: un cliente, una cuenta, desde su bucket

Estas reglas son decisiones del dueño del proyecto (INFILE). No se discuten de nuevo en cada
sesión; si una tarea las contradice, se detiene y se pregunta.

## Punto de partida

- **La IaC crea el bucket de datos** del cliente (en su cuenta) con toda su configuración; el
  cliente o su sistema **depositan después** los archivos JSON Lines de facturas en `raw/`. El
  proyecto no produce esos archivos ni gestiona cómo llegan; solo define el destino y lo procesa.
- Todo lo que construye este repo (Glue, Iceberg, Athena, QuickSight, Cognito, app) se levanta a
  partir de ese bucket y hacia adelante: promover, transformar, modelar, visualizar, conversar.
- Cada despliegue del modelo (`deploy-views`) corre migraciones idempotentes en `sql/model/migrations`
  para que un cambio de esquema nunca deje vistas vacías ni exija pasos manuales.

## Multimoneda

- Los importes viven en su moneda original (`codigo_moneda`: GTQ o USD). **Nunca se suman,
  promedian ni comparan monedas distintas**, ni en SQL, ni en QuickSight, ni en el chat, ni en
  alertas. No hay tasas de cambio en los datos.
- GTQ se muestra con prefijo `Q`, USD con `US$`; jamás un `$` a secas.

## Independencia total por cliente

- Cada cliente vive **completo en su propia cuenta de AWS**: datos, pipeline, QuickSight, Cognito,
  app, **y el estado de Terraform**.
- **Prohibido acoplar clientes a la cuenta piloto de INFILE (503561412084)**: ni estado remoto en
  su bucket, ni `assume_role` desde ella, ni perfiles SSO de INFILE en backends, ni un "router
  central" de datos. La cuenta piloto es solo la demo.
- Un cliente no debe poder ser afectado por otro. No hay recursos compartidos entre cuentas.

## Consecuencias para el código

- `infrastructure/terraform/tenants/_template/main.tf` debe tener backend S3 **en la cuenta del
  cliente** y provider con credenciales de esa cuenta (sin `assume_role` hacia/desde la piloto).
- El módulo `modules/tenant` crea el bucket de datos (ya lo hace). `data_writer_principals` es
  opcional y sirve para que el sistema del cliente escriba en `raw/`; no existe un router central.
- Los scripts de `scripts/` y `scripts/quicksight/` deben recibir cuenta/perfil/ids por parámetro;
  cualquier default `503561412084` o `dashboards-dev-infile` es deuda, no diseño.
- Dashboard, Topic y agente de Quick deben quedar reproducibles por cliente (código o script
  parametrizado); hoy solo existen en el piloto.

## Referencias

- `docs/PRINCIPIOS_DESPLIEGUE.md`: versión completa con el orden de despliegue de un cliente.
- `docs/DEUDA_TECNICA.md`: qué falta cambiar en el módulo y los scripts para cumplir esto.
- `docs/MULTI_TENANT.md`: diseño original; las partes sobre estado central y router están obsoletas.
