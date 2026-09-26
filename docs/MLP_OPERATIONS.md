# Operación del MLP — Ventas Inteligentes

## Objetivo

Permitir que usuarios autorizados consulten facturación de Guatemala mediante Amazon Quick y exploren el dashboard **Pulso de Facturación**, sin acceso directo a Athena, S3 ni credenciales AWS.

## Arquitectura desplegada

```text
DTE JSONL → S3/raw → Glue 5 (MERGE) → Iceberg en S3/curated/iceberg → Glue Catalog → Athena
                                                                           ↓
                                                                   QuickSight SPICE
                                                                           ↓
                                                          Topic + Amazon Quick + Dashboard
```

Tablas y vistas: una sola fuente en `sql/model/`.

Recursos principales en `dev-infile` / `us-east-1`:

| Recurso | Nombre |
|---|---|
| Bucket de datos | `dashboards-dinamicos-dev-503561412084` |
| Glue database | `sales_demo` |
| Athena workgroup | `dashboards-dinamicos-dev` |
| Glue job | `dashboards-dinamicos-flatten-invoices-dev` |
| Dataset QuickSight | `Ventas comerciales` |
| Topic | `Ventas Inteligentes GT` |
| Dashboard | `Pulso de Facturación` |

## Flujo de carga de datos

1. Cargar JSONL de DTE en `raw/dte/country=gt/ingest_date=YYYY-MM-DD/`. Todo lo demás es automático.
2. EventBridge arranca el job `dashboards-dinamicos-flatten-invoices-dev`, que lee solo los archivos
   que no están en `ctl_archivos_procesados` y hace `MERGE` en `fct_lineas_factura`.
3. El job recalcula en `agg_ventas_diario` solo los días que tocó la carga.
4. Al terminar, `deploy-views` despliega `sql/model` y luego `refresh-spice` refresca SPICE:
   incremental si la carga cayó en los últimos días, completo si no.
5. Validar Athena y Amazon Quick con preguntas de aceptación.

No hace falta crawler ni `MSCK REPAIR TABLE`: Iceberg lleva su propio registro de archivos.

## Métricas certificadas

| Concepto | Definición |
|---|---|
| Facturación total | `SUM(facturacion_total_linea)`; incluye IVA |
| Ventas sin IVA | `SUM(ventas_sin_iva_linea)` |
| IVA | `SUM(iva_linea)` |
| Facturas emitidas | `COUNT(DISTINCT factura_id)` |
| Unidades vendidas | `SUM(unidades_vendidas)` |
| Ticket promedio | Facturación total / facturas emitidas |

Solo se usan documentos con `estado = emitido`. No se deben inferir costos, margen, inventario ni metas.

## Seguridad

- Terraform está bloqueado a la cuenta `503561412084` y a `us-east-1`.
- El bucket bloquea acceso público y usa cifrado SSE-S3 y versionado.
- QuickSight obtiene permisos mínimos sobre `curated/` y `athena-results/`.
- Los logs Glue usan el prefijo `/dashboards-dinamicos/dev/glue`; no son administrados ni eliminados por Terraform debido a la SCP organizacional.
- La futura API de embedding debe requerir token Cognito y generar URLs temporales de QuickSight. Nunca exponer credenciales AWS, URLs persistentes ni el ARN de un usuario administrador al navegador.

## Pruebas de aceptación

1. Preguntar: `¿Cuál fue la facturación total, las ventas sin IVA y el número de facturas emitidas en agosto de 2026?`
2. Confirmar resultados: Q 56,901.32; Q 50,804.81; 63 facturas.
3. Revisar que el dashboard muestre KPI, tendencia mensual, región, categoría y producto.
4. Confirmar que documentos anulados no aparezcan en resultados.

## Escalamiento a producto

1. Separar `dev`, `qa` y `prod` en cuentas AWS diferentes.
2. Reemplazar el usuario QuickSight de desarrollo por aprovisionamiento automático Cognito/SSO → QuickSight.
3. Mapear usuario, región o cartera a Row-Level Security en QuickSight.
4. Añadir refresh SPICE programado y monitoreo de fallas Glue/Athena.
5. Centralizar estado Terraform en S3 cifrado con bloqueo y CI/CD OIDC; no usar access keys estáticas.
6. Añadir dominios propios, WAF, auditoría, presupuestos y alertas antes de exposición externa.
