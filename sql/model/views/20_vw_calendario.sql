-- Calendario continuo del primer al último día con documentos emitidos.
--
-- Sin fechas continuas, un día sin ventas simplemente no existe: el promedio
-- diario divide entre los días que vendieron y una caída total se ve como dato
-- ausente. La semana va de lunes a domingo (date_trunc('week') inicia lunes).
CREATE OR REPLACE VIEW ${db}.vw_calendario AS
WITH rango AS (
  SELECT min(fecha) AS desde, max(fecha) AS hasta
  FROM ${db}.agg_ventas_diario
  WHERE facturas > 0
)
SELECT
  CAST(dia AS date)                               AS fecha,
  year(dia)                                       AS anio,
  month(dia)                                      AS mes,
  week(dia)                                       AS semana_iso,
  CAST(date_trunc('week', dia) AS date)           AS inicio_semana,
  CAST(date_trunc('month', dia) AS date)          AS inicio_mes,
  CAST(date_trunc('year', dia) AS date)           AS inicio_anio,
  day_of_week(dia)                                AS dia_semana_numero,
  format_datetime(CAST(dia AS timestamp), 'EEEE') AS dia_semana,
  day_of_week(dia) >= 6                           AS es_fin_semana
FROM rango
CROSS JOIN UNNEST(
  sequence(CAST(rango.desde AS date), CAST(rango.hasta AS date), interval '1' day)
) AS t(dia)
