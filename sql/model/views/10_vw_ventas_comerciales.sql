-- Capa certificada: solo documentos emitidos, con los nombres de negocio.
--
-- Toda métrica monetaria debe filtrarse o agruparse por codigo_moneda. No es
-- válido sumar GTQ y USD sin una tasa de cambio explícita.
--
-- Métricas correctas sobre esta vista:
--   Facturación total: SUM(facturacion_total_linea), por moneda
--   Ventas sin IVA:    SUM(ventas_sin_iva_linea), por moneda
--   IVA:               SUM(iva_linea), por moneda
--   Facturas emitidas: COUNT(DISTINCT factura_id)
--   Ticket promedio:   SUM(facturacion_total_linea) / COUNT(DISTINCT factura_id), por moneda
--
-- (factura_id, linea) identifica una línea: es la llave para unir otras fuentes
-- por línea (por ejemplo costos) sin duplicar filas.
CREATE OR REPLACE VIEW ${db}.vw_ventas_comerciales AS
SELECT
  fecha,
  anio,
  mes,
  upper(trim(codigo_moneda)) AS codigo_moneda,
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
  linea,
  cantidad AS unidades_vendidas,
  facturacion_total_linea,
  ventas_sin_iva_linea,
  iva_linea
FROM ${db}.fct_lineas_factura
WHERE estado = 'emitido'
  AND upper(trim(codigo_moneda)) IN ('GTQ', 'USD')
