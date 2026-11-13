-- =====================================================================
--  02 · CTE RECURSIVA (T-SQL)
--  "Armá la jerarquía completa de un organigrama a partir de una tabla
--   con id_empleado e id_manager."
--  Diferencias con PostgreSQL: no se escribe RECURSIVE, el límite por
--  defecto es 100 niveles (OPTION (MAXRECURSION n)), no hay arrays
--  (se usa una ruta en texto o hierarchyid).
-- =====================================================================
USE sql_lab;
GO
-- SOLUCIÓN BASE
;WITH org AS (
    SELECT id_empleado, nombre, cargo, id_manager, salario,
           1 AS nivel,
           CAST(nombre AS nvarchar(500))                      AS ruta,
           CAST(RIGHT('0000' + CAST(id_empleado AS varchar(4)), 4) AS varchar(200)) AS ruta_orden
    FROM   lab.empleados WHERE id_manager IS NULL
    UNION ALL
    SELECT e.id_empleado, e.nombre, e.cargo, e.id_manager, e.salario,
           o.nivel + 1,
           CAST(o.ruta + N' > ' + e.nombre AS nvarchar(500)),
           CAST(o.ruta_orden + '.' + RIGHT('0000' + CAST(e.id_empleado AS varchar(4)), 4) AS varchar(200))
    FROM   lab.empleados e JOIN org o ON e.id_manager = o.id_empleado
)
SELECT nivel, REPLICATE('    ', nivel - 1) + nombre AS organigrama, cargo, ruta
FROM   org ORDER BY ruta_orden
OPTION (MAXRECURSION 50);
-- ¡Los tipos del ancla y del miembro recursivo deben coincidir EXACTAMENTE (de ahí los CAST)!

-- P1 · Reportes directos / totales / masa salarial por manager
;WITH arbol AS (
    SELECT id_empleado AS id_ancestro, id_empleado AS id_descendiente, 0 AS distancia FROM lab.empleados
    UNION ALL
    SELECT a.id_ancestro, e.id_empleado, a.distancia + 1
    FROM   arbol a JOIN lab.empleados e ON e.id_manager = a.id_descendiente
)
SELECT m.nombre, m.cargo,
       SUM(CASE WHEN a.distancia = 1 THEN 1 ELSE 0 END) AS reportes_directos,
       SUM(CASE WHEN a.distancia > 0 THEN 1 ELSE 0 END) AS reportes_totales,
       SUM(CASE WHEN a.distancia > 0 THEN e.salario END) AS masa_salarial_a_cargo
FROM   arbol a
JOIN   lab.empleados m ON m.id_empleado = a.id_ancestro
JOIN   lab.empleados e ON e.id_empleado = a.id_descendiente
GROUP  BY m.id_empleado, m.nombre, m.cargo
HAVING SUM(CASE WHEN a.distancia > 0 THEN 1 ELSE 0 END) > 0
ORDER  BY reportes_totales DESC;

-- P2 · Cadena de mando hacia arriba
;WITH cadena AS (
    SELECT id_empleado, nombre, cargo, id_manager, 0 AS saltos FROM lab.empleados WHERE id_empleado = 18
    UNION ALL
    SELECT m.id_empleado, m.nombre, m.cargo, m.id_manager, c.saltos + 1
    FROM   cadena c JOIN lab.empleados m ON m.id_empleado = c.id_manager
)
SELECT saltos, nombre, cargo FROM cadena ORDER BY saltos;

-- P3 · Protección contra ciclos: ruta de ids como texto + CHARINDEX
BEGIN TRAN;
UPDATE lab.empleados SET id_manager = 18 WHERE id_empleado = 1;    -- ciclo artificial
;WITH org AS (
    SELECT id_empleado, nombre, id_manager, 1 AS nivel,
           CAST('|' + CAST(id_empleado AS varchar(10)) + '|' AS varchar(400)) AS visitados,
           CAST(0 AS bit) AS es_ciclo
    FROM   lab.empleados WHERE id_empleado = 1
    UNION ALL
    SELECT e.id_empleado, e.nombre, e.id_manager, o.nivel + 1,
           CAST(o.visitados + CAST(e.id_empleado AS varchar(10)) + '|' AS varchar(400)),
           CAST(CASE WHEN CHARINDEX('|' + CAST(e.id_empleado AS varchar(10)) + '|', o.visitados) > 0 THEN 1 ELSE 0 END AS bit)
    FROM   lab.empleados e JOIN org o ON e.id_manager = o.id_empleado
    WHERE  o.es_ciclo = 0
)
SELECT nivel, nombre, es_ciclo FROM org ORDER BY nivel
OPTION (MAXRECURSION 100);
ROLLBACK TRAN;
-- Sin la protección, con MAXRECURSION 100 el motor aborta con error 530 (eso también vale como respuesta).

-- P4 · Empleados por nivel
;WITH org AS (
    SELECT id_empleado, 1 AS nivel FROM lab.empleados WHERE id_manager IS NULL
    UNION ALL
    SELECT e.id_empleado, o.nivel + 1 FROM lab.empleados e JOIN org o ON e.id_manager = o.id_empleado
)
SELECT nivel, COUNT(*) AS empleados FROM org GROUP BY nivel ORDER BY nivel;

-- P5 · Serie de números con recursión (y por qué NO usarla para millones de filas:
--      la recursión en SQL Server es fila a fila; una tally table es órdenes de magnitud más rápida)
;WITH n AS (SELECT 1 AS i UNION ALL SELECT i + 1 FROM n WHERE i < 10)
SELECT i FROM n;

-- Equivalente DAX (columnas calculadas en Power BI):
--   Ruta      = PATH(Empleados[id_empleado], Empleados[id_manager])
--   Nivel     = PATHLENGTH([Ruta])
--   Nivel1    = LOOKUPVALUE(Empleados[nombre], Empleados[id_empleado], PATHITEM([Ruta], 1, INTEGER))
