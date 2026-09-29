-- Totales diarios de documentos emitidos separados por moneda.
--
-- Nunca se suman importes de monedas distintas. El job de Glue recalcula solo
-- las combinaciones (fecha, codigo_moneda) tocadas por cada carga.
CREATE TABLE ${db}.agg_ventas_diario_moneda (
  fecha             date,
  codigo_moneda     string,
  facturacion_total decimal(18,2),
  ventas_sin_iva    decimal(18,2),
  iva               decimal(18,2),
  facturas          bigint,
  unidades          bigint,
  actualizado_en    timestamp
)
PARTITIONED BY (day(fecha))
LOCATION '${warehouse}/agg_ventas_diario_moneda/'
TBLPROPERTIES ('table_type' = 'ICEBERG')
