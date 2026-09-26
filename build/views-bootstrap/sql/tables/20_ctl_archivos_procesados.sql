-- Un registro por archivo crudo ya cargado. Reemplaza el escaneo de toda la
-- tabla de hechos que hacía falta para saber qué archivos eran nuevos.
--
-- fecha_min y fecha_max dicen qué días tocó cada carga: con eso se decide si
-- basta un refresco incremental de SPICE o hace falta uno completo.
CREATE TABLE ${db}.ctl_archivos_procesados (
  source_file  string,
  ingest_date  string,
  job_run_id   string,
  documentos   bigint,
  lineas       bigint,
  fecha_min    date,
  fecha_max    date,
  procesado_en timestamp
)
LOCATION '${warehouse}/ctl_archivos_procesados/'
TBLPROPERTIES ('table_type' = 'ICEBERG')
