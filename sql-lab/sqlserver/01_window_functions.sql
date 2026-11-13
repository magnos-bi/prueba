-- =====================================================================
--  01 · WINDOW FUNCTIONS (T-SQL)
--  "Calculá el promedio móvil de ventas de los últimos 7 días por región."
-- =====================================================================
USE sql_lab;
GO
-- PASO 0 · Agregar a nivel día + región (una window function cuenta FILAS, no días)
CREATE OR ALTER VIEW lab.v_ventas_diarias AS
SELECT region, fecha, SUM(monto) AS ventas_dia, COUNT(*) AS n_ventas
FROM   lab.ventas GROUP BY region, fecha;
GO

-- SOLUCIÓN A · ROWS BETWEEN 6 PRECEDING AND CURRENT ROW ("últimas 7 filas")
SELECT TOP (15) region, fecha, ventas_dia,
       CAST(AVG(ventas_dia) OVER (PARTITION BY region ORDER BY fecha
                                  ROWS BETWEEN 6 PRECEDING AND CURRENT ROW) AS decimal(12,2)) AS media_movil_7filas,
       COUNT(*)        OVER (PARTITION BY region ORDER BY fecha
                                  ROWS BETWEEN 6 PRECEDING AND CURRENT ROW) AS filas_en_ventana
FROM   lab.v_ventas_diarias
WHERE  region = 'Norte'
ORDER  BY fecha;

-- SOLUCIÓN B · "últimos 7 días de calendario".
--   SQL Server NO soporta RANGE BETWEEN INTERVAL (solo UNBOUNDED/CURRENT ROW).
--   Alternativa 1: self-join / APPLY sobre el rango de fechas.
SELECT TOP (15) d.region, d.fecha, d.ventas_dia,
       CAST(x.media AS decimal(12,2)) AS media_movil_7dias, x.dias_con_venta
FROM   lab.v_ventas_diarias d
CROSS  APPLY (SELECT AVG(v.ventas_dia) AS media, COUNT(*) AS dias_con_venta
              FROM   lab.v_ventas_diarias v
              WHERE  v.region = d.region
                AND  v.fecha BETWEEN DATEADD(day, -6, d.fecha) AND d.fecha) x
WHERE  d.region = 'Norte'
ORDER  BY d.fecha;

-- SOLUCIÓN C · Calendario completo (la robusta): días sin venta = 0.
;WITH calendario AS (
    SELECT DATEADD(day, n - 1, (SELECT MIN(fecha) FROM lab.ventas)) AS fecha
    FROM   lab.Numeros
    WHERE  n <= DATEDIFF(day, (SELECT MIN(fecha) FROM lab.ventas), (SELECT MAX(fecha) FROM lab.ventas)) + 1
), regiones AS (SELECT DISTINCT region FROM lab.ventas),
base AS (
    SELECT r.region, c.fecha, COALESCE(v.ventas_dia, 0) AS ventas_dia
    FROM   regiones r CROSS JOIN calendario c
    LEFT   JOIN lab.v_ventas_diarias v ON v.region = r.region AND v.fecha = c.fecha
)
SELECT TOP (20) region, fecha, ventas_dia,
       CAST(AVG(ventas_dia) OVER (PARTITION BY region ORDER BY fecha ROWS BETWEEN 6 PRECEDING AND CURRENT ROW) AS decimal(12,2)) AS media_movil_7d,
       SUM(ventas_dia)      OVER (PARTITION BY region ORDER BY fecha ROWS BETWEEN 6 PRECEDING AND CURRENT ROW) AS suma_7d,
       ventas_dia - LAG(ventas_dia, 1) OVER (PARTITION BY region ORDER BY fecha) AS delta_vs_ayer,
       SUM(ventas_dia)      OVER (PARTITION BY region ORDER BY fecha ROWS UNBOUNDED PRECEDING) AS acumulado_ytd
