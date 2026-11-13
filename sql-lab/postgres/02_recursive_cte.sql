-- =====================================================================
--  02 · CTE RECURSIVA
--  Pregunta de entrevista:
--  "Armá la jerarquía completa de un organigrama a partir de una tabla
--   con id_empleado e id_manager."
-- =====================================================================
SET search_path TO lab, public;

-- ---------------------------------------------------------------
-- ANATOMÍA de una CTE recursiva
--   WITH RECURSIVE nombre AS (
--       <miembro ancla>        -- punto de partida (raíces: id_manager IS NULL)
--       UNION ALL
--       <miembro recursivo>    -- se une a `nombre` (el resultado de la iteración anterior)
--   )
--   Se repite hasta que el miembro recursivo devuelve 0 filas.
-- ---------------------------------------------------------------

-- SOLUCIÓN BASE · nivel, ruta y manager directo
WITH RECURSIVE org AS (
    -- Ancla: la raíz del organigrama
    SELECT id_empleado, nombre, cargo, id_manager, salario,
           1                       AS nivel,
           nombre::text            AS ruta,
           ARRAY[id_empleado]      AS ruta_ids
    FROM   empleados
    WHERE  id_manager IS NULL

    UNION ALL

    -- Recursivo: los que reportan a alguien ya alcanzado
    SELECT e.id_empleado, e.nombre, e.cargo, e.id_manager, e.salario,
           o.nivel + 1,
           o.ruta || ' > ' || e.nombre,
           o.ruta_ids || e.id_empleado
    FROM   empleados e
    JOIN   org o ON e.id_manager = o.id_empleado
)
SELECT nivel,
       REPEAT('    ', nivel - 1) || nombre AS organigrama,
       cargo, ruta
FROM   org
ORDER  BY ruta_ids;         -- ordenar por el array de ids da el orden "de árbol"

-- ---------------------------------------------------------------
-- PREGUNTAS DE SEGUIMIENTO
-- ---------------------------------------------------------------

-- P1 · "¿Cuántas personas tiene a cargo (directa o indirectamente) cada manager?"
--      Truco: arrancar desde TODOS los empleados como ancla y propagar el id del
--      ancestro. Cada par (ancestro, descendiente) aparece una vez.
WITH RECURSIVE arbol AS (
    SELECT id_empleado AS id_ancestro, id_empleado AS id_descendiente, 0 AS distancia
    FROM   empleados
    UNION ALL
    SELECT a.id_ancestro, e.id_empleado, a.distancia + 1
    FROM   arbol a
    JOIN   empleados e ON e.id_manager = a.id_descendiente
)
SELECT m.nombre, m.cargo,
       COUNT(*) FILTER (WHERE a.distancia = 1) AS reportes_directos,
       COUNT(*) FILTER (WHERE a.distancia > 0) AS reportes_totales,
       SUM(e.salario) FILTER (WHERE a.distancia > 0) AS masa_salarial_a_cargo
FROM   arbol a
JOIN   empleados m ON m.id_empleado = a.id_ancestro
JOIN   empleados e ON e.id_empleado = a.id_descendiente
GROUP  BY m.id_empleado, m.nombre, m.cargo
HAVING COUNT(*) FILTER (WHERE a.distancia > 0) > 0
ORDER  BY reportes_totales DESC;

-- P2 · "Dame toda la cadena de mando de un empleado (hacia arriba)"
WITH RECURSIVE cadena AS (
    SELECT id_empleado, nombre, cargo, id_manager, 0 AS saltos
    FROM   empleados WHERE id_empleado = 18          -- Hugo Prieto
    UNION ALL
    SELECT m.id_empleado, m.nombre, m.cargo, m.id_manager, c.saltos + 1
    FROM   cadena c
    JOIN   empleados m ON m.id_empleado = c.id_manager
)
SELECT saltos, nombre, cargo FROM cadena ORDER BY saltos;

-- P3 · "¿Cómo evitás un bucle infinito si los datos tienen un ciclo?"
--      Opción A (PG 14+): CYCLE ... SET ... USING ...
--      Opción B (portable): llevar un array de visitados y cortar con `<> ALL`.
BEGIN;
UPDATE empleados SET id_manager = 18 WHERE id_empleado = 1;   -- CEO reporta a un junior: ciclo
WITH RECURSIVE org AS (
    SELECT id_empleado, nombre, id_manager, 1 AS nivel, ARRAY[id_empleado] AS visitados, false AS es_ciclo
    FROM   empleados WHERE id_empleado = 1
    UNION ALL
    SELECT e.id_empleado, e.nombre, e.id_manager, o.nivel + 1,
           o.visitados || e.id_empleado,
           e.id_empleado = ANY(o.visitados)
    FROM   empleados e
    JOIN   org o ON e.id_manager = o.id_empleado
    WHERE  NOT o.es_ciclo                        -- detiene la rama cuando detecta el ciclo
)
SELECT nivel, nombre, es_ciclo FROM org ORDER BY nivel LIMIT 25;
ROLLBACK;   -- deshacemos el ciclo

-- P3-bis · Sintaxis nativa PG 14+ (más corta)
WITH RECURSIVE org AS (
    SELECT id_empleado, nombre, id_manager, 1 AS nivel
    FROM   empleados WHERE id_manager IS NULL
    UNION ALL
    SELECT e.id_empleado, e.nombre, e.id_manager, o.nivel + 1
    FROM   empleados e JOIN org o ON e.id_manager = o.id_empleado
) CYCLE id_empleado SET es_ciclo USING ruta
SELECT nivel, nombre, es_ciclo, ruta FROM org ORDER BY ruta LIMIT 25;

-- P4 · "Profundidad máxima y empleados por nivel"
WITH RECURSIVE org AS (
    SELECT id_empleado, 1 AS nivel FROM empleados WHERE id_manager IS NULL
    UNION ALL
    SELECT e.id_empleado, o.nivel + 1 FROM empleados e JOIN org o ON e.id_manager = o.id_empleado
)
SELECT nivel, COUNT(*) AS empleados FROM org GROUP BY nivel ORDER BY nivel;

-- P5 · "Generá una serie sin generate_series" (para demostrar que entendés la recursión)
WITH RECURSIVE n AS (
    SELECT 1 AS i
    UNION ALL
    SELECT i + 1 FROM n WHERE i < 10
)
SELECT i FROM n;

-- ---------------------------------------------------------------
-- CHULETA
--  · UNION ALL (no UNION): UNION deduplica cada iteración y es más lento;
--    UNION sí sirve como freno natural contra ciclos, pero cuesta.
--  · Hay que proteger contra ciclos en datos reales (ver P3).
--  · PG no tiene límite de recursión por defecto; en SQL Server es 100
--    (OPTION (MAXRECURSION n)).
--  · Alternativa en Power BI: PATH() / PATHITEM() en DAX hacen lo mismo
--    sobre una columna calculada (ejercicio 02 en sqlserver/ tiene el mapeo).
-- ---------------------------------------------------------------
