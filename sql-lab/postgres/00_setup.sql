-- =====================================================================
--  SQL LAB · 00_setup.sql  (PostgreSQL 13+)
--  Crea el esquema `lab` con 4 datasets sintéticos, uno por ejercicio:
--    ventas          -> 01 window functions
--    empleados       -> 02 CTE recursiva
--    eventos         -> 03 optimización (tabla grande)
--    clientes_raw    -> 04 deduplicación
--    pedidos         -> 05 datos faltantes / backfill
--  Ejecutar:  psql -d sql_lab -v ROWS=1000000 -f 00_setup.sql
--  (ROWS controla el tamaño de las tablas grandes; por defecto 1M)
-- =====================================================================

\set ON_ERROR_STOP on
\timing on

-- Parámetro de tamaño (psql): si no se pasó -v ROWS, usar 1.000.000
\if :{?ROWS}
\else
  \set ROWS 1000000
\endif

DROP SCHEMA IF EXISTS lab CASCADE;
CREATE SCHEMA lab;
SET search_path TO lab, public;

-- Datos reproducibles
SELECT setseed(0.42);

-- ---------------------------------------------------------------
-- 1) VENTAS: 4 regiones x 365 días, varias ventas por día.
--    Se eliminan algunos días al azar para que "últimos 7 días"
--    NO sea lo mismo que "últimas 7 filas" (trampa clásica).
-- ---------------------------------------------------------------
CREATE TABLE ventas (
    id_venta   bigserial PRIMARY KEY,
    fecha      date        NOT NULL,
    region     text        NOT NULL,
    vendedor   text        NOT NULL,
    monto      numeric(12,2) NOT NULL
);

INSERT INTO ventas (fecha, region, vendedor, monto)
WITH dias_region AS (                               -- ~10 % de días SIN ventas por región
    SELECT d::date AS fecha, r.region
    FROM generate_series(date '2025-01-01', date '2025-12-31', interval '1 day') AS d
    CROSS JOIN (VALUES ('Norte'),('Sur'),('Este'),('Oeste')) AS r(region)
    WHERE random() > 0.10
)
SELECT fecha, region,
       'vend_' || (1 + (random()*9)::int),
       round((50 + random()*950 + (CASE region WHEN 'Norte' THEN 200 ELSE 0 END))::numeric, 2)
FROM dias_region
CROSS JOIN generate_series(1, 3) AS n;             -- 3 ventas por día y región

CREATE INDEX ix_ventas_region_fecha ON ventas (region, fecha);

-- ---------------------------------------------------------------
-- 2) EMPLEADOS: organigrama de 5 niveles.
-- ---------------------------------------------------------------
CREATE TABLE empleados (
    id_empleado int  PRIMARY KEY,
    nombre      text NOT NULL,
    cargo       text NOT NULL,
    id_manager  int  REFERENCES empleados(id_empleado),
    salario     numeric(10,2) NOT NULL
);

INSERT INTO empleados VALUES
 (1 ,'Ana García'     ,'CEO'               ,NULL,25000),
 (2 ,'Luis Pérez'     ,'CTO'               ,1   ,18000),
 (3 ,'Marta Ruiz'     ,'CFO'               ,1   ,18000),
 (4 ,'Pedro Sánchez'  ,'VP Ingeniería'     ,2   ,14000),
 (5 ,'Elena Torres'   ,'VP Datos'          ,2   ,14000),
 (6 ,'Jorge Molina'   ,'Controller'        ,3   ,11000),
 (7 ,'Sofía Castro'   ,'Eng Manager'       ,4   ,10000),
 (8 ,'Diego Romero'   ,'Eng Manager'       ,4   ,10000),
 (9 ,'Lucía Navarro'  ,'Data Manager'      ,5   ,10000),
 (10,'Carlos Vega'    ,'Senior Developer'  ,7   , 7000),
 (11,'Paula Ortiz'    ,'Developer'         ,7   , 5500),
 (12,'Raúl Gil'       ,'Developer'         ,8   , 5500),
 (13,'Nuria Blanco'   ,'Data Engineer'     ,9   , 7000),
 (14,'Iván Serrano'   ,'Data Analyst'      ,9   , 5000),
 (15,'Clara Domínguez','BI Developer'      ,9   , 5500),
 (16,'Óscar Marín'    ,'Contador'          ,6   , 4500),
 (17,'Teresa Campos'  ,'Junior Developer'  ,10  , 3500),
 (18,'Hugo Prieto'    ,'Junior Data Eng'   ,13  , 3500);

