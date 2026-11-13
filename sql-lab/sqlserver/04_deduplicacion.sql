-- =====================================================================
--  04 · DEDUPLICACIÓN (T-SQL)
--  "Tenés registros duplicados en una tabla de 50M de filas.
--   ¿Cómo los identificás y eliminás sin perder datos?"
--  Definir -> medir -> respaldar -> borrar por lotes -> prevenir
-- =====================================================================
USE sql_lab;
GO
-- PASO 1-2 · Identificar
SELECT COUNT(*) AS emails_duplicados, SUM(n) - COUNT(*) AS filas_sobrantes
FROM (SELECT email, COUNT(*) AS n FROM lab.clientes_raw GROUP BY email HAVING COUNT(*) > 1) d;

SELECT TOP (10) id_fila, email, nombre, telefono, updated_at, origen,
       ROW_NUMBER() OVER (PARTITION BY email
                          ORDER BY updated_at DESC,
                                   CASE WHEN telefono IS NOT NULL THEN 0 ELSE 1 END,   -- la más completa
                                   id_fila DESC) AS rn
FROM   lab.clientes_raw
WHERE  email IN (SELECT TOP (3) email FROM lab.clientes_raw GROUP BY email HAVING COUNT(*) > 1 ORDER BY email)
ORDER  BY email, rn;

-- PASO 3 · Respaldo de lo que se borra
DROP TABLE IF EXISTS lab.clientes_raw_dups_backup;
SELECT * INTO lab.clientes_raw_dups_backup
FROM (SELECT c.*, ROW_NUMBER() OVER (PARTITION BY email ORDER BY updated_at DESC,
                   CASE WHEN telefono IS NOT NULL THEN 0 ELSE 1 END, id_fila DESC) AS rn
      FROM lab.clientes_raw c) t
WHERE rn > 1;
SELECT COUNT(*) AS filas_respaldadas FROM lab.clientes_raw_dups_backup;
GO

-- PASO 4 · Opción A: DELETE directo sobre la CTE (SQL Server SÍ lo permite; PostgreSQL no)
BEGIN TRAN;
;WITH numerados AS (
    SELECT ROW_NUMBER() OVER (PARTITION BY email ORDER BY updated_at DESC,
               CASE WHEN telefono IS NOT NULL THEN 0 ELSE 1 END, id_fila DESC) AS rn
    FROM lab.clientes_raw
)
DELETE FROM numerados WHERE rn > 1;
SELECT COUNT(*) AS total, COUNT(DISTINCT email) AS emails_unicos FROM lab.clientes_raw;
ROLLBACK TRAN;      -- deshacemos para probar la opción B
GO

-- PASO 4 · Opción B: por LOTES (la respuesta para 50M). Evita bloquear la tabla y
--   que el log de transacciones crezca sin control (sobre todo en FULL recovery).
DECLARE @lote int = 100000, @n int = 1, @total bigint = 0;
WHILE @n > 0
BEGIN
    DELETE TOP (@lote) c
    FROM   lab.clientes_raw c
    JOIN   lab.clientes_raw_dups_backup b ON b.id_fila = c.id_fila;
    SET @n = @@ROWCOUNT;
    SET @total += @n;
    RAISERROR('lote: %d filas borradas (acumulado %I64d)', 0, 1, @n, @total) WITH NOWAIT;
    -- En producción: CHECKPOINT / BACKUP LOG entre lotes si el log crece; WAITFOR DELAY '00:00:00.5' para dar aire al OLTP
END
SELECT COUNT(*) AS total, COUNT(DISTINCT email) AS emails_unicos FROM lab.clientes_raw;
GO

-- Opción C · Si los duplicados son > 30-40 %: recrear es más barato que borrar
--   SELECT * INTO lab.clientes_clean FROM (... ROW_NUMBER ...) t WHERE rn = 1;
--   -- índices, FKs, permisos; luego sp_rename / ALTER TABLE ... SWITCH si está particionada

-- PASO 5 · Prevenir
CREATE UNIQUE INDEX ux_clientes_raw_email ON lab.clientes_raw (email);
GO
-- Carga idempotente con MERGE (upsert): actualiza solo si llega algo más nuevo
MERGE lab.clientes_raw AS tgt
USING (VALUES ('user00000001@mail.com', N'Cliente actualizado', '+34600000000', SYSDATETIME(), 'crm'))
      AS src (email, nombre, telefono, updated_at, origen)
   ON tgt.email = src.email
WHEN MATCHED AND tgt.updated_at < src.updated_at THEN
     UPDATE SET nombre = src.nombre, telefono = src.telefono, updated_at = src.updated_at
WHEN NOT MATCHED THEN
     INSERT (email, nombre, telefono, updated_at, origen) VALUES (src.email, src.nombre, src.telefono, src.updated_at, src.origen);
-- Nota: MERGE tiene bugs históricos conocidos; muchos equipos prefieren UPDATE + INSERT ... WHERE NOT EXISTS con HOLDLOCK.
GO

-- Seguimiento:
--  P1 · duplicado "lógico" (mayúsculas/espacios): PARTITION BY LOWER(LTRIM(RTRIM(email))) + columna calculada persistida indexada
--  P2 · duplicados exactos: GROUP BY todas las columnas HAVING COUNT(*) > 1
--  P3 · ROW_NUMBER vs DISTINCT: DISTINCT no elige CUÁL conservar
--  P4 · FKs hijas: re-apuntar al id ganador antes del DELETE
