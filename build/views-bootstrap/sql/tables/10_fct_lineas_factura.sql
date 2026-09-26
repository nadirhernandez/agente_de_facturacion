-- Una fila por línea de factura. La escribe el job de Glue con MERGE por
-- (doc_id, linea): un DTE reenviado reemplaza sus líneas en lugar de duplicarlas.
--
-- Partición oculta por día de emisión: un filtro por fecha, como el del
-- refresco incremental de SPICE, lee solo los días que pide.
CREATE TABLE ${db}.fct_lineas_factura (
  doc_id                  string,
  fecha_emision           timestamp,
  fecha                   date,
  dia                     int,
  estado                  string,
  codigo_moneda           string,
  serie                   string,
  nit_receptor            string,
  cliente                 string,
  establecimiento_codigo  string,
  establecimiento         string,
  departamento            string,
  municipio               string,
  canal                   string,
  gran_total_documento    decimal(12,2),
  linea                   int,
  codigo_producto         string,
  producto                string,
  categoria               string,
  cantidad                int,
  precio_unitario         decimal(12,2),
  facturacion_total_linea decimal(12,2),
  ventas_sin_iva_linea    decimal(12,2),
  iva_linea               decimal(12,2),
  ingest_date             string,
  source_file             string,
  country                 string,
  anio                    int,
  mes                     int
)
PARTITIONED BY (day(fecha))
LOCATION '${warehouse}/fct_lineas_factura/'
TBLPROPERTIES ('table_type' = 'ICEBERG')
