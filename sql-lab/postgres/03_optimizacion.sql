-- =====================================================================
--  03 · OPTIMIZACIÓN
--  Pregunta de entrevista:
--  "Esta query tarda 45 minutos. ¿Cómo la mejorás?"
--
--  Lo que evalúan es el PROCESO, no un truco. Guion de respuesta:
--    1. Medir:     EXPLAIN (ANALYZE, BUFFERS)  -> ¿dónde se va el tiempo?
--    2. Índices:   ¿Seq Scan sobre tabla grande con filtro selectivo?
--    3. Reescribir: funciones sobre columnas, SELECT *, DISTINCT, OR, subqueries correlacionadas
--    4. Estadísticas: ANALYZE / work_mem / estimaciones erradas (rows=1 vs actual=1.000.000)
--    5. Particionar: tablas de hechos por fecha -> partition pruning
--    6. Materializar: si la consulta es repetitiva, pre-calcular (MV / tabla agregada)
--    7. Arquitectura: ¿tiene que correr en el OLTP? ¿incremental en vez de full?
-- =====================================================================
SET search_path TO lab, public;
\timing on

-- ---------------------------------------------------------------
-- LA QUERY "LENTA": eventos de compra del Q3 por país y plan.
--   Problemas plantados:
--     (a) DATE(created_at) en el WHERE  -> no es "sargable", mata cualquier índice
--     (b) sin índice en eventos(created_at) ni eventos(id_usuario)
--     (c) tipo_evento con LOWER()        -> idem (a)
-- ---------------------------------------------------------------
EXPLAIN (ANALYZE, BUFFERS)
SELECT u.pais, u.plan, COUNT(*) AS compras, SUM((e.payload->>'v')::int) AS valor
FROM   eventos e
JOIN   usuarios u ON u.id_usuario = e.id_usuario
WHERE  DATE(e.created_at) BETWEEN '2025-07-01' AND '2025-09-30'
  AND  LOWER(e.tipo_evento) = 'purchase'
GROUP  BY u.pais, u.plan
ORDER  BY compras DESC;
-- Fijate en: "Seq Scan on eventos", "Rows Removed by Filter", "shared read" (I/O de disco).

-- ---------------------------------------------------------------
-- PASO 1 · Reescritura "sargable": compará rangos contra la columna cruda.
--   DATE(created_at) BETWEEN a AND b  ==>  created_at >= a AND created_at < b + 1 día
-- ---------------------------------------------------------------
EXPLAIN (ANALYZE, BUFFERS)
SELECT u.pais, u.plan, COUNT(*) AS compras, SUM((e.payload->>'v')::int) AS valor
FROM   eventos e
JOIN   usuarios u ON u.id_usuario = e.id_usuario
WHERE  e.created_at >= timestamptz '2025-07-01'
  AND  e.created_at <  timestamptz '2025-10-01'
  AND  e.tipo_evento = 'purchase'
GROUP  BY u.pais, u.plan
ORDER  BY compras DESC;
-- Todavía Seq Scan (no hay índice), pero ahora el planificador PUEDE usar uno.

-- ---------------------------------------------------------------
-- PASO 2 · Índice. ¿Cuál?
--   Columna más selectiva primero si ambas son de igualdad; si una es
--   rango (created_at) y otra igualdad (tipo_evento), la de IGUALDAD va
--   primero: (tipo_evento, created_at).
--   INCLUDE evita ir a la tabla (index-only scan) para las columnas del SELECT.
-- ---------------------------------------------------------------
CREATE INDEX IF NOT EXISTS ix_eventos_tipo_fecha
    ON eventos (tipo_evento, created_at) INCLUDE (id_usuario);
ANALYZE eventos;

EXPLAIN (ANALYZE, BUFFERS)
SELECT u.pais, u.plan, COUNT(*) AS compras, SUM((e.payload->>'v')::int) AS valor
FROM   eventos e
JOIN   usuarios u ON u.id_usuario = e.id_usuario
WHERE  e.created_at >= timestamptz '2025-07-01'
  AND  e.created_at <  timestamptz '2025-10-01'
  AND  e.tipo_evento = 'purchase'
GROUP  BY u.pais, u.plan
ORDER  BY compras DESC;
-- Debería aparecer "Index Scan / Bitmap Index Scan using ix_eventos_tipo_fecha".
-- Nota: SUM(payload->>'v') obliga a leer el heap; si quitás esa columna verás Index Only Scan.

-- Alternativa: índice PARCIAL si siempre filtrás el mismo valor (más pequeño, más rápido)
CREATE INDEX IF NOT EXISTS ix_eventos_purchase_fecha
    ON eventos (created_at) INCLUDE (id_usuario) WHERE tipo_evento = 'purchase';

-- ---------------------------------------------------------------
-- PASO 3 · Estadísticas: ¿el planificador estima bien?
--   Compará "rows=" (estimado) vs "actual rows=" en el EXPLAIN. Si difieren
--   en órdenes de magnitud, ANALYZE o subir default_statistics_target.
-- ---------------------------------------------------------------
SELECT attname, n_distinct, correlation
FROM   pg_stats WHERE schemaname = 'lab' AND tablename = 'eventos';

-- Ver índices y su uso (¿hay índices que nadie usa? ¿falta alguno?)
SELECT indexrelname, idx_scan, pg_size_pretty(pg_relation_size(indexrelid)) AS tamano
FROM   pg_stat_user_indexes WHERE schemaname = 'lab' AND relname = 'eventos';

