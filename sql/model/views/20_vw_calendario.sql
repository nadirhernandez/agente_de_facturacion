-- Calendario continuo por moneda, desde su primer hasta su último día emitido.
--
-- Cada moneda tiene su propio rango para que días sin ventas aparezcan en cero
-- sin crear combinaciones ni totales monetarios cruzados.
CREATE OR REPLACE VIEW ${db}.vw_calendario AS
WITH rango AS (
  SELECT
    codigo_moneda,
    min(fecha) AS desde,
    max(fecha) AS hasta
  FROM ${db}.agg_ventas_diario_moneda
  WHERE facturas > 0
  GROUP BY codigo_moneda
)
SELECT
  rango.codigo_moneda,
  CAST(dia AS date)                      AS fecha,
  year(dia)                              AS anio,
  month(dia)                             AS mes,
  week(dia)                              AS semana_iso,
  year_of_week(dia)                      AS anio_semana_iso,
  CAST(date_trunc('week', dia) AS date)  AS inicio_semana,
  CAST(date_trunc('month', dia) AS date) AS inicio_mes,
  CAST(date_trunc('year', dia) AS date)  AS inicio_anio,
  day_of_week(dia)                       AS dia_semana_numero,
  CASE day_of_week(dia)
    WHEN 1 THEN 'lunes'
    WHEN 2 THEN 'martes'
    WHEN 3 THEN 'miércoles'
    WHEN 4 THEN 'jueves'
    WHEN 5 THEN 'viernes'
    WHEN 6 THEN 'sábado'
    ELSE 'domingo'
  END                                    AS dia_semana,
  day_of_week(dia) >= 6                  AS es_fin_semana
FROM rango
CROSS JOIN UNNEST(
  sequence(CAST(rango.desde AS date), CAST(rango.hasta AS date), interval '1' day)
) AS t(dia)
