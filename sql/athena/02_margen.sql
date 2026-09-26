-- Margen bruto: requiere una fuente de costos que hoy NO existe.
--
-- El JSON de factura electrónica trae precio de venta e IVA, pero no el costo
-- del producto. Sin costo no hay margen, y estimarlo produciría un dashboard
-- que miente con precisión. Esto es la estructura lista para cuando el ERP
-- entregue costos reales.
--
-- Paso 1: subir costos a s3://<bucket>/reference/costos_producto/
--         CSV: codigo_producto,costo_unitario,vigente_desde
--
-- Paso 2: crear la dimensión de costos.

CREATE EXTERNAL TABLE IF NOT EXISTS sales_demo.costos_producto (
  codigo_producto string,
  costo_unitario  decimal(12,2),
  vigente_desde   string
)
ROW FORMAT SERDE 'org.apache.hadoop.hive.serde2.OpenCSVSerde'
WITH SERDEPROPERTIES ('separatorChar' = ',', 'quoteChar' = '"')
STORED AS TEXTFILE
LOCATION 's3://dashboards-dinamicos-dev-503561412084/reference/costos_producto/'
TBLPROPERTIES ('skip.header.line.count'='1');

-- Paso 3: vista con margen. Usa el costo vigente más reciente a la fecha de
-- la venta. Las líneas sin costo quedan con margen NULL, nunca en cero: un cero
-- se confunde con "sin ganancia", un NULL se lee como "sin dato".

CREATE OR REPLACE VIEW sales_demo.vw_ventas_margen AS
WITH costo_vigente AS (
  SELECT
    v.factura_id,
    v.fecha,
    v.codigo_producto,
    v.unidades_vendidas,
    v.ventas_sin_iva_linea,
    max_by(c.costo_unitario, c.vigente_desde) AS costo_unitario
  FROM sales_demo.vw_ventas_comerciales v
  LEFT JOIN sales_demo.costos_producto c
    ON c.codigo_producto = v.codigo_producto
   AND CAST(c.vigente_desde AS date) <= v.fecha
  GROUP BY 1, 2, 3, 4, 5
)
SELECT
  v.*,
  cv.costo_unitario,
  cv.costo_unitario * v.unidades_vendidas AS costo_total_linea,
  v.ventas_sin_iva_linea - (cv.costo_unitario * v.unidades_vendidas) AS margen_bruto_linea,
  CASE
    WHEN v.ventas_sin_iva_linea = 0 OR cv.costo_unitario IS NULL THEN NULL
    ELSE (v.ventas_sin_iva_linea - (cv.costo_unitario * v.unidades_vendidas))
         / v.ventas_sin_iva_linea * 100
  END AS margen_pct
FROM sales_demo.vw_ventas_comerciales v
LEFT JOIN costo_vigente cv
  ON cv.factura_id = v.factura_id
 AND cv.codigo_producto = v.codigo_producto
 AND cv.fecha = v.fecha;

-- Paso 4: apuntar el dataset de QuickSight a vw_ventas_margen, agregar
-- "margen bruto" y "margen porcentual" al Topic con sus sinónimos
-- (ganancia, rentabilidad, utilidad) y refrescar SPICE.
--
-- Cobertura antes de publicar: si menos del 95% de las líneas tienen costo,
-- el margen total será engañoso. Verificar con:
--   SELECT count(*) FILTER (WHERE costo_unitario IS NULL) * 100.0 / count(*)
--   FROM sales_demo.vw_ventas_margen;
