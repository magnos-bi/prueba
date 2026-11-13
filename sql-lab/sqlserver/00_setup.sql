-- =====================================================================
--  SQL LAB · 00_setup.sql  (SQL Server 2016+ ; probado mentalmente para 2019/2022)
--  Crea la BD sql_lab y el esquema `lab` con los mismos datasets que la
--  versión PostgreSQL:
--    ventas, empleados, usuarios/eventos, clientes_raw, pedidos(_fuente)
--  Ejecutar con SSMS / Azure Data Studio / sqlcmd:
--    sqlcmd -S localhost -U sa -P 'TuPassword!' -i 00_setup.sql
--  Cambiá @rows para escalar las tablas grandes (por defecto 1.000.000).
-- =====================================================================
SET NOCOUNT ON;
GO
IF DB_ID('sql_lab') IS NULL CREATE DATABASE sql_lab;
GO
USE sql_lab;
GO
SET QUOTED_IDENTIFIER ON; SET ANSI_NULLS ON;   -- obligatorio para vistas indexadas (sqlcmd las deja OFF: usar también -I)
GO
-- Limpieza para que el lab sea re-ejecutable (orden importa: vistas -> FKs -> tablas -> particiones)
IF SCHEMA_ID('lab') IS NOT NULL
BEGIN
    DECLARE @sql nvarchar(max) = N'';
    SELECT @sql += N'DROP VIEW IF EXISTS lab.' + QUOTENAME(name) + N';'
    FROM   sys.views WHERE schema_id = SCHEMA_ID('lab');
    SELECT @sql += N'ALTER TABLE lab.' + QUOTENAME(OBJECT_NAME(parent_object_id)) + N' DROP CONSTRAINT ' + QUOTENAME(name) + N';'
    FROM   sys.foreign_keys WHERE schema_id = SCHEMA_ID('lab');
    SELECT @sql += N'DROP TABLE IF EXISTS lab.' + QUOTENAME(name) + N';'
    FROM   sys.tables WHERE schema_id = SCHEMA_ID('lab');
    EXEC sp_executesql @sql;
    DROP SCHEMA lab;
END
IF EXISTS (SELECT 1 FROM sys.partition_schemes   WHERE name = 'ps_mes') DROP PARTITION SCHEME ps_mes;
IF EXISTS (SELECT 1 FROM sys.partition_functions WHERE name = 'pf_mes') DROP PARTITION FUNCTION pf_mes;
GO
CREATE SCHEMA lab;
GO

-- ---------------------------------------------------------------
-- 0) Tabla de números (tally). SQL Server no tiene generate_series
--    hasta la versión 2022; una tally table funciona en todas.
-- ---------------------------------------------------------------
CREATE TABLE lab.Numeros (n int NOT NULL PRIMARY KEY CLUSTERED);
;WITH L0 AS (SELECT 1 AS c FROM (VALUES(1),(1),(1),(1),(1),(1),(1),(1),(1),(1)) v(c)),  -- 10
      L1 AS (SELECT 1 AS c FROM L0 a CROSS JOIN L0 b),                                  -- 100
      L2 AS (SELECT 1 AS c FROM L1 a CROSS JOIN L1 b),                                  -- 10.000
      L3 AS (SELECT 1 AS c FROM L2 a CROSS JOIN L1 b CROSS JOIN L0 c)                   -- 10.000.000
INSERT INTO lab.Numeros (n)
SELECT TOP (2000000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) FROM L3;
GO

DECLARE @rows int = 1000000;