-- ---------------------------------------------------------------
-- 3) EVENTOS: tabla grande para el ejercicio de optimización.
--    Sin índices a propósito (salvo la PK).
-- ---------------------------------------------------------------
CREATE TABLE usuarios (
    id_usuario int PRIMARY KEY,
    pais       text NOT NULL,
    plan       text NOT NULL
);
INSERT INTO usuarios
SELECT g,
       (ARRAY['ES','MX','AR','CO','CL','PE'])[1 + floor(random()*5.999)::int],
       (ARRAY['free','pro','enterprise'])[1 + floor(random()*2.999)::int]
FROM generate_series(1, 50000) g;

CREATE TABLE eventos (
    id_evento   bigserial PRIMARY KEY,
    id_usuario  int         NOT NULL,
    tipo_evento text        NOT NULL,
    created_at  timestamptz NOT NULL,
    payload     jsonb
);
INSERT INTO eventos (id_usuario, tipo_evento, created_at, payload)
SELECT 1 + (random()*49999)::int,
       (ARRAY['login','view','click','purchase','logout'])[1 + floor(random()*4.999)::int],
       timestamptz '2025-01-01' + random() * (timestamptz '2025-12-31' - timestamptz '2025-01-01'),
       jsonb_build_object('v', (random()*100)::int)
FROM generate_series(1, :ROWS);

-- ---------------------------------------------------------------
-- 4) CLIENTES_RAW: ~10 % de emails duplicados con distinto updated_at.
-- ---------------------------------------------------------------
CREATE TABLE clientes_raw (
    id_fila    bigserial PRIMARY KEY,
    email      text        NOT NULL,
    nombre     text,
    telefono   text,
    updated_at timestamptz NOT NULL,
    origen     text        NOT NULL
);
INSERT INTO clientes_raw (email, nombre, telefono, updated_at, origen)
SELECT 'user' || LPAD((1 + (random() * (:ROWS * 0.9))::int)::text, 8, '0') || '@mail.com',
       'Cliente ' || g,
       CASE WHEN random() < 0.1 THEN NULL ELSE '+34' || (600000000 + (random()*99999999)::int) END,
       timestamptz '2024-01-01' + random() * interval '600 days',
       (ARRAY['crm','web','import'])[1 + floor(random()*2.999)::int]
FROM generate_series(1, :ROWS) g;

-- ---------------------------------------------------------------
-- 5) PEDIDOS: pipeline que "rompió" y dejó NULL en canal_venta
--    entre 2025-07-10 y 2025-10-05. Existe una tabla fuente
--    (pedidos_fuente) con el dato correcto para hacer backfill.
-- ---------------------------------------------------------------
CREATE TABLE pedidos_fuente (
    id_pedido    int PRIMARY KEY,
    fecha_pedido date NOT NULL,
    id_cliente   int  NOT NULL,
    canal_venta  text NOT NULL,
    importe      numeric(12,2) NOT NULL
);
INSERT INTO pedidos_fuente
SELECT g,
       date '2025-01-01' + (random()*330)::int,
       1 + (random()*9999)::int,
       (ARRAY['web','tienda','telefono','app'])[1 + floor(random()*3.999)::int],
       round((10 + random()*490)::numeric, 2)
FROM generate_series(1, 200000) g;

CREATE TABLE pedidos AS
SELECT id_pedido, fecha_pedido, id_cliente,
       CASE WHEN fecha_pedido BETWEEN date '2025-07-10' AND date '2025-10-05'
                 AND random() < 0.97            -- el 97 % de ese período quedó NULL
            THEN NULL ELSE canal_venta END AS canal_venta,
       importe
FROM pedidos_fuente;
ALTER TABLE pedidos ADD PRIMARY KEY (id_pedido);

-- ---------------------------------------------------------------
ANALYZE;
SELECT 'ventas' t, count(*) FROM ventas
UNION ALL SELECT 'empleados', count(*) FROM empleados
UNION ALL SELECT 'eventos', count(*) FROM eventos
UNION ALL SELECT 'clientes_raw', count(*) FROM clientes_raw
UNION ALL SELECT 'pedidos', count(*) FROM pedidos;
