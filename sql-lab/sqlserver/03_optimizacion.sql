-- =====================================================================
--  03 · OPTIMIZACIÓN (T-SQL)
--  "Esta query tarda 45 minutos. ¿Cómo la mejorás?"
--  Proceso: medir -> reescribir (sargable) -> indexar -> estadísticas ->
--           particionar -> materializar (vista indexada / tabla agregada) -> arquitectura
--  En SSMS: activar "Include Actual Execution Plan" (Ctrl+M) antes de ejecutar.
-- =====================================================================
USE sql_lab;
GO
SET QUOTED_IDENTIFIER ON; SET ANSI_NULLS ON;   -- requisito de la vista indexada del PASO 5
SET STATISTICS IO ON;    -- lecturas lógicas por tabla  (el "BUFFERS" de PostgreSQL)
SET STATISTICS TIME ON;  -- CPU y tiempo transcurrido
GO

-- LA QUERY "LENTA": funciones sobre columnas (no sargable) + sin índices
SELECT u.pais, u.plan, COUNT(*) AS compras,
       SUM(TRY_CAST(JSON_VALUE(e.payload, '$.v') AS int)) AS valor
FROM   lab.eventos e
JOIN   lab.usuarios u ON u.id_usuario = e.id_usuario
WHERE  CAST(e.created_at AS date) BETWEEN '2025-07-01' AND '2025-09-30'
  AND  LOWER(e.tipo_evento) = 'purchase'
GROUP  BY u.pais, u.plan
ORDER  BY compras DESC;
-- Plan esperado: Clustered Index Scan sobre eventos (toda la tabla) + Hash Match.
GO

-- PASO 1 · Reescritura sargable: rango abierto por la derecha sobre la columna cruda
SELECT u.pais, u.plan, COUNT(*) AS compras,
       SUM(TRY_CAST(JSON_VALUE(e.payload, '$.v') AS int)) AS valor
FROM   lab.eventos e
JOIN   lab.usuarios u ON u.id_usuario = e.id_usuario
WHERE  e.created_at >= '2025-07-01' AND e.created_at < '2025-10-01'
  AND  e.tipo_evento = 'purchase'          -- la collation por defecto ya es case-insensitive
GROUP  BY u.pais, u.plan
ORDER  BY compras DESC;
GO

-- PASO 2 · Índice: igualdad primero, rango después, INCLUDE para cubrir el SELECT
CREATE NONCLUSTERED INDEX ix_eventos_tipo_fecha
    ON lab.eventos (tipo_evento, created_at) INCLUDE (id_usuario);
-- Índice FILTRADO (equivalente al índice parcial de PG) si siempre filtrás 'purchase':
CREATE NONCLUSTERED INDEX ix_eventos_purchase_fecha
    ON lab.eventos (created_at) INCLUDE (id_usuario, payload)
    WHERE tipo_evento = 'purchase';
GO
SELECT u.pais, u.plan, COUNT(*) AS compras,
       SUM(TRY_CAST(JSON_VALUE(e.payload, '$.v') AS int)) AS valor
FROM   lab.eventos e
JOIN   lab.usuarios u ON u.id_usuario = e.id_usuario
WHERE  e.created_at >= '2025-07-01' AND e.created_at < '2025-10-01'
  AND  e.tipo_evento = 'purchase'
GROUP  BY u.pais, u.plan
ORDER  BY compras DESC;
-- Ahora: Index Seek. Compará "logical reads" antes/después.
GO

-- PASO 3 · Estadísticas y DMVs
-- ¿Estimaciones correctas? En el plan real: "Estimated Number of Rows" vs "Actual Number of Rows".
DBCC SHOW_STATISTICS ('lab.eventos', ix_eventos_tipo_fecha) WITH HISTOGRAM;
-- Índices que faltan según el motor (pista, no verdad absoluta)
SELECT TOP (10) migs.avg_user_impact, mid.statement, mid.equality_columns, mid.inequality_columns, mid.included_columns
FROM   sys.dm_db_missing_index_groups mig
JOIN   sys.dm_db_missing_index_group_stats migs ON migs.group_handle = mig.index_group_handle
JOIN   sys.dm_db_missing_index_details mid ON mid.index_handle = mig.index_handle
WHERE  mid.database_id = DB_ID()
ORDER  BY migs.avg_user_impact DESC;
-- Uso de índices (¿cuáles no se usan y solo cuestan en escrituras?)
SELECT i.name, s.user_seeks, s.user_scans, s.user_lookups, s.user_updates
FROM   sys.indexes i
LEFT   JOIN sys.dm_db_index_usage_stats s ON s.object_id = i.object_id AND s.index_id = i.index_id AND s.database_id = DB_ID()
WHERE  i.object_id = OBJECT_ID('lab.eventos');
GO

