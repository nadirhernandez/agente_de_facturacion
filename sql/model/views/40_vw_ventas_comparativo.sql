-- Una fila por período y granularidad, con el período anterior inmediato y la
-- variación ya calculados. El chat filtra por granularidad en lugar de
-- reinventar la lógica de fechas en cada pregunta.
--
-- El conteo de facturas se puede sumar entre días porque una factura pertenece
-- a un solo día. Si eso cambiara, habría que recontar por período.
--
-- es_periodo_completo marca los períodos en curso: comparar uno a medias contra
-- uno completo exagera la caída, así que el chat los excluye de comparativos.
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
  SELECT max(fecha) AS ultimo_dia FROM ${db}.vw_ventas_diario
)
SELECT
  granularidad,
  periodo,
  year(periodo)  AS anio,
  month(periodo) AS mes,
  CASE granularidad
    WHEN 'dia'    THEN periodo
    WHEN 'semana' THEN date_add('day', 6, periodo)
    WHEN 'mes'    THEN date_add('day', -1, date_add('month', 1, periodo))
    ELSE date_add('day', -1, date_add('year', 1, periodo))
  END AS fin_periodo,
  CASE granularidad
    WHEN 'dia'    THEN periodo
    WHEN 'semana' THEN date_add('day', 6, periodo)
    WHEN 'mes'    THEN date_add('day', -1, date_add('month', 1, periodo))
    ELSE date_add('day', -1, date_add('year', 1, periodo))
  END <= (SELECT ultimo_dia FROM limite) AS es_periodo_completo,
  facturacion_total,
  ventas_sin_iva,
  iva,
  facturas,
  unidades,
  lag(facturacion_total) OVER (PARTITION BY granularidad ORDER BY periodo) AS facturacion_total_anterior,
  lag(ventas_sin_iva)    OVER (PARTITION BY granularidad ORDER BY periodo) AS ventas_sin_iva_anterior,
  lag(facturas)          OVER (PARTITION BY granularidad ORDER BY periodo) AS facturas_anterior,
  lag(unidades)          OVER (PARTITION BY granularidad ORDER BY periodo) AS unidades_anterior,
  CASE
    WHEN lag(facturacion_total) OVER (PARTITION BY granularidad ORDER BY periodo) IS NULL
      OR lag(facturacion_total) OVER (PARTITION BY granularidad ORDER BY periodo) = 0
    THEN NULL
    ELSE round(
      (facturacion_total - lag(facturacion_total) OVER (PARTITION BY granularidad ORDER BY periodo))
      / lag(facturacion_total) OVER (PARTITION BY granularidad ORDER BY periodo) * 100, 1)
  END AS variacion_facturacion_pct,
  CASE
    WHEN lag(facturas) OVER (PARTITION BY granularidad ORDER BY periodo) IS NULL
      OR lag(facturas) OVER (PARTITION BY granularidad ORDER BY periodo) = 0
    THEN NULL
    ELSE round(
      (CAST(facturas AS double) - lag(facturas) OVER (PARTITION BY granularidad ORDER BY periodo))
      / lag(facturas) OVER (PARTITION BY granularidad ORDER BY periodo) * 100, 1)
  END AS variacion_facturas_pct
FROM unificado
