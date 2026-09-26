-- Capa certificada: solo documentos emitidos, con los nombres de negocio.
--
-- Métricas correctas sobre esta vista:
--   Facturación total: SUM(facturacion_total_linea)
--   Ventas sin IVA:    SUM(ventas_sin_iva_linea)
--   IVA:               SUM(iva_linea)
--   Facturas emitidas: COUNT(DISTINCT factura_id)
--   Ticket promedio:   SUM(facturacion_total_linea) / COUNT(DISTINCT factura_id)
CREATE OR REPLACE VIEW ${db}.vw_ventas_comerciales AS
SELECT
  fecha,
  anio,
  mes,
  departamento AS region,
  municipio,
  establecimiento,
  canal,
  cliente,
  nit_receptor,
  categoria,
  producto,
  codigo_producto,
  doc_id AS factura_id,
  cantidad AS unidades_vendidas,
  facturacion_total_linea,
  ventas_sin_iva_linea,
  iva_linea
FROM ${db}.fct_lineas_factura
WHERE estado = 'emitido'