-- PASO 4 · Particionado por rango de fecha (Enterprise/Developer, o Standard desde 2016 SP1)
CREATE PARTITION FUNCTION pf_mes (datetime2(0)) AS RANGE RIGHT FOR VALUES
 ('2025-02-01','2025-03-01','2025-04-01','2025-05-01','2025-06-01','2025-07-01',
  '2025-08-01','2025-09-01','2025-10-01','2025-11-01','2025-12-01');
CREATE PARTITION SCHEME ps_mes AS PARTITION pf_mes ALL TO ([PRIMARY]);
GO
DROP TABLE IF EXISTS lab.eventos_part;
CREATE TABLE lab.eventos_part (
    id_evento   bigint       NOT NULL,
    id_usuario  int          NOT NULL,
    tipo_evento varchar(10)  NOT NULL,
    created_at  datetime2(0) NOT NULL,
    payload     nvarchar(max) NULL,
    CONSTRAINT pk_eventos_part PRIMARY KEY CLUSTERED (created_at, id_evento)   -- la clave de partición va en el índice clustered
) ON ps_mes (created_at);
INSERT INTO lab.eventos_part SELECT id_evento, id_usuario, tipo_evento, created_at, payload FROM lab.eventos;
CREATE INDEX ix_eventos_part_tipo ON lab.eventos_part (tipo_evento, created_at) INCLUDE (id_usuario) ON ps_mes (created_at);
GO
SELECT u.pais, u.plan, COUNT(*) AS compras
FROM   lab.eventos_part e JOIN lab.usuarios u ON u.id_usuario = e.id_usuario
WHERE  e.created_at >= '2025-07-01' AND e.created_at < '2025-10-01' AND e.tipo_evento = 'purchase'
GROUP  BY u.pais, u.plan;
-- En el plan: propiedad "Actual Partition Count = 3" (partition elimination).
-- Ver filas por partición:
SELECT $PARTITION.pf_mes(created_at) AS particion, COUNT(*) FROM lab.eventos_part GROUP BY $PARTITION.pf_mes(created_at) ORDER BY 1;
GO

-- PASO 5 · Materializar: vista indexada (se mantiene sola) o tabla agregada (ETL)
--   Restricciones de vista indexada: SCHEMABINDING, COUNT_BIG, sin LEFT JOIN/subqueries/funciones no deterministas.
CREATE OR ALTER VIEW lab.v_compras_diarias WITH SCHEMABINDING AS
SELECT CAST(e.created_at AS date) AS dia, u.pais, u.plan,
       COUNT_BIG(*) AS compras
FROM   lab.eventos e JOIN lab.usuarios u ON u.id_usuario = e.id_usuario
WHERE  e.tipo_evento = 'purchase'
GROUP  BY CAST(e.created_at AS date), u.pais, u.plan;
GO
CREATE UNIQUE CLUSTERED INDEX ux_v_compras_diarias ON lab.v_compras_diarias (dia, pais, plan);
GO
SELECT pais, plan, SUM(compras) AS compras
FROM   lab.v_compras_diarias WITH (NOEXPAND)      -- NOEXPAND fuerza usar la vista en ediciones Standard
WHERE  dia BETWEEN '2025-07-01' AND '2025-09-30'
GROUP  BY pais, plan ORDER BY compras DESC;
GO

-- PASO 6 · Anti-patrones a nombrar
--  (1) subquery correlacionada en SELECT -> JOIN / window      (5) SELECT * con nvarchar(max)
--  (2) DISTINCT para tapar un JOIN que multiplica               (6) funciones sobre columnas indexadas
--  (3) OR entre columnas -> UNION ALL                          (7) parameter sniffing (OPTION (RECOMPILE) / OPTIMIZE FOR)
--  (4) NOT IN con NULLs -> NOT EXISTS                          (8) conversiones implícitas (nvarchar vs varchar en el JOIN)
--  (9) cursores / WHILE fila a fila -> set-based               (10) estadísticas desactualizadas tras cargas masivas
SELECT COUNT(*) FROM lab.usuarios u
WHERE NOT EXISTS (SELECT 1 FROM lab.eventos e WHERE e.id_usuario = u.id_usuario AND e.tipo_evento = 'purchase');
GO
SET STATISTICS IO OFF; SET STATISTICS TIME OFF;
GO