-- ---------------------------------------------------------------
-- PASO 4 · Particionado por rango de fecha (partition pruning).
--   Útil cuando casi todas las consultas filtran por fecha y la tabla
--   es enorme. Además facilita purgar datos viejos (DROP PARTITION).
-- ---------------------------------------------------------------
DROP TABLE IF EXISTS eventos_part CASCADE;
CREATE TABLE eventos_part (
    id_evento   bigint      NOT NULL,
    id_usuario  int         NOT NULL,
    tipo_evento text        NOT NULL,
    created_at  timestamptz NOT NULL,
    payload     jsonb,
    PRIMARY KEY (id_evento, created_at)        -- la clave de partición debe estar en la PK
) PARTITION BY RANGE (created_at);

-- Una partición por mes, generadas dinámicamente
DO $$
DECLARE m date;
BEGIN
  FOR m IN SELECT generate_series(date '2025-01-01', date '2025-12-01', interval '1 month')
  LOOP
    EXECUTE format(
      'CREATE TABLE eventos_part_%s PARTITION OF eventos_part FOR VALUES FROM (%L) TO (%L)',
      to_char(m, 'YYYYMM'), m, m + interval '1 month');
  END LOOP;
END $$;
CREATE TABLE eventos_part_default PARTITION OF eventos_part DEFAULT;

INSERT INTO eventos_part SELECT * FROM eventos;
CREATE INDEX ON eventos_part (tipo_evento, created_at);   -- se crea en cada partición
ANALYZE eventos_part;

EXPLAIN (ANALYZE, BUFFERS)
SELECT u.pais, u.plan, COUNT(*) AS compras
FROM   eventos_part e
JOIN   usuarios u ON u.id_usuario = e.id_usuario
WHERE  e.created_at >= timestamptz '2025-07-01'
  AND  e.created_at <  timestamptz '2025-10-01'
  AND  e.tipo_evento = 'purchase'
GROUP  BY u.pais, u.plan;
-- Solo aparecen eventos_part_202507/08/09: el resto se "poda" (pruning).

-- ---------------------------------------------------------------
-- PASO 5 · Materializar. Si el dashboard pide siempre "compras por
--   país/plan/día", pre-agregá. En BI esto es la tabla de hechos agregada.
-- ---------------------------------------------------------------
DROP MATERIALIZED VIEW IF EXISTS mv_compras_diarias;
CREATE MATERIALIZED VIEW mv_compras_diarias AS
SELECT date_trunc('day', e.created_at)::date AS dia, u.pais, u.plan,
       COUNT(*) AS compras, SUM((e.payload->>'v')::int) AS valor
FROM   eventos e JOIN usuarios u ON u.id_usuario = e.id_usuario
WHERE  e.tipo_evento = 'purchase'
GROUP  BY 1, 2, 3;
CREATE UNIQUE INDEX ON mv_compras_diarias (dia, pais, plan);  -- necesario para REFRESH CONCURRENTLY

EXPLAIN (ANALYZE, BUFFERS)
SELECT pais, plan, SUM(compras) AS compras, SUM(valor) AS valor
FROM   mv_compras_diarias
WHERE  dia BETWEEN '2025-07-01' AND '2025-09-30'
GROUP  BY pais, plan ORDER BY compras DESC;
-- De ~1M filas a unos pocos miles. Para refrescar sin bloquear lecturas:
-- REFRESH MATERIALIZED VIEW CONCURRENTLY mv_compras_diarias;

-- ---------------------------------------------------------------
-- PASO 6 · Anti-patrones que conviene nombrar en la entrevista
-- ---------------------------------------------------------------
-- (1) Subquery correlacionada en SELECT -> JOIN o window function
--     SELECT e.*, (SELECT pais FROM usuarios WHERE id_usuario = e.id_usuario) ...
-- (2) DISTINCT para "arreglar" duplicados de un JOIN mal hecho
-- (3) OR entre columnas distintas -> UNION ALL de dos consultas indexables
-- (4) NOT IN con subquery que puede devolver NULL -> NOT EXISTS
-- (5) SELECT * sobre tablas anchas con jsonb/text -> I/O innecesario
-- (6) Funciones sobre columnas indexadas: DATE(col), LOWER(col), col + 1
-- (7) Falta de ANALYZE tras cargas masivas (estimaciones absurdas)
-- (8) Un solo UPDATE/DELETE de 50M filas -> lotes (ver ejercicio 04)

-- Comparar NOT IN vs NOT EXISTS (usuarios sin compras)
EXPLAIN (ANALYZE)
SELECT COUNT(*) FROM usuarios u
WHERE NOT EXISTS (SELECT 1 FROM eventos e WHERE e.id_usuario = u.id_usuario AND e.tipo_evento = 'purchase');

-- ---------------------------------------------------------------
-- CHULETA de lectura de EXPLAIN ANALYZE
--   Seq Scan            lee toda la tabla; OK si devuelve > ~10 % de filas
--   Index Scan          índice + heap; bueno para pocas filas
--   Index Only Scan     solo índice (necesita INCLUDE/visibility map)
--   Bitmap Heap Scan    término medio; muchas filas dispersas
--   Nested Loop         bueno si el lado externo es pequeño
--   Hash Join           bueno para joins grandes sin orden
--   Merge Join          ambos lados ordenados
--   Sort + external     work_mem insuficiente ("Disk: ..." en el plan)
--   rows= vs actual     estimaciones malas -> ANALYZE / estadísticas extendidas
-- ---------------------------------------------------------------
