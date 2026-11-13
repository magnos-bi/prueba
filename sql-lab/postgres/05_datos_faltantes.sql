-- =====================================================================
--  05 · DATOS FALTANTES / BACKFILL
--  Pregunta de entrevista:
--  "Un pipeline dejó NULLs en una columna crítica hace 3 meses.
--   ¿Cómo lo detectás y corregís?"
--
--  Evalúan pensamiento de producción. Guion:
--    1. DIMENSIONAR: ¿desde cuándo? ¿cuántas filas? ¿qué % por día? ¿solo esa columna?
--    2. CAUSA RAÍZ: ¿cambió el origen? ¿un JOIN que pasó a LEFT? ¿un deploy? (correlacionar fecha)
--    3. FUENTE DE VERDAD: ¿existe el dato en otro lado (origen, log, staging)? -> backfill real
--       ¿No existe? -> imputar (LOCF, moda, regla de negocio) y MARCARLO como imputado
--    4. EJECUTAR: en lotes, idempotente, con respaldo, verificable
--    5. PREVENIR: test de calidad (NOT NULL %, freshness) que alerte antes que el usuario
-- =====================================================================
SET search_path TO lab, public;
\timing on

-- ---------------------------------------------------------------
-- PASO 1 · Dimensionar el problema
-- ---------------------------------------------------------------
-- Perfil de nulos de toda la tabla (una pasada)
SELECT COUNT(*)                                             AS filas,
       COUNT(*) - COUNT(canal_venta)                        AS nulos_canal,
       ROUND(100.0 * (COUNT(*) - COUNT(canal_venta)) / COUNT(*), 2) AS pct_nulos_canal,
       COUNT(*) - COUNT(id_cliente)                         AS nulos_cliente,
       COUNT(*) - COUNT(importe)                            AS nulos_importe
FROM   pedidos;

-- % de nulos por semana: ¿desde cuándo y hasta cuándo?
SELECT date_trunc('week', fecha_pedido)::date AS semana,
       COUNT(*) AS pedidos,
       COUNT(*) FILTER (WHERE canal_venta IS NULL) AS nulos,
       ROUND(100.0 * COUNT(*) FILTER (WHERE canal_venta IS NULL) / COUNT(*), 1) AS pct_nulos
FROM   pedidos
GROUP  BY 1 ORDER BY 1;

-- Fecha exacta de inicio y fin del problema (primer y último día con > 50 % nulos)
WITH diario AS (
    SELECT fecha_pedido,
           100.0 * COUNT(*) FILTER (WHERE canal_venta IS NULL) / COUNT(*) AS pct_nulos
    FROM pedidos GROUP BY fecha_pedido
)
SELECT MIN(fecha_pedido) AS inicio_incidente, MAX(fecha_pedido) AS fin_incidente,
       COUNT(*) AS dias_afectados
FROM   diario WHERE pct_nulos > 50;

-- Detectar el "salto": día en que el % de nulos cambia bruscamente vs el día anterior (LAG)
WITH diario AS (
    SELECT fecha_pedido,
           100.0 * COUNT(*) FILTER (WHERE canal_venta IS NULL) / COUNT(*) AS pct_nulos
    FROM pedidos GROUP BY fecha_pedido
), con_lag AS (
    SELECT fecha_pedido, pct_nulos,
           pct_nulos - LAG(pct_nulos) OVER (ORDER BY fecha_pedido) AS salto
    FROM diario
)
SELECT fecha_pedido, ROUND(pct_nulos,1) AS pct_nulos, ROUND(salto,1) AS salto
FROM   con_lag WHERE ABS(salto) > 40 ORDER BY fecha_pedido;
-- => Esto te dice la fecha del deploy que lo rompió. Cruzalo con el changelog del pipeline.

-- ¿Afecta a todos los clientes/importes por igual o a un segmento? (pista de la causa)
SELECT canal_venta IS NULL AS es_nulo, COUNT(*), ROUND(AVG(importe),2) AS importe_medio
FROM   pedidos WHERE fecha_pedido BETWEEN '2025-07-10' AND '2025-10-05'
GROUP  BY 1;

