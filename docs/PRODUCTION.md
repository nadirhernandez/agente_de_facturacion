# Camino a producción

Lo que ya quedó resuelto y verificado, y lo que falta con su razón.

## 1. Identidad por usuario — resuelto parcialmente

La Lambda ahora resuelve la identidad de QuickSight a partir del `email` del token de Cognito:

```text
JWT claim email → quicksight:ListUsers → ARN del usuario → embed con SU identidad
```

Si la persona ya existe en QuickSight, el embed usa su usuario, con sus permisos y su RLS. El
permiso IAM se otorga sobre `user/default/*`, no sobre un ARN fijo.

Queda un `SHARED_QUICKSIGHT_USER_ARN` apuntando al administrador para quien no tenga usuario
QuickSight. **Eso es lo que hay que quitar antes de abrir el producto**: mientras exista, alguien
sin usuario propio hereda permisos de administrador.

Para cerrarlo:

```bash
# Registrar cada persona como lector, con el mismo email de Cognito
aws quicksight register-user --aws-account-id 503561412084 --namespace default \
  --identity-type QUICKSIGHT --user-role READER \
  --email persona@empresa.com --user-name persona@empresa.com \
  --profile dashboards-dev-infile --region us-east-1
```

Luego borrar `SHARED_QUICKSIGHT_USER_ARN` de `application.tf`. La Lambda devolverá 403 con un
mensaje claro a quien no esté registrado, que es el comportamiento correcto.

## 2. Row-Level Security — pendiente

Sin RLS todos los usuarios ven todas las regiones. La estructura:

```text
s3://<bucket>/reference/rls_reglas/  →  UserName,region
                                         gerente.norte@empresa.com,Quetzaltenango
                                         director@empresa.com,            (vacío = todo)
```

Se crea un dataset con ese CSV y se asocia al dataset de ventas con
`row_level_permission_data_set`. QuickSight filtra antes de devolver datos, así que aplica igual en
el dashboard, en el chat y en cualquier consulta. Un campo vacío significa acceso total.

No lo activé porque hoy existe un solo usuario y una regla mal configurada deja a todos sin datos.
Es el paso inmediato después de registrar usuarios reales.

## 3. Estado de Terraform — resuelto

```text
bucket:   dashboards-dinamicos-tfstate-503561412084
key:      dev/ventas-inteligentes.tfstate
lock:     nativo de S3 (use_lockfile)
versionado, cifrado, sin acceso público, TLS obligatorio
versiones antiguas expiran a los 90 días
```

El bucket se crea con `infrastructure/terraform/bootstrap/`, que tiene `prevent_destroy` sobre el
bucket. Su propio estado queda local a propósito: es de seis recursos y se puede reconstruir.

## 4. Ingesta automática e incremental — resuelto

```text
archivo en raw/dte/  →  EventBridge  →  Lambda  →  Glue (incremental)
Glue SUCCEEDED       →  EventBridge  →  Lambda  →  refresco de SPICE
```

Verificado de punta a punta: subir un archivo disparó el job solo, y al terminar se lanzó la
ingesta `auto-...` sin intervención.

El job ya no reprocesa todo:

- Filtra las particiones `ingest_date` que nunca se procesaron.
- Sobrescribe solo las particiones `country/anio/mes` afectadas (`partitionOverwriteMode=dynamic`).
- **Deduplica por `(doc_id, linea)`** conservando el `ingest_date` más reciente.
- `max_concurrent_runs = 1`, para que dos cargas no se pisen.
- `--REPROCESS_ALL true` reconstruye todo cuando cambian las reglas de negocio.

La deduplicación no es teórica: al probar la cadena subí el mismo archivo dos veces y el dataset
llegó a 3,042 filas. Con el arreglo volvió a 1,521. En producción los DTE se reenvían, así que sin
esto la facturación se infla sola.

## 5. Margen bruto — estructura lista, faltan costos

El JSON de factura trae precio de venta e IVA, **no costo**. Sin costo no hay margen, y estimarlo
produce un dashboard que miente con precisión.

`sql/athena/02_margen.sql` deja la ruta completa: tabla de costos por producto con vigencia,
vista `vw_ventas_margen` que toma el costo vigente a la fecha de la venta, y margen en quetzales y
porcentaje. Plantilla en `data/reference/costos_producto.csv.template`.

Dos decisiones de diseño que importan:

- Las líneas sin costo quedan en `NULL`, no en cero. Un cero se lee como "no gané nada"; un `NULL`
  se lee como "no sé".
- El costo tiene `vigente_desde`, porque el costo de hoy no sirve para explicar el margen de hace
  ocho meses.

Antes de publicarlo, verificar cobertura: con menos del 95% de líneas con costo, el margen total
engaña.

## 6. Alertas proactivas — resuelto

Lambda semanal (lunes 13:00 UTC) que compara el último mes cerrado contra el anterior por región y
publica en SNS solo si alguna cae más de 10%.

Probado: detectó 2 regiones con caída y publicó la alerta.

Decisiones: compara el último mes **completo** para que una carga parcial del mes en curso no
dispare falsas alarmas, y no envía nada cuando no hay caídas, para que el correo no se vuelva ruido.

**Falta un paso tuyo:** confirmar la suscripción SNS desde el correo que AWS envió a
`rnhernandez@infile.com`. Hasta entonces la alerta se publica pero no se entrega.

Ajustar el umbral con la variable `DROP_THRESHOLD_PCT`.

## 7. Guardar una conversación como dashboard — pendiente

Es viable y ya está probada la mitad difícil: los 8 visuales del dashboard actual se crearon por API
con `scripts/quicksight/build_dashboard_definition.py`, no a mano.

Lo que falta es el puente: capturar qué exploró el usuario en el chat y traducirlo a una definición
de análisis. Amazon Quick no expone hoy la estructura de la visualización que generó, así que el
camino realista es un botón "guardar esta vista" sobre el dashboard filtrado en lugar de sobre la
respuesta del chat.

## 8. Otros pendientes

| Tema | Por qué importa |
|---|---|
| Categoría de producto inventada | El Glue job la deriva de un `CASE` por código. Con el ERP real debe venir de una dimensión de producto. |
| WAF y dominio propio | CloudFront está abierto a Internet con dominio de AWS. |
| CI/CD con OIDC | Hoy todo depende de tu sesión SSO local. |
| Presupuestos y alarmas de costo | Amazon Quick tiene cargo fijo por cuenta; conviene vigilarlo. |
| Tier de Cognito | Está en PLUS por threat protection. ESSENTIALS basta para Managed Login y cuesta menos por usuario. |
