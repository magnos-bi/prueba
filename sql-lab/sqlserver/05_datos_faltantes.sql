-- =====================================================================
--  05 · DATOS FALTANTES / BACKFILL (T-SQL)
--  "Un pipeline dejó NULLs en una columna crítica hace 3 meses.
--   ¿Cómo lo detectás y corregís?"
--  Dimensionar -> causa raíz -> fuente de verdad (backfill) o imputar
--  marcándolo -> ejecutar por lotes e idempotente -> prevenir con tests
-- =====================================================================
USE sql_lab;
GO
-- PASO 1 · Dimensionar
SELECT COUNT(*) AS filas,
       COUNT(*) - COUNT(canal_venta) AS nulos_canal,
       CAST(100.0 * (COUNT(*) - COUNT(canal_venta)) / COUNT(*) AS decimal(5,2)) AS pct_nulos_canal,
       COUNT(*) - COUNT(id_cliente) AS nulos_cliente,
       COUNT(*) - COUNT(importe)    AS nulos_importe
FROM   lab.pedidos;

-- % de nulos por semana
SELECT DATEADD(week, DATEDIFF(week, 0, fecha_pedido), 0) AS semana,
       COUNT(*) AS pedidos,
       SUM(CASE WHEN canal_venta IS NULL THEN 1 ELSE 0 END) AS nulos,
       CAST(100.0 * SUM(CASE WHEN canal_venta IS NULL THEN 1 ELSE 0 END) / COUNT(*) AS decimal(5,1)) AS pct_nulos
FROM   lab.pedidos
GROUP  BY DATEADD(week, DATEDIFF(week, 0, fecha_pedido), 0)
ORDER  BY semana;

-- Inicio / fin exacto del incidente
;WITH diario AS (
    SELECT fecha_pedido, 100.0 * SUM(CASE WHEN canal_venta IS NULL THEN 1 ELSE 0 END) / COUNT(*) AS pct_nulos
    FROM lab.pedidos GROUP BY fecha_pedido
)
SELECT MIN(fecha_pedido) AS inicio_incidente, MAX(fecha_pedido) AS fin_incidente, COUNT(*) AS dias_afectados
FROM   diario WHERE pct_nulos > 50;

-- El "salto" con LAG: la fecha del deploy que rompió el pipeline
;WITH diario AS (
    SELECT fecha_pedido, 100.0 * SUM(CASE WHEN canal_venta IS NULL THEN 1 ELSE 0 END) / COUNT(*) AS pct_nulos
    FROM lab.pedidos GROUP BY fecha_pedido
), con_lag AS (
    SELECT fecha_pedido, pct_nulos, pct_nulos - LAG(pct_nulos) OVER (ORDER BY fecha_pedido) AS salto FROM diario
)
SELECT fecha_pedido, CAST(pct_nulos AS decimal(5,1)) AS pct_nulos, CAST(salto AS decimal(5,1)) AS salto
FROM   con_lag WHERE ABS(salto) > 40 ORDER BY fecha_pedido;

-- Días sin ningún pedido (huecos en la serie)
SELECT TOP (10) DATEADD(day, n - 1, '2025-01-01') AS dia
FROM   lab.Numeros nu
WHERE  n <= 334
  AND  NOT EXISTS (SELECT 1 FROM lab.pedidos p WHERE p.fecha_pedido = DATEADD(day, nu.n - 1, '2025-01-01'));
GO

-- PASO 2 · ESTRATEGIA A: backfill desde la fuente de verdad
DROP TABLE IF EXISTS lab.pedidos_backfill_log;
SELECT p.id_pedido, p.canal_venta AS valor_anterior, f.canal_venta AS valor_nuevo,
       'fuente' AS metodo, SYSDATETIME() AS ejecutado_en
INTO   lab.pedidos_backfill_log
FROM   lab.pedidos p JOIN lab.pedidos_fuente f ON f.id_pedido = p.id_pedido
WHERE  p.canal_venta IS NULL AND f.canal_venta IS NOT NULL;
SELECT COUNT(*) AS a_corregir FROM lab.pedidos_backfill_log;

-- Dry-run: ¿hay nulos sin fuente?
SELECT SUM(CASE WHEN f.canal_venta IS NOT NULL THEN 1 ELSE 0 END) AS con_fuente,
       SUM(CASE WHEN f.id_pedido IS NULL THEN 1 ELSE 0 END)       AS sin_fuente
