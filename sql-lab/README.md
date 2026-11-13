# SQL Lab · Las 5 queries de entrevista Data Engineer

Laboratorio práctico, con datos sintéticos, para dominar las 5 preguntas SQL clásicas de
entrevista de Data Engineer. Cada ejercicio trae **el enunciado, la solución, el porqué,
las preguntas de seguimiento típicas y una chuleta**. Hay versión **PostgreSQL** y **SQL Server (T-SQL)**.

| # | Tema | Pregunta de entrevista | Qué evalúan realmente |
|---|------|------------------------|-----------------------|
| 01 | Window functions | Promedio móvil de ventas de los últimos 7 días por región | Que sepas la diferencia entre *7 filas* y *7 días*, frames `ROWS/RANGE`, y que agregues antes de aplicar la ventana |
| 02 | CTE recursiva | Jerarquía completa de un organigrama (id_empleado / id_manager) | Ancla + miembro recursivo, nivel, ruta, y cómo protegerte de ciclos |
| 03 | Optimización | "Esta query tarda 45 minutos, ¿cómo la mejorás?" | El **proceso**: EXPLAIN → predicados sargables → índices → estadísticas → particiones → materialización |
| 04 | Deduplicación | Duplicados en una tabla de 50M de filas, sin perder datos | `ROW_NUMBER() OVER (PARTITION BY ...)` + DELETE, pero **por lotes, con respaldo y con prevención** |
| 05 | Datos faltantes | Un pipeline dejó NULLs hace 3 meses, ¿cómo lo detectás y corregís? | Pensamiento de producción: dimensionar, encontrar la fecha del deploy, backfill desde la fuente de verdad o imputar marcándolo, test de calidad |

## Estructura

```
sql-lab/
├── README.md
├── docker-compose.yml          # PostgreSQL 16 + SQL Server 2022 (Developer)
├── run_postgres.sh             # ejecuta setup + ejercicios en PostgreSQL
├── run_sqlserver.sh            # ejecuta setup + ejercicios en SQL Server
├── postgres/
│   ├── 00_setup.sql            # esquema `lab` con los 5 datasets (parámetro ROWS)
│   ├── 01_window_functions.sql
│   ├── 02_recursive_cte.sql
│   ├── 03_optimizacion.sql
│   ├── 04_deduplicacion.sql
│   └── 05_datos_faltantes.sql
└── sqlserver/                  # mismos 6 archivos en T-SQL
```

### Datasets que crea `00_setup.sql` (esquema `lab`)

| Tabla | Filas (por defecto) | Para qué | Trampa plantada |
|-------|--------------------:|----------|-----------------|
| `ventas` | ~3.900 | 01 | ~10 % de días **sin** ventas por región: `ROWS 6 PRECEDING` ≠ "últimos 7 días" |
| `empleados` | 18 | 02 | 6 niveles; el ejercicio inserta un ciclo (en transacción) para practicar la detección |
| `usuarios`, `eventos` | 50k, 1M | 03 | Sin índices; la query lenta usa `DATE(col)` y `LOWER(col)` en el WHERE |
| `clientes_raw` | 1M | 04 | ~27 % de emails repetidos con distinto `updated_at` y teléfonos nulos |
| `pedidos`, `pedidos_fuente` | 200k | 05 | `canal_venta` NULL en el 97 % de los pedidos entre 2025-07-10 y 2025-10-05; la fuente tiene el dato bueno |

## Cómo montarlo

### Opción A · Docker (recomendada, los dos motores)

```bash
cd sql-lab
docker compose up -d postgres        # y/o: docker compose up -d sqlserver
./run_postgres.sh                    # setup + 5 ejercicios
./run_sqlserver.sh                   # idem en SQL Server (tarda ~1-2 min más por la carga)
```

Conexiones para DBeaver / Azure Data Studio / SSMS / Power BI:

| Motor | Host | Usuario | Password | BD |
|-------|------|---------|----------|----|
| PostgreSQL | `localhost:5432` | `lab` | `lab` | `sql_lab` |
| SQL Server | `localhost,1433` | `sa` | `Lab_Pass_2025!` | `sql_lab` (la crea el setup) |

### Opción B · PostgreSQL ya instalado

```bash
createdb sql_lab
PGURL=postgresql://usuario:pass@localhost/sql_lab ./run_postgres.sh
# o archivo a archivo:
psql -d sql_lab -v ROWS=1000000 -f postgres/00_setup.sql
psql -d sql_lab -f postgres/01_window_functions.sql
```

### Opción C · SQL Server ya instalado (LocalDB, Express, Developer)

Abrí los archivos de `sqlserver/` en SSMS o Azure Data Studio **en orden** y ejecutalos
(activá *Include Actual Execution Plan*, Ctrl+M, para el ejercicio 03). Con `sqlcmd`:

```bash
sqlcmd -S localhost -U sa -P 'TuPass' -I -i sqlserver/00_setup.sql     # -I: QUOTED_IDENTIFIER ON (lo exige la vista indexada)
```

> El particionado del ejercicio 03 requiere edición Developer/Enterprise, o Standard 2016 SP1+.
> En Express/LocalDB ese bloque falla; el resto del ejercicio funciona.

### Escalar el tamaño

`ROWS` controla `eventos` y `clientes_raw` (1M por defecto, ~10 s de carga en PostgreSQL).
Para sentir de verdad el ejercicio de optimización: `ROWS=10000000 ./run_postgres.sh 03`.
En SQL Server cambiá `DECLARE @rows int = 1000000;` en `00_setup.sql` (la tally table llega a 2M; ampliá el `TOP` si necesitás más).