FROM   base
ORDER  BY region, fecha;
-- Nota: T-SQL no tiene cláusula WINDOW (hasta SQL Server 2022, que sí la añade).

-- P1 · Solo ventanas completas
SELECT TOP (10) region, fecha,
       CASE WHEN COUNT(*) OVER (PARTITION BY region ORDER BY fecha ROWS BETWEEN 6 PRECEDING AND CURRENT ROW) = 7
            THEN CAST(AVG(ventas_dia) OVER (PARTITION BY region ORDER BY fecha ROWS BETWEEN 6 PRECEDING AND CURRENT ROW) AS decimal(12,2)) END AS media_7d_completa
FROM   lab.v_ventas_diarias ORDER BY region, fecha;

-- P2 · RANK vs DENSE_RANK vs ROW_NUMBER por mes
;WITH mensual AS (
    SELECT DATEFROMPARTS(YEAR(fecha), MONTH(fecha), 1) AS mes, region, SUM(monto) AS ventas
    FROM   lab.ventas GROUP BY DATEFROMPARTS(YEAR(fecha), MONTH(fecha), 1), region
)
SELECT TOP (12) mes, region, ventas,
       RANK()       OVER (PARTITION BY mes ORDER BY ventas DESC) AS rk,
       DENSE_RANK() OVER (PARTITION BY mes ORDER BY ventas DESC) AS drk,
       ROW_NUMBER() OVER (PARTITION BY mes ORDER BY ventas DESC) AS rn
FROM   mensual ORDER BY mes, rk;

-- P3 · Top 3 vendedores por región (window function no puede ir en WHERE)
;WITH ranked AS (
    SELECT region, vendedor, SUM(monto) AS ventas,
           DENSE_RANK() OVER (PARTITION BY region ORDER BY SUM(monto) DESC) AS pos
    FROM   lab.ventas GROUP BY region, vendedor
)
SELECT * FROM ranked WHERE pos <= 3 ORDER BY region, pos;

-- P4 · % de cada región sobre el total del mes (window sobre un agregado)
SELECT TOP (8) DATEFROMPARTS(YEAR(fecha), MONTH(fecha), 1) AS mes, region, SUM(monto) AS ventas,
       CAST(100.0 * SUM(monto) / SUM(SUM(monto)) OVER (PARTITION BY DATEFROMPARTS(YEAR(fecha), MONTH(fecha), 1)) AS decimal(5,2)) AS pct_mes
FROM   lab.ventas
GROUP  BY DATEFROMPARTS(YEAR(fecha), MONTH(fecha), 1), region
ORDER  BY mes, region;

-- P5 · Variación mes a mes con LAG
;WITH mensual AS (
    SELECT region, DATEFROMPARTS(YEAR(fecha), MONTH(fecha), 1) AS mes, SUM(monto) AS ventas
    FROM   lab.ventas GROUP BY region, DATEFROMPARTS(YEAR(fecha), MONTH(fecha), 1)
)
SELECT TOP (8) region, mes, ventas,
       LAG(ventas) OVER (PARTITION BY region ORDER BY mes) AS mes_anterior,
       CAST(100.0 * (ventas / NULLIF(LAG(ventas) OVER (PARTITION BY region ORDER BY mes), 0) - 1) AS decimal(6,2)) AS var_pct_mom
FROM   mensual ORDER BY region, mes;

-- Mapeo a Power BI / DAX (para explicar que entendés el concepto, no solo la sintaxis):
--   media móvil 7d  -> AVERAGEX(DATESINPERIOD(Fecha[Date], MAX(Fecha[Date]), -7, DAY), [Ventas])
--   acumulado YTD   -> TOTALYTD([Ventas], Fecha[Date])
--   LAG mes         -> CALCULATE([Ventas], PREVIOUSMONTH(Fecha[Date]))
--   RANK            -> RANKX(ALL(Region[Region]), [Ventas])  /  WINDOW() y OFFSET() en DAX moderno