FROM   lab.pedidos p LEFT JOIN lab.pedidos_fuente f ON f.id_pedido = p.id_pedido
WHERE  p.canal_venta IS NULL;
GO
-- UPDATE por lotes, idempotente (solo toca lo que sigue NULL; se puede relanzar)
DECLARE @n int = 1, @total bigint = 0;
WHILE @n > 0
BEGIN
    UPDATE TOP (20000) p
    SET    p.canal_venta = f.canal_venta
    FROM   lab.pedidos p JOIN lab.pedidos_fuente f ON f.id_pedido = p.id_pedido
    WHERE  p.canal_venta IS NULL AND f.canal_venta IS NOT NULL;
    SET @n = @@ROWCOUNT; SET @total += @n;
    RAISERROR('lote %d (acumulado %I64d)', 0, 1, @n, @total) WITH NOWAIT;
END
SELECT SUM(CASE WHEN canal_venta IS NULL THEN 1 ELSE 0 END) AS nulos_restantes FROM lab.pedidos;
GO
-- Verificación: distribución del período corregido vs período sano
;WITH b AS (
    SELECT CASE WHEN fecha_pedido BETWEEN '2025-07-10' AND '2025-10-05' THEN 'corregido' ELSE 'sano' END AS periodo, canal_venta
    FROM lab.pedidos
)
SELECT periodo, canal_venta,
       CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY periodo) AS decimal(5,1)) AS pct
FROM   b GROUP BY periodo, canal_venta ORDER BY periodo, canal_venta;
GO

-- PASO 3 · ESTRATEGIA B: no hay fuente -> imputar y MARCAR
DROP TABLE IF EXISTS lab.pedidos_imput;
SELECT id_pedido, fecha_pedido, id_cliente, importe,
       CASE WHEN fecha_pedido BETWEEN '2025-07-10' AND '2025-10-05' AND ABS(CHECKSUM(NEWID())) % 100 < 97
            THEN NULL ELSE canal_venta END AS canal_venta,
       CAST(NULL AS varchar(20)) AS canal_imputado_por
INTO   lab.pedidos_imput
FROM   lab.pedidos;
GO
-- B1 · LOCF por cliente.
--   SQL Server 2022+: LAG(canal_venta) IGNORE NULLS OVER (...)   <- una línea.
--   Versiones anteriores: truco de "grupos" con COUNT acumulado + MAX por grupo.
;WITH grupos AS (
    SELECT id_pedido, id_cliente, canal_venta,
           COUNT(canal_venta) OVER (PARTITION BY id_cliente ORDER BY fecha_pedido, id_pedido ROWS UNBOUNDED PRECEDING) AS grp
    FROM lab.pedidos_imput
), relleno AS (
    SELECT id_pedido, MAX(canal_venta) OVER (PARTITION BY id_cliente, grp) AS canal_locf FROM grupos
)
UPDATE p SET canal_venta = r.canal_locf, canal_imputado_por = 'locf_cliente'
FROM   lab.pedidos_imput p JOIN relleno r ON r.id_pedido = p.id_pedido
WHERE  p.canal_venta IS NULL AND r.canal_locf IS NOT NULL;

-- B2 · Lo que queda: moda global de los valores reales
UPDATE lab.pedidos_imput
SET    canal_venta = (SELECT TOP (1) canal_venta FROM lab.pedidos_imput
                      WHERE canal_venta IS NOT NULL AND canal_imputado_por IS NULL
                      GROUP BY canal_venta ORDER BY COUNT(*) DESC),
       canal_imputado_por = 'moda_global'
WHERE  canal_venta IS NULL;

-- B3 · Alternativa honesta: 'desconocido' y que el informe lo muestre
SELECT canal_imputado_por, COUNT(*) AS filas FROM lab.pedidos_imput GROUP BY canal_imputado_por ORDER BY filas DESC;
GO

-- PASO 4 · Prevenir: vista de calidad que corre tras cada carga
CREATE OR ALTER VIEW lab.v_dq_pedidos AS
SELECT fecha_pedido, COUNT(*) AS filas,
       CAST(100.0 * SUM(CASE WHEN canal_venta IS NULL THEN 1 ELSE 0 END) / COUNT(*) AS decimal(5,2)) AS pct_nulos_canal,
       SUM(CASE WHEN canal_venta NOT IN ('web','tienda','telefono','app') THEN 1 ELSE 0 END) AS valores_invalidos,
       CASE WHEN 100.0 * SUM(CASE WHEN canal_venta IS NULL THEN 1 ELSE 0 END) / COUNT(*) > 1 THEN 'ALERTA' ELSE 'OK' END AS estado
FROM   lab.pedidos
GROUP  BY fecha_pedido;
GO
SELECT estado, COUNT(*) AS dias FROM lab.v_dq_pedidos GROUP BY estado;
-- Y si el negocio dice que no puede ser NULL, que lo imponga la BD:
-- ALTER TABLE lab.pedidos ALTER COLUMN canal_venta varchar(10) NOT NULL;
GO