## Cómo estudiarlo

1. **Leé solo el enunciado** (cabecera de cada archivo) e intentá resolverlo en blanco, en voz alta, como en la entrevista.
2. Ejecutá la solución y compará. Leé los comentarios: ahí está lo que el entrevistador quiere oír.
3. Hacé las **preguntas de seguimiento** (P1..P5) sin mirar.
4. Repetí en el otro motor: las diferencias de sintaxis son parte de lo que preguntan.

### Guion de respuesta de 60 segundos (para memorizar)

- **01** "Primero agrego a nivel día-región. Luego `AVG() OVER (PARTITION BY region ORDER BY fecha ROWS BETWEEN 6 PRECEDING AND CURRENT ROW)`. Ojo: si faltan días, eso son 7 *filas*, no 7 *días*; para días de calendario uso `RANGE INTERVAL '6 days'` en Postgres o completo con una tabla calendario."
- **02** "CTE recursiva: ancla = `id_manager IS NULL`, miembro recursivo = join de empleados contra la CTE por `id_manager`. Arrastro nivel y ruta. Con datos reales protejo contra ciclos (array de visitados / `CYCLE` en PG 14 / `MAXRECURSION` en SQL Server)."
- **03** "No adivino: `EXPLAIN ANALYZE`. Busco seq scans sobre tablas grandes, estimaciones erradas y funciones sobre columnas en el WHERE. Reescribo sargable, indexo igualdad-luego-rango con INCLUDE, actualizo estadísticas. Si es una tabla de hechos enorme, particiono por fecha. Si la consulta se repite, la materializo (vista materializada / tabla agregada)."
- **04** "Defino qué es duplicado con negocio. `ROW_NUMBER() OVER (PARTITION BY clave ORDER BY updated_at DESC)` y me quedo con rn = 1. Antes de borrar respaldo los rn > 1. En 50M borro **por lotes** para no bloquear ni llenar el log. Después, índice único y carga idempotente (upsert / MERGE) para que no vuelva a pasar."
- **05** "Dimensiono: % de nulos por día con `COUNT(*) - COUNT(col)`, y con `LAG` encuentro el día exacto del salto, que cruzo con los deploys. Si existe la fuente de verdad, hago backfill desde ahí, por lotes e idempotente, con log de lo que cambié. Si no existe, imputo (LOCF, moda, regla de negocio) **y marco la fila como imputada**. Cierro con un test de calidad que alerte y, si aplica, `NOT NULL`."

## PostgreSQL vs SQL Server: diferencias que aparecen en el lab

| Tema | PostgreSQL | SQL Server |
|------|-----------|------------|
| Series | `generate_series()` | tally table `lab.Numeros` (o `GENERATE_SERIES` desde 2022) |
| Ventana por tiempo | `RANGE BETWEEN INTERVAL '6 days' PRECEDING` | no existe: `CROSS APPLY` o tabla calendario |
| Cláusula `WINDOW w AS (...)` | sí | solo desde 2022 |
| CTE recursiva | `WITH RECURSIVE`, sin límite, arrays, `CYCLE` (14+) | `WITH` a secas, `MAXRECURSION 100` por defecto, ruta como texto |
| Plan de ejecución | `EXPLAIN (ANALYZE, BUFFERS)` | *Actual Execution Plan* + `SET STATISTICS IO, TIME ON` |
| Índice parcial / filtrado | `CREATE INDEX ... WHERE` | `CREATE INDEX ... WHERE` (índice filtrado) |
| Particionado | declarativo, `PARTITION BY RANGE` + tablas hijas | `PARTITION FUNCTION` + `PARTITION SCHEME` |
| Materializar | `MATERIALIZED VIEW` + `REFRESH CONCURRENTLY` | vista indexada (`SCHEMABINDING`, `COUNT_BIG`, `NOEXPAND`) o tabla agregada |
| DELETE de duplicados | `DELETE ... USING cte` por PK/`ctid` | `DELETE FROM cte WHERE rn > 1` directo |
| Borrado por lotes | bucle PL/pgSQL (COMMIT en procedimiento) | `DELETE TOP (n)` en `WHILE` |
| Upsert | `INSERT ... ON CONFLICT DO UPDATE` | `MERGE` (o UPDATE + INSERT con `HOLDLOCK`) |
| LAG ignorando nulos | no: truco COUNT acumulado + MAX | `IGNORE NULLS` desde 2022; antes, el mismo truco |
| Primer valor por grupo | `DISTINCT ON` | `ROW_NUMBER()` |

## Para quien viene de Power BI

Los archivos T-SQL de 01 y 02 incluyen el equivalente DAX (`DATESINPERIOD`, `TOTALYTD`, `RANKX`, `PATH`/`PATHITEM`).
La vista materializada / tabla agregada del ejercicio 03 es exactamente la tabla de hechos agregada que
alimentarías a un modelo en Import; el ejercicio 05 es lo que hoy harías a mano en Power Query y
que en un pipeline debe vivir en SQL con un test de calidad detrás.

## Estado de validación

- **PostgreSQL**: los 6 scripts se ejecutaron completos y en orden sobre PostgreSQL 16.15 con `ROWS=1000000`, sin errores (`ON_ERROR_STOP`).
- **SQL Server**: los scripts T-SQL están escritos para 2016 SP1+ y revisados a mano, pero **no se ejecutaron en un motor** al preparar este lab. Si algo falla, lo más probable son los bloques de particionado (edición) o la vista indexada (`SET QUOTED_IDENTIFIER ON`).