-- ---------------------------------------------------------------
-- 1) VENTAS: 4 regiones x 365 días, 3 ventas/día, ~10 % de días sin ventas
-- ---------------------------------------------------------------
CREATE TABLE lab.ventas (
    id_venta  bigint IDENTITY(1,1) PRIMARY KEY,
    fecha     date          NOT NULL,
    region    varchar(10)   NOT NULL,
    vendedor  varchar(10)   NOT NULL,
    monto     decimal(12,2) NOT NULL
);
;WITH dias_region AS (
    SELECT DATEADD(day, n.n - 1, '2025-01-01') AS fecha, r.region
    FROM   lab.Numeros n
    CROSS  JOIN (VALUES ('Norte'),('Sur'),('Este'),('Oeste')) r(region)
    WHERE  n.n <= 365
      AND  ABS(CHECKSUM(NEWID())) % 100 >= 10         -- quita ~10 % de días
)
INSERT INTO lab.ventas (fecha, region, vendedor, monto)
SELECT d.fecha, d.region,
       'vend_' + CAST(1 + ABS(CHECKSUM(NEWID())) % 10 AS varchar(2)),
       CAST(50 + RAND(CHECKSUM(NEWID())) * 950 + CASE d.region WHEN 'Norte' THEN 200 ELSE 0 END AS decimal(12,2))
FROM   dias_region d
CROSS  JOIN (VALUES (1),(2),(3)) x(k);
CREATE INDEX ix_ventas_region_fecha ON lab.ventas (region, fecha);

-- ---------------------------------------------------------------
-- 2) EMPLEADOS
-- ---------------------------------------------------------------
CREATE TABLE lab.empleados (
    id_empleado int PRIMARY KEY,
    nombre      nvarchar(60) NOT NULL,
    cargo       nvarchar(60) NOT NULL,
    id_manager  int NULL REFERENCES lab.empleados(id_empleado),
    salario     decimal(10,2) NOT NULL
);
INSERT INTO lab.empleados VALUES
 (1 ,N'Ana García'     ,N'CEO'              ,NULL,25000),
 (2 ,N'Luis Pérez'     ,N'CTO'              ,1   ,18000),
 (3 ,N'Marta Ruiz'     ,N'CFO'              ,1   ,18000),
 (4 ,N'Pedro Sánchez'  ,N'VP Ingeniería'    ,2   ,14000),
 (5 ,N'Elena Torres'   ,N'VP Datos'         ,2   ,14000),
 (6 ,N'Jorge Molina'   ,N'Controller'       ,3   ,11000),
 (7 ,N'Sofía Castro'   ,N'Eng Manager'      ,4   ,10000),
 (8 ,N'Diego Romero'   ,N'Eng Manager'      ,4   ,10000),
 (9 ,N'Lucía Navarro'  ,N'Data Manager'     ,5   ,10000),
 (10,N'Carlos Vega'    ,N'Senior Developer' ,7   , 7000),
 (11,N'Paula Ortiz'    ,N'Developer'        ,7   , 5500),
 (12,N'Raúl Gil'       ,N'Developer'        ,8   , 5500),
 (13,N'Nuria Blanco'   ,N'Data Engineer'    ,9   , 7000),
 (14,N'Iván Serrano'   ,N'Data Analyst'     ,9   , 5000),
 (15,N'Clara Domínguez',N'BI Developer'     ,9   , 5500),
 (16,N'Óscar Marín'    ,N'Contador'         ,6   , 4500),
 (17,N'Teresa Campos'  ,N'Junior Developer' ,10  , 3500),
 (18,N'Hugo Prieto'    ,N'Junior Data Eng'  ,13  , 3500);

-- ---------------------------------------------------------------
-- 3) USUARIOS + EVENTOS (tabla grande, sin índices salvo PK)
-- ---------------------------------------------------------------
CREATE TABLE lab.usuarios (
    id_usuario int PRIMARY KEY,
    pais       char(2)     NOT NULL,
    plan       varchar(10) NOT NULL
);
INSERT INTO lab.usuarios
SELECT n,
       CHOOSE(1 + ABS(CHECKSUM(NEWID())) % 6, 'ES','MX','AR','CO','CL','PE'),
       CHOOSE(1 + ABS(CHECKSUM(NEWID())) % 3, 'free','pro','enterprise')
FROM lab.Numeros WHERE n <= 50000;

