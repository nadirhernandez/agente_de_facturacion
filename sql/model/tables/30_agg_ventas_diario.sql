-- Totales diarios de documentos emitidos. El job de Glue recalcula solo los días
-- que tocó cada carga, así el comparativo no vuelve a sumar toda la historia.
--
-- Un día cuyos documentos quedaron todos anulados se guarda en cero, no se
-- borra: así el total de ese día baja en lugar de quedarse con el valor viejo.
CREATE TABLE ${db}.agg_ventas_diario (
  fecha             date,
  facturacion_total decimal(18,2),
  ventas_sin_iva    decimal(18,2),
  iva               decimal(18,2),
  facturas          bigint,
  unidades          bigint,
  actualizado_en    timestamp
)
LOCATION '${warehouse}/agg_ventas_diario/'
TBLPROPERTIES ('table_type' = 'ICEBERG')
