#!/usr/bin/env bash
# Ejecuta el lab completo en SQL Server (contenedor sql_lab_mssql de docker-compose).
#   ./run_sqlserver.sh          -> todo
#   ./run_sqlserver.sh 02       -> setup + ejercicio 02
# Para un servidor propio: usá SSMS/Azure Data Studio y abrí los .sql en orden, o
#   sqlcmd -S host -U user -P pass -I -i sqlserver/00_setup.sql   (-I = QUOTED_IDENTIFIER ON)
set -euo pipefail
cd "$(dirname "$0")"
EJ="${1:-all}"
PASS="Lab_Pass_2025!"
# La imagen 2022 trae sqlcmd en /opt/mssql-tools18 (requiere -C para confiar en el certificado autofirmado)
RUN() { docker compose exec -T sqlserver /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "$PASS" -C -I -b -i "/lab/$1"; }

echo "== 00_setup"; RUN 00_setup.sql
for f in 01_window_functions 02_recursive_cte 03_optimizacion 04_deduplicacion 05_datos_faltantes; do
  if [[ "$EJ" == "all" || "$f" == "$EJ"* ]]; then echo; echo "== $f"; RUN "$f.sql"; fi
done