CREATE TABLE lab.eventos (
    id_evento   bigint IDENTITY(1,1) PRIMARY KEY,
    id_usuario  int          NOT NULL,
    tipo_evento varchar(10)  NOT NULL,
    created_at  datetime2(0) NOT NULL,
    payload     nvarchar(max) NULL
);
INSERT INTO lab.eventos (id_usuario, tipo_evento, created_at, payload)
SELECT 1 + ABS(CHECKSUM(NEWID())) % 50000,
       CHOOSE(1 + ABS(CHECKSUM(NEWID())) % 5, 'login','view','click','purchase','logout'),
       DATEADD(second, ABS(CHECKSUM(NEWID())) % 31449600, '2025-01-01'),   -- 364 días en segundos
       N'{"v": ' + CAST(ABS(CHECKSUM(NEWID())) % 100 AS nvarchar(3)) + N'}'
FROM lab.Numeros WHERE n <= @rows;

-- ---------------------------------------------------------------
-- 4) CLIENTES_RAW (~10 % de emails duplicados)
-- ---------------------------------------------------------------
CREATE TABLE lab.clientes_raw (
    id_fila    bigint IDENTITY(1,1) PRIMARY KEY,
    email      varchar(60)  NOT NULL,
    nombre     nvarchar(60) NULL,
    telefono   varchar(15)  NULL,
    updated_at datetime2(0) NOT NULL,
    origen     varchar(10)  NOT NULL
);
INSERT INTO lab.clientes_raw (email, nombre, telefono, updated_at, origen)
SELECT 'user' + RIGHT('00000000' + CAST(1 + ABS(CHECKSUM(NEWID())) % CAST(@rows * 0.9 AS int) AS varchar(8)), 8) + '@mail.com',
       N'Cliente ' + CAST(n AS nvarchar(10)),
       CASE WHEN ABS(CHECKSUM(NEWID())) % 10 = 0 THEN NULL
            ELSE '+34' + CAST(600000000 + ABS(CHECKSUM(NEWID())) % 99999999 AS varchar(12)) END,
       DATEADD(minute, ABS(CHECKSUM(NEWID())) % 864000, '2024-01-01'),      -- 600 días en minutos
       CHOOSE(1 + ABS(CHECKSUM(NEWID())) % 3, 'crm','web','import')
FROM lab.Numeros WHERE n <= @rows;

-- ---------------------------------------------------------------
-- 5) PEDIDOS_FUENTE (verdad) y PEDIDOS (con NULLs entre 2025-07-10 y 2025-10-05)
-- ---------------------------------------------------------------
CREATE TABLE lab.pedidos_fuente (
    id_pedido    int PRIMARY KEY,
    fecha_pedido date          NOT NULL,
    id_cliente   int           NOT NULL,
    canal_venta  varchar(10)   NOT NULL,
    importe      decimal(12,2) NOT NULL
);
INSERT INTO lab.pedidos_fuente
SELECT n,
       DATEADD(day, ABS(CHECKSUM(NEWID())) % 331, '2025-01-01'),
       1 + ABS(CHECKSUM(NEWID())) % 10000,
       CHOOSE(1 + ABS(CHECKSUM(NEWID())) % 4, 'web','tienda','telefono','app'),
       CAST(10 + RAND(CHECKSUM(NEWID())) * 490 AS decimal(12,2))
FROM lab.Numeros WHERE n <= 200000;

SELECT id_pedido, fecha_pedido, id_cliente,
       CASE WHEN fecha_pedido BETWEEN '2025-07-10' AND '2025-10-05'
                 AND ABS(CHECKSUM(NEWID())) % 100 < 97
            THEN NULL ELSE canal_venta END AS canal_venta,
       importe
INTO   lab.pedidos
FROM   lab.pedidos_fuente;
ALTER TABLE lab.pedidos ADD PRIMARY KEY (id_pedido);
GO

UPDATE STATISTICS lab.eventos; UPDATE STATISTICS lab.clientes_raw; UPDATE STATISTICS lab.pedidos;
SELECT 'ventas' AS t, COUNT(*) AS filas FROM lab.ventas
UNION ALL SELECT 'empleados',    COUNT(*) FROM lab.empleados
UNION ALL SELECT 'eventos',      COUNT(*) FROM lab.eventos
UNION ALL SELECT 'clientes_raw', COUNT(*) FROM lab.clientes_raw
UNION ALL SELECT 'pedidos',      COUNT(*) FROM lab.pedidos;
GO
