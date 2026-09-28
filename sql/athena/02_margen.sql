-- Margen bruto: requiere una fuente de costos que hoy NO existe.
--
-- El JSON de factura electrónica trae precio de venta e IVA, pero no el costo
-- del producto. Sin costo no hay margen, y estimarlo produciría un dashboard
-- que miente con precisión. Esto es la estructura lista para cuando el ERP
-- entregue costos reales. No se despliega sola: cuando existan costos, se mueve
-- a sql/model (tabla en tables/, vista en views/) y la despliega deploy-views.
--
-- Marcadores: ${db} es la base de Glue y ${bucket} el bucket de datos
-- (s3://<bucket>), los mismos que resuelve deploy-views para sql/model.
--
-- Paso 1: subir costos a ${bucket}/reference/costos_producto/
--         CSV con encabezado: codigo_producto,costo_unitario,vigente_desde
--         vigente_desde en formato AAAA-MM-DD.
--
-- Paso 2: crear la dimensión de costos.
CREATE EXTERNAL TABLE IF NOT EXISTS ${db}.costos_producto (
  codigo_producto string,
  costo_unitario  string,
  vigente_desde   string
)
ROW FORMAT SERDE 'org.apache.hadoop.hive.serde2.OpenCSVSerde'
WITH SERDEPROPERTIES ('separatorChar' = ',', 'quoteChar' = '"')
STORED AS TEXTFILE
LOCATION '${bucket}/reference/costos_producto/'
TBLPROPERTIES ('skip.header.line.count' = '1');

-- Paso 3: vista con margen, una fila por línea de factura (nunca más).
--
-- El costo es el vigente más reciente a la fecha de la venta. OpenCSVSerde lee
-- todo como texto, así que costo y fecha se convierten con TRY_CAST: una fila
-- mal escrita queda sin costo en lugar de romper la vista. Las líneas sin costo
-- quedan con margen NULL, nunca en cero: un cero se confunde con "sin ganancia",
-- un NULL se lee como "sin dato".
CREATE OR REPLACE VIEW ${db}.vw_ventas_margen AS
WITH costos AS (
  SELECT
    codigo_producto,
    TRY_CAST(costo_unitario AS decimal(12, 2)) AS costo_unitario,
    TRY_CAST(vigente_desde AS date)            AS vigente_desde
  FROM ${db}.costos_producto
),
costo_por_linea AS (
  -- La llave (factura_id, linea) garantiza una fila por línea aunque la factura
  -- repita el mismo producto en varias líneas.
  SELECT
    v.factura_id,
    v.linea,
    max_by(c.costo_unitario, c.vigente_desde) AS costo_unitario
  FROM ${db}.vw_ventas_comerciales v
  LEFT JOIN costos c
    ON c.codigo_producto = v.codigo_producto
   AND c.vigente_desde <= v.fecha
   AND c.costo_unitario IS NOT NULL
  GROUP BY v.factura_id, v.linea
)
SELECT
  v.*,
  cl.costo_unitario,
  cl.costo_unitario * v.unidades_vendidas AS costo_total_linea,
  v.ventas_sin_iva_linea - (cl.costo_unitario * v.unidades_vendidas) AS margen_bruto_linea,
  CASE
    WHEN v.ventas_sin_iva_linea = 0 OR cl.costo_unitario IS NULL THEN NULL
    ELSE (v.ventas_sin_iva_linea - (cl.costo_unitario * v.unidades_vendidas))
         / v.ventas_sin_iva_linea * 100
  END AS margen_pct
FROM ${db}.vw_ventas_comerciales v
LEFT JOIN costo_por_linea cl
  ON cl.factura_id = v.factura_id
 AND cl.linea = v.linea;

-- Paso 4: apuntar el dataset de QuickSight a vw_ventas_margen, agregar
-- "margen bruto" y "margen porcentual" al Topic con sus sinónimos
-- (ganancia, rentabilidad, utilidad) y refrescar SPICE. margen_pct no es
-- aditivo: en el Topic va como promedio ponderado o se recalcula como
-- SUM(margen_bruto_linea) / SUM(ventas_sin_iva_linea).
--
-- Cobertura antes de publicar: si menos del 95% de las líneas tienen costo,
-- el margen total será engañoso. Verificar con:
--   SELECT count_if(costo_unitario IS NULL) * 100.0 / count(*)
--   FROM ${db}.vw_ventas_margen;
