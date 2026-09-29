-- Rellena agg_ventas_diario_moneda con las combinaciones (fecha, moneda) que
-- aún no tiene, recalculadas desde el detalle. Idempotente: en un modelo al día
-- no inserta nada.
--
-- Cubre dos casos con la misma sentencia:
--   1. Migración a multimoneda: el histórico existía solo en agg_ventas_diario y
--      el job de Glue solo recalcula los días que toca cada carga nueva. Sin
--      esto, las vistas por moneda quedarían vacías hasta reprocesar todo.
--   2. Cliente nuevo: el agregado se construye desde el primer despliegue con
--      lo que ya haya en la tabla de hechos.
-- Misma fórmula que el job de Glue (sección "Daily aggregate by currency").
INSERT INTO ${db}.agg_ventas_diario_moneda
SELECT
  f.fecha,
  upper(trim(f.codigo_moneda))                          AS codigo_moneda,
  CAST(sum(f.facturacion_total_linea) AS decimal(18,2)) AS facturacion_total,
  CAST(sum(f.ventas_sin_iva_linea) AS decimal(18,2))    AS ventas_sin_iva,
  CAST(sum(f.iva_linea) AS decimal(18,2))               AS iva,
  CAST(count(DISTINCT f.doc_id) AS bigint)              AS facturas,
  CAST(sum(f.cantidad) AS bigint)                       AS unidades,
  CAST(current_timestamp AS timestamp(6))               AS actualizado_en
FROM ${db}.fct_lineas_factura f
WHERE f.estado = 'emitido'
  AND upper(trim(f.codigo_moneda)) IN ('GTQ', 'USD')
  AND NOT EXISTS (
    SELECT 1
    FROM ${db}.agg_ventas_diario_moneda m
    WHERE m.fecha = f.fecha
      AND m.codigo_moneda = upper(trim(f.codigo_moneda))
  )
GROUP BY f.fecha, upper(trim(f.codigo_moneda))