-- Huecos en la serie (días sin NINGÚN pedido): otra forma de "dato faltante"
WITH cal AS (
    SELECT d::date AS dia FROM generate_series(date '2025-01-01', date '2025-11-30', interval '1 day') d
)
SELECT c.dia FROM cal c LEFT JOIN pedidos p ON p.fecha_pedido = c.dia
WHERE p.id_pedido IS NULL LIMIT 10;

-- ---------------------------------------------------------------
-- PASO 2 · ESTRATEGIA A: Backfill desde la fuente de verdad (la buena)
--   Existe pedidos_fuente con el dato correcto. Siempre preferir esto.
-- ---------------------------------------------------------------
-- 2.1 Respaldo de lo que vamos a tocar
DROP TABLE IF EXISTS pedidos_backfill_log;
CREATE TABLE pedidos_backfill_log AS
SELECT p.id_pedido, p.canal_venta AS valor_anterior, f.canal_venta AS valor_nuevo,
       'fuente'::text AS metodo, now() AS ejecutado_en
FROM   pedidos p JOIN pedidos_fuente f USING (id_pedido)
WHERE  p.canal_venta IS NULL AND f.canal_venta IS NOT NULL;
SELECT COUNT(*) AS a_corregir FROM pedidos_backfill_log;

-- 2.2 Dry-run: ¿cuántas filas coinciden? ¿hay nulos SIN fuente?
SELECT COUNT(*) FILTER (WHERE f.canal_venta IS NOT NULL) AS con_fuente,
       COUNT(*) FILTER (WHERE f.id_pedido IS NULL)       AS sin_fuente
FROM   pedidos p LEFT JOIN pedidos_fuente f USING (id_pedido)
WHERE  p.canal_venta IS NULL;

-- 2.3 UPDATE idempotente y por lotes (se puede relanzar: solo toca lo que sigue NULL)
DO $$
DECLARE v_n int; v_total bigint := 0;
BEGIN
  LOOP
    WITH lote AS (
        SELECT p.id_pedido, f.canal_venta
        FROM   pedidos p JOIN pedidos_fuente f USING (id_pedido)
        WHERE  p.canal_venta IS NULL AND f.canal_venta IS NOT NULL
        LIMIT  20000
    )
    UPDATE pedidos p SET canal_venta = lote.canal_venta
    FROM   lote WHERE p.id_pedido = lote.id_pedido;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_total := v_total + v_n;
    RAISE NOTICE 'lote % (acumulado %)', v_n, v_total;
    EXIT WHEN v_n = 0;
  END LOOP;
END $$;

-- 2.4 Verificar
SELECT COUNT(*) FILTER (WHERE canal_venta IS NULL) AS nulos_restantes FROM pedidos;
-- Y comparar distribución del período corregido vs un período sano
SELECT CASE WHEN fecha_pedido BETWEEN '2025-07-10' AND '2025-10-05' THEN 'corregido' ELSE 'sano' END AS periodo,
       canal_venta, ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY
         CASE WHEN fecha_pedido BETWEEN '2025-07-10' AND '2025-10-05' THEN 'corregido' ELSE 'sano' END), 1) AS pct
FROM   pedidos GROUP BY 1, 2 ORDER BY 1, 2;

-- ---------------------------------------------------------------
-- PASO 3 · ESTRATEGIA B: NO hay fuente -> imputar. Volvemos a romper los
--   datos para practicar (copia de trabajo, no toca pedidos).
-- ---------------------------------------------------------------
DROP TABLE IF EXISTS pedidos_imput;
CREATE TABLE pedidos_imput AS
SELECT id_pedido, fecha_pedido, id_cliente, importe,
       CASE WHEN fecha_pedido BETWEEN '2025-07-10' AND '2025-10-05' AND random() < 0.97
            THEN NULL ELSE canal_venta END AS canal_venta,
       NULL::text AS canal_imputado_por       -- SIEMPRE marcar qué filas son imputadas
FROM   pedidos;

