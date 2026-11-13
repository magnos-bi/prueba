-- =====================================================================
--  04 · DEDUPLICACIÓN
--  Pregunta de entrevista:
--  "Tenés registros duplicados en una tabla de 50M de filas.
--   ¿Cómo los identificás y eliminás sin perder datos?"
--
--  Guion de respuesta:
--    1. DEFINIR qué es duplicado (¿misma PK? ¿mismo email? ¿mismo email+teléfono?)
--    2. MEDIR cuántos hay y cuál se conserva (regla: el más reciente, el más completo...)
--    3. RESPALDAR (tabla de respaldo o copia de los que se van a borrar)
--    4. BORRAR por lotes (en 50M un DELETE único bloquea y llena el WAL/log)
--    5. PREVENIR (índice único / constraint / dedup en la carga: MERGE / ON CONFLICT)
-- =====================================================================
SET search_path TO lab, public;
\timing on

-- ---------------------------------------------------------------
-- PASO 1 y 2 · Identificar. Clave de negocio: email.
-- ---------------------------------------------------------------
-- ¿Cuántos emails tienen más de una fila?
SELECT COUNT(*) AS emails_duplicados, SUM(n) - COUNT(*) AS filas_sobrantes
FROM (SELECT email, COUNT(*) AS n FROM clientes_raw GROUP BY email HAVING COUNT(*) > 1) d;

-- Ver algunos ejemplos completos
SELECT * FROM clientes_raw
WHERE email IN (SELECT email FROM clientes_raw GROUP BY email HAVING COUNT(*) > 1 LIMIT 3)
ORDER BY email, updated_at DESC;

-- ROW_NUMBER: numera dentro de cada email, la más reciente = 1.
--   Criterio de desempate completo: updated_at DESC, luego "más completa"
--   (teléfono no nulo primero), luego id_fila para que sea determinista.
SELECT id_fila, email, nombre, telefono, updated_at, origen,
       ROW_NUMBER() OVER (PARTITION BY email
                          ORDER BY updated_at DESC,
                                   (telefono IS NOT NULL) DESC,
                                   id_fila DESC) AS rn
FROM   clientes_raw
WHERE  email IN (SELECT email FROM clientes_raw GROUP BY email HAVING COUNT(*) > 1 LIMIT 3)
ORDER  BY email, rn;

-- ---------------------------------------------------------------
-- PASO 3 · Respaldar lo que se va a borrar (siempre). Cuesta poco, salva carreras.
-- ---------------------------------------------------------------
DROP TABLE IF EXISTS clientes_raw_dups_backup;
CREATE TABLE clientes_raw_dups_backup AS
SELECT *
FROM (
    SELECT c.*,
           ROW_NUMBER() OVER (PARTITION BY email
                              ORDER BY updated_at DESC, (telefono IS NOT NULL) DESC, id_fila DESC) AS rn
    FROM clientes_raw c
) t
WHERE rn > 1;
SELECT COUNT(*) AS filas_respaldadas FROM clientes_raw_dups_backup;

-- ---------------------------------------------------------------
-- PASO 4 · Borrar.
--   Opción A (la "de libro"): DELETE con CTE + ROW_NUMBER.
--   En PostgreSQL no se puede hacer DELETE directamente sobre una CTE,
--   así que se borra por PK (id_fila) o, si no hay PK, por ctid.
-- ---------------------------------------------------------------
BEGIN;
WITH numerados AS (
    SELECT id_fila,
           ROW_NUMBER() OVER (PARTITION BY email
                              ORDER BY updated_at DESC, (telefono IS NOT NULL) DESC, id_fila DESC) AS rn
    FROM clientes_raw
)
DELETE FROM clientes_raw c
USING  numerados n
WHERE  c.id_fila = n.id_fila
  AND  n.rn > 1;
-- Verificar antes de confirmar
SELECT COUNT(*) AS total, COUNT(DISTINCT email) AS emails_unicos FROM clientes_raw;
ROLLBACK;   -- lo deshacemos para poder probar la opción B

-- Opción A-bis · sin PK: usar ctid (identificador físico de fila en PG)
--   DELETE FROM clientes_raw WHERE ctid IN (SELECT ctid FROM (... ROW_NUMBER ...) t WHERE rn > 1);

