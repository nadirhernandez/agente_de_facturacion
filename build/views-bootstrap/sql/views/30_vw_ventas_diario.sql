-- Facturación diaria con los días sin venta en cero. Lee el agregado diario, no
-- el detalle: su costo no crece con el número de líneas.
CREATE OR REPLACE VIEW ${db}.vw_ventas_diario AS
SELECT
  c.fecha,
  c.anio,
  c.mes,
  c.semana_iso,
  c.inicio_semana,
  c.inicio_mes,
  c.dia_semana,
  c.es_fin_semana,
  COALESCE(a.facturacion_total, 0) AS facturacion_total,
  COALESCE(a.ventas_sin_iva, 0)    AS ventas_sin_iva,
  COALESCE(a.iva, 0)               AS iva,
  COALESCE(a.facturas, 0)          AS facturas,
  COALESCE(a.unidades, 0)          AS unidades
FROM ${db}.vw_calendario c
LEFT JOIN ${db}.agg_ventas_diario a
  ON a.fecha = c.fecha