-- B1 · LOCF (last observation carried forward) por cliente: el último canal conocido del cliente.
--   Truco en SQL estándar: las window functions no tienen "LAG ignorando nulos" en PG
--   (SQL Server tampoco hasta 2022 ...IGNORE NULLS). Se simula con dos pasos:
--   (1) contar los no-nulos acumulados para crear un "grupo", (2) tomar el MAX del grupo.
WITH grupos AS (
    SELECT id_pedido, id_cliente, fecha_pedido, canal_venta,
           COUNT(canal_venta) OVER (PARTITION BY id_cliente ORDER BY fecha_pedido, id_pedido
                                    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS grp
    FROM pedidos_imput
), relleno AS (
    SELECT id_pedido,
           MAX(canal_venta) OVER (PARTITION BY id_cliente, grp) AS canal_locf
    FROM grupos
)
UPDATE pedidos_imput p
SET    canal_venta = r.canal_locf, canal_imputado_por = 'locf_cliente'
FROM   relleno r
WHERE  p.id_pedido = r.id_pedido AND p.canal_venta IS NULL AND r.canal_locf IS NOT NULL;

-- B2 · Lo que queda sin historial del cliente: moda (valor más frecuente) del mes sano más cercano.
WITH moda AS (
    SELECT canal_venta
    FROM   pedidos_imput
    WHERE  canal_venta IS NOT NULL AND canal_imputado_por IS NULL
    GROUP  BY canal_venta ORDER BY COUNT(*) DESC LIMIT 1
)
UPDATE pedidos_imput p
SET    canal_venta = m.canal_venta, canal_imputado_por = 'moda_global'
FROM   moda m
WHERE  p.canal_venta IS NULL;

-- B3 · Alternativa honesta: NO inventar. Poner 'desconocido' y que el informe lo muestre.
--   UPDATE pedidos_imput SET canal_venta = 'desconocido', canal_imputado_por = 'sin_dato' WHERE canal_venta IS NULL;

SELECT canal_imputado_por, COUNT(*) FROM pedidos_imput GROUP BY 1 ORDER BY 2 DESC;

-- B4 · Para series numéricas (p. ej. importe NULL): interpolación lineal entre vecinos
--   usa LAG/LEAD del valor y de la fecha y pondera por distancia. Ejemplo en el README.

-- ---------------------------------------------------------------
-- PASO 4 · PREVENIR: test de calidad que corre tras cada carga
--   (en dbt sería `not_null` + `accepted_values`; aquí a mano)
-- ---------------------------------------------------------------
CREATE OR REPLACE VIEW v_dq_pedidos AS
SELECT fecha_pedido,
       COUNT(*)                                                        AS filas,
       ROUND(100.0 * COUNT(*) FILTER (WHERE canal_venta IS NULL) / COUNT(*), 2) AS pct_nulos_canal,
       COUNT(*) FILTER (WHERE canal_venta NOT IN ('web','tienda','telefono','app')) AS valores_invalidos,
       CASE WHEN 100.0 * COUNT(*) FILTER (WHERE canal_venta IS NULL) / COUNT(*) > 1 THEN 'ALERTA' ELSE 'OK' END AS estado
FROM   pedidos
WHERE  fecha_pedido >= CURRENT_DATE - 400          -- en producción: últimos 7 días
GROUP  BY fecha_pedido;

SELECT estado, COUNT(*) AS dias FROM v_dq_pedidos GROUP BY estado;

-- Y la regla definitiva: si el negocio dice que no puede ser NULL, que la BD lo imponga.
-- ALTER TABLE pedidos ALTER COLUMN canal_venta SET NOT NULL;   -- (falla si quedan nulos: eso es bueno)

-- ---------------------------------------------------------------
-- CHULETA
--  COUNT(col) ignora nulos; COUNT(*) no  -> COUNT(*) - COUNT(col) = nulos
--  COALESCE(a, b, c)  primer no nulo      NULLIF(a, b)  NULL si a = b (evita división por 0)
--  NULL = NULL es NULL (no TRUE)          -> usar IS NULL / IS DISTINCT FROM
--  AVG() ignora nulos: AVG(x) ≠ SUM(x)/COUNT(*) si hay nulos
--  NOT IN (subquery con NULL) devuelve vacío -> NOT EXISTS
-- ---------------------------------------------------------------