-- ---------------------------------------------------------------
--   Opción B (la de "50M de filas"): por LOTES.
--   Un DELETE de millones de filas en una transacción:
--     - bloquea las filas durante minutos/horas
--     - genera WAL enorme (PG) / log de transacciones (SQL Server)
--     - si falla a los 40 min, hace rollback de todo
--   Solución: lotes de 50-100k con commits intermedios, usando la tabla
--   de respaldo (que ya tiene los id_fila a borrar) como "cola".
-- ---------------------------------------------------------------
DO $$
DECLARE
    v_lote     int := 100000;
    v_borradas int;
    v_total    bigint := 0;
BEGIN
  LOOP
    WITH lote AS (
        SELECT b.id_fila
        FROM   clientes_raw_dups_backup b
        JOIN   clientes_raw c USING (id_fila)     -- solo los que todavía existen
        LIMIT  v_lote
    )
    DELETE FROM clientes_raw c USING lote WHERE c.id_fila = lote.id_fila;
    GET DIAGNOSTICS v_borradas = ROW_COUNT;
    v_total := v_total + v_borradas;
    RAISE NOTICE 'lote: % filas borradas (acumulado %)', v_borradas, v_total;
    EXIT WHEN v_borradas = 0;
    -- En un script real: COMMIT aquí (en PG 11+ dentro de un procedimiento, no de un DO)
  END LOOP;
END $$;

SELECT COUNT(*) AS total, COUNT(DISTINCT email) AS emails_unicos FROM clientes_raw;

-- ---------------------------------------------------------------
--   Opción C (cuando los duplicados son > 30-40 % de la tabla):
--   Es más barato RECREAR la tabla con los únicos que borrar.
--     CREATE TABLE clientes_clean AS SELECT DISTINCT ON (email) * FROM clientes_raw
--        ORDER BY email, updated_at DESC, (telefono IS NOT NULL) DESC, id_fila DESC;
--     -- índices, constraints, permisos...
--     ALTER TABLE clientes_raw RENAME TO clientes_raw_old;
--     ALTER TABLE clientes_clean RENAME TO clientes_raw;
--   DISTINCT ON es específico de PostgreSQL; en SQL Server se usa ROW_NUMBER.
-- ---------------------------------------------------------------

-- ---------------------------------------------------------------
-- PASO 5 · Prevenir que vuelva a pasar.
-- ---------------------------------------------------------------
-- (1) Constraint única sobre la clave de negocio
CREATE UNIQUE INDEX IF NOT EXISTS ux_clientes_raw_email ON clientes_raw (email);

-- (2) Carga idempotente: UPSERT. Si llega un email existente, actualiza si es más nuevo.
INSERT INTO clientes_raw (email, nombre, telefono, updated_at, origen)
VALUES ('user00000001@mail.com', 'Cliente actualizado', '+34600000000', now(), 'crm')
ON CONFLICT (email) DO UPDATE
   SET nombre = EXCLUDED.nombre, telefono = EXCLUDED.telefono, updated_at = EXCLUDED.updated_at
 WHERE clientes_raw.updated_at < EXCLUDED.updated_at;      -- solo si es más reciente

-- (3) Dedup en staging ANTES de cargar al destino (patrón ELT): la query del PASO 2
--     con WHERE rn = 1 como fuente del INSERT ... SELECT.

-- ---------------------------------------------------------------
-- PREGUNTAS DE SEGUIMIENTO
-- ---------------------------------------------------------------
-- P1 · "¿Y si duplicado es 'misma persona' pero el email difiere en mayúsculas/espacios?"
--      Normalizar en la PARTITION BY: PARTITION BY LOWER(TRIM(email))
--      y crear el índice único sobre la expresión: CREATE UNIQUE INDEX ... ON t (LOWER(TRIM(email)))
-- P2 · "¿Cómo detectás duplicados EXACTOS (todas las columnas iguales)?"
--      GROUP BY todas las columnas HAVING COUNT(*) > 1, o ROW_NUMBER() PARTITION BY todas.
-- P3 · "¿ROW_NUMBER o DISTINCT?"  DISTINCT no te deja elegir CUÁL conservar. ROW_NUMBER sí.
-- P4 · "¿Qué pasa con las FKs que apuntaban a las filas borradas?"
--      Antes de borrar, re-apuntar hijos al id superviviente (UPDATE hijos SET id = ganador).
