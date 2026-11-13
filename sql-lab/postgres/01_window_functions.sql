-- =====================================================================
--  01 · WINDOW FUNCTIONS
--  Pregunta de entrevista:
--  "Calculá el promedio móvil de ventas de los últimos 7 días por región."
-- =====================================================================
SET search_path TO lab, public;

-- ---------------------------------------------------------------
-- PASO 0 · Agregar primero a nivel día+región.
--   Una window function opera sobre FILAS. Si hay varias ventas por
--   día, el promedio "de 7 filas" NO es "de 7 días". Siempre agregá
--   primero a la granularidad que te piden.
-- ---------------------------------------------------------------
CREATE OR REPLACE VIEW v_ventas_diarias AS
SELECT region, fecha, SUM(monto) AS ventas_dia, COUNT(*) AS n_ventas
FROM   ventas
GROUP  BY region, fecha;

-- ---------------------------------------------------------------
-- SOLUCIÓN A · ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
--   "Las últimas 7 filas" (día actual + 6 anteriores que EXISTEN).
--   Es la respuesta que el 90 % da en entrevista. Es correcta SOLO
--   si no hay días sin ventas.
-- ---------------------------------------------------------------
SELECT region, fecha, ventas_dia,
       ROUND(AVG(ventas_dia) OVER (
             PARTITION BY region
             ORDER BY fecha
             ROWS BETWEEN 6 PRECEDING AND CURRENT ROW), 2) AS media_movil_7filas,
       COUNT(*) OVER (
             PARTITION BY region
             ORDER BY fecha
             ROWS BETWEEN 6 PRECEDING AND CURRENT ROW)   AS filas_en_ventana
FROM   v_ventas_diarias
WHERE  region = 'Norte'
ORDER  BY fecha
LIMIT  15;

-- ---------------------------------------------------------------
-- SOLUCIÓN B · RANGE BETWEEN INTERVAL '6 days' PRECEDING  (PG 11+)
--   "Los últimos 7 días de calendario": si faltan días, la ventana
--   tiene menos filas. Es la respuesta que distingue al candidato.
-- ---------------------------------------------------------------
SELECT region, fecha, ventas_dia,
       ROUND(AVG(ventas_dia) OVER (
             PARTITION BY region
             ORDER BY fecha
             RANGE BETWEEN INTERVAL '6 days' PRECEDING AND CURRENT ROW), 2) AS media_movil_7dias,
       COUNT(*) OVER (
             PARTITION BY region
             ORDER BY fecha
             RANGE BETWEEN INTERVAL '6 days' PRECEDING AND CURRENT ROW)   AS dias_con_venta
FROM   v_ventas_diarias
WHERE  region = 'Norte'
ORDER  BY fecha
LIMIT  15;

-- ---------------------------------------------------------------
-- SOLUCIÓN C · Calendario completo (la más robusta y portable)
--   Generás los 7 días y los días sin ventas valen 0. Así el
--   promedio es "suma de 7 días / 7", que es lo que Negocio espera.
--   Funciona igual en SQL Server (con una tabla calendario).
-- ---------------------------------------------------------------
WITH calendario AS (
    SELECT d::date AS fecha
    FROM   generate_series((SELECT MIN(fecha) FROM ventas),
                           (SELECT MAX(fecha) FROM ventas), interval '1 day') d
), regiones AS (
    SELECT DISTINCT region FROM ventas
), base AS (
    SELECT r.region, c.fecha, COALESCE(v.ventas_dia, 0) AS ventas_dia
    FROM   regiones r
    CROSS  JOIN calendario c
    LEFT   JOIN v_ventas_diarias v ON v.region = r.region AND v.fecha = c.fecha
)
SELECT region, fecha, ventas_dia,
       ROUND(AVG(ventas_dia) OVER w, 2) AS media_movil_7d,
       ROUND(SUM(ventas_dia) OVER w, 2) AS suma_7d,
       -- Diferencia vs el día anterior (LAG)
       ventas_dia - LAG(ventas_dia, 1) OVER (PARTITION BY region ORDER BY fecha) AS delta_vs_ayer,
       -- Acumulado del año (running total)
       ROUND(SUM(ventas_dia) OVER (PARTITION BY region ORDER BY fecha
                                   ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW), 2) AS acumulado_ytd
