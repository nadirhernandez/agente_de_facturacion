# Modelo de despliegue: un cliente, una cuenta, desde su bucket

Estas reglas son decisiones del dueño del proyecto (INFILE). No se discuten de nuevo en cada
sesión; si una tarea las contradice, se detiene y se pregunta.

## Punto de partida

- El despliegue de un cliente **empieza con los archivos JSON Lines de facturas ya depositados en
  un bucket S3 de la cuenta del cliente**. Ese bucket y esos archivos son la entrada; el proyecto no
  los produce ni gestiona cómo llegan ahí.
- Todo lo que construye este repo (Glue, Iceberg, Athena, QuickSight, Cognito, app) se levanta a
  partir de ese bucket y hacia adelante: promover, transformar, modelar, visualizar, conversar.

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
- El módulo `modules/tenant` debe **aceptar un bucket de datos existente** (nombre y prefijo de
  raw) en lugar de crearlo, y no requerir `data_writer_principals` externos.
- Los scripts de `scripts/` y `scripts/quicksight/` deben recibir cuenta/perfil/ids por parámetro;
  cualquier default `503561412084` o `dashboards-dev-infile` es deuda, no diseño.
- Dashboard, Topic y agente de Quick deben quedar reproducibles por cliente (código o script
  parametrizado); hoy solo existen en el piloto.

## Referencias

- `docs/PRINCIPIOS_DESPLIEGUE.md`: versión completa con el orden de despliegue de un cliente.
- `docs/DEUDA_TECNICA.md`: qué falta cambiar en el módulo y los scripts para cumplir esto.
- `docs/MULTI_TENANT.md`: diseño original; las partes sobre estado central y router están obsoletas.
