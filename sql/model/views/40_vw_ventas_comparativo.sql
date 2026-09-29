-- Una fila por período y granularidad, con el período anterior inmediato y la
-- variación ya calculados. El chat filtra por granularidad en lugar de
-- reinventar la lógica de fechas en cada pregunta.
--
-- El conteo de facturas se puede sumar entre días porque una factura pertenece
-- a un solo día. Si eso cambiara, habría que recontar por período.
--
-- es_periodo_completo marca los períodos que no se pueden comparar tal cual,
-- porque comparar uno a medias contra uno completo exagera la variación:
--   - el período en curso: termina hoy o después (hoy en Guatemala, UTC-06:00)
--     o después del último día cargado;
--   - el primer período del histórico cuando los datos empiezan a media semana,
--     mes o año.
-- El dataset se refresca cada hora, así "hoy" no se queda atrasado en SPICE.
CREATE OR REPLACE VIEW ${db}.vw_ventas_comparativo AS
WITH por_dia AS (
  SELECT
    'dia'             AS granularidad,
    fecha             AS periodo,
    facturacion_total,
    ventas_sin_iva,
    iva,
    facturas,
    unidades
  FROM ${db}.vw_ventas_diario
),
por_semana AS (
  SELECT
    'semana'               AS granularidad,
    inicio_semana          AS periodo,
    sum(facturacion_total) AS facturacion_total,
    sum(ventas_sin_iva)    AS ventas_sin_iva,
    sum(iva)               AS iva,
    sum(facturas)          AS facturas,
    sum(unidades)          AS unidades
  FROM ${db}.vw_ventas_diario
  GROUP BY inicio_semana
),
por_mes AS (
  SELECT
    'mes'                  AS granularidad,
    inicio_mes             AS periodo,
    sum(facturacion_total) AS facturacion_total,
    sum(ventas_sin_iva)    AS ventas_sin_iva,
    sum(iva)               AS iva,
    sum(facturas)          AS facturas,
    sum(unidades)          AS unidades
  FROM ${db}.vw_ventas_diario
  GROUP BY inicio_mes
),
por_anio AS (
  SELECT
    'anio'                                  AS granularidad,
    CAST(date_trunc('year', fecha) AS date) AS periodo,
    sum(facturacion_total)                  AS facturacion_total,
    sum(ventas_sin_iva)                     AS ventas_sin_iva,
    sum(iva)                                AS iva,
    sum(facturas)                           AS facturas,
    sum(unidades)                           AS unidades
  FROM ${db}.vw_ventas_diario
  GROUP BY CAST(date_trunc('year', fecha) AS date)
),
unificado AS (
  SELECT * FROM por_dia
  UNION ALL SELECT * FROM por_semana
  UNION ALL SELECT * FROM por_mes
  UNION ALL SELECT * FROM por_anio
),
limite AS (
  SELECT
    min(fecha) AS primer_dia,
    max(fecha) AS ultimo_dia,
    CAST(current_timestamp AT TIME ZONE '-06:00' AS date) AS hoy
  FROM ${db}.vw_ventas_diario
),
con_limites AS (
  SELECT
    u.*,
    CASE u.granularidad
      WHEN 'dia'    THEN u.periodo
      WHEN 'semana' THEN date_add('day', 6, u.periodo)
      WHEN 'mes'    THEN date_add('day', -1, date_add('month', 1, u.periodo))
      ELSE date_add('day', -1, date_add('year', 1, u.periodo))
    END AS fin_periodo,
    l.primer_dia,
    l.ultimo_dia,
    l.hoy
  FROM unificado u
  CROSS JOIN limite l
),
con_anterior AS (
  SELECT
    c.*,
    lag(facturacion_total) OVER (PARTITION BY granularidad ORDER BY periodo) AS facturacion_total_anterior,
    lag(ventas_sin_iva)    OVER (PARTITION BY granularidad ORDER BY periodo) AS ventas_sin_iva_anterior,
    lag(facturas)          OVER (PARTITION BY granularidad ORDER BY periodo) AS facturas_anterior,
    lag(unidades)          OVER (PARTITION BY granularidad ORDER BY periodo) AS unidades_anterior
  FROM con_limites c
)
SELECT
  granularidad,
  periodo,
  year(periodo)  AS anio,
  month(periodo) AS mes,
  fin_periodo,
  (periodo >= primer_dia AND fin_periodo <= ultimo_dia AND fin_periodo < hoy) AS es_periodo_completo,
  facturacion_total,
  ventas_sin_iva,
  iva,
  facturas,
  unidades,
  facturacion_total_anterior,
  ventas_sin_iva_anterior,
  facturas_anterior,
  unidades_anterior,
  CASE
    WHEN facturacion_total_anterior IS NULL OR facturacion_total_anterior = 0 THEN NULL
    ELSE round((facturacion_total - facturacion_total_anterior) / facturacion_total_anterior * 100, 1)
  END AS variacion_facturacion_pct,
  CASE
    WHEN facturas_anterior IS NULL OR facturas_anterior = 0 THEN NULL
    ELSE round((CAST(facturas AS double) - facturas_anterior) / facturas_anterior * 100, 1)
  END AS variacion_facturas_pct
FROM con_anterior