FROM   base
WINDOW w AS (PARTITION BY region ORDER BY fecha ROWS BETWEEN 6 PRECEDING AND CURRENT ROW)
ORDER  BY region, fecha
LIMIT  20;

-- ---------------------------------------------------------------
-- PREGUNTAS DE SEGUIMIENTO típicas (y su respuesta)
-- ---------------------------------------------------------------

-- P1 · "¿Y si quiero que los primeros 6 días NO tengan promedio (ventana incompleta)?"
SELECT region, fecha,
       CASE WHEN COUNT(*) OVER w = 7
            THEN ROUND(AVG(ventas_dia) OVER w, 2) END AS media_movil_7d_completa
FROM   v_ventas_diarias
WINDOW w AS (PARTITION BY region ORDER BY fecha ROWS BETWEEN 6 PRECEDING AND CURRENT ROW)
ORDER  BY region, fecha
LIMIT  10;

-- P2 · "Ranking de regiones por ventas de cada mes" (RANK vs DENSE_RANK vs ROW_NUMBER)
WITH mensual AS (
    SELECT date_trunc('month', fecha)::date AS mes, region, SUM(monto) AS ventas
    FROM   ventas GROUP BY 1, 2
)
SELECT mes, region, ventas,
       RANK()       OVER (PARTITION BY mes ORDER BY ventas DESC) AS rk,
       DENSE_RANK() OVER (PARTITION BY mes ORDER BY ventas DESC) AS drk,
       ROW_NUMBER() OVER (PARTITION BY mes ORDER BY ventas DESC) AS rn
FROM   mensual
ORDER  BY mes, rk
LIMIT  12;
-- RANK deja huecos (1,1,3), DENSE_RANK no (1,1,2), ROW_NUMBER nunca empata (1,2,3).

-- P3 · "Top 3 vendedores por región" (filtrar sobre una window function => subquery/CTE)
WITH ranked AS (
    SELECT region, vendedor, SUM(monto) AS ventas,
           DENSE_RANK() OVER (PARTITION BY region ORDER BY SUM(monto) DESC) AS pos
    FROM   ventas GROUP BY region, vendedor
)
SELECT * FROM ranked WHERE pos <= 3 ORDER BY region, pos;
-- No se puede poner una window function en WHERE: se evalúa después del WHERE.

-- P4 · "Porcentaje que representa cada región sobre el total del mes"
SELECT date_trunc('month', fecha)::date AS mes, region, SUM(monto) AS ventas,
       ROUND(100.0 * SUM(monto) / SUM(SUM(monto)) OVER (PARTITION BY date_trunc('month', fecha)::date), 2) AS pct_mes
FROM   ventas
GROUP  BY date_trunc('month', fecha)::date, region
ORDER  BY 1, 2
LIMIT  8;
-- SUM(SUM(monto)) OVER (...) = window sobre un agregado. Patrón muy habitual en BI.

-- P5 · "Variación vs mismo mes del año anterior" (LAG con offset 12 sobre serie mensual)
WITH mensual AS (
    SELECT region, date_trunc('month', fecha)::date AS mes, SUM(monto) AS ventas
    FROM ventas GROUP BY 1, 2
)
SELECT region, mes, ventas,
       LAG(ventas, 1)  OVER (PARTITION BY region ORDER BY mes) AS mes_anterior,
       ROUND(100.0 * (ventas / NULLIF(LAG(ventas, 1) OVER (PARTITION BY region ORDER BY mes), 0) - 1), 2) AS var_pct_mom
FROM   mensual
ORDER  BY region, mes
LIMIT  8;

-- ---------------------------------------------------------------
-- CHULETA: orden lógico de ejecución
--   FROM -> WHERE -> GROUP BY -> HAVING -> [WINDOW] -> SELECT -> DISTINCT -> ORDER BY -> LIMIT
--   Por eso: una window function puede usar agregados (SUM(SUM(x)) OVER ...),
--   pero no puede ir en WHERE/HAVING; hay que envolverla en CTE/subquery.
-- Frame por defecto con ORDER BY: RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
--   (¡incluye empates! usar ROWS si querés "fila a fila").
-- ---------------------------------------------------------------
