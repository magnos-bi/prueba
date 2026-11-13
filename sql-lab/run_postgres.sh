#!/usr/bin/env bash
# Ejecuta el lab completo en PostgreSQL.
#   ./run_postgres.sh                 -> usa docker compose (contenedor sql_lab_pg)
#   PGURL=postgresql://u:p@host/db ./run_postgres.sh   -> contra cualquier servidor
#   ROWS=5000000 ./run_postgres.sh    -> tablas grandes de 5M filas
#   ./run_postgres.sh 03              -> solo setup + ejercicio 03
set -euo pipefail
cd "$(dirname "$0")/postgres"
ROWS="${ROWS:-1000000}"
EJ="${1:-all}"

if [[ -n "${PGURL:-}" ]]; then
  PSQL=(psql "$PGURL" -v ON_ERROR_STOP=1)
  RUN() { "${PSQL[@]}" -v ROWS="$ROWS" -f "$1"; }
else
  RUN() { docker compose -f ../docker-compose.yml exec -T postgres psql -U lab -d sql_lab -v ON_ERROR_STOP=1 -v ROWS="$ROWS" -f "/lab/$1"; }
fi

echo "== 00_setup (ROWS=$ROWS)"; RUN 00_setup.sql
for f in 01_window_functions 02_recursive_cte 03_optimizacion 04_deduplicacion 05_datos_faltantes; do
  if [[ "$EJ" == "all" || "$f" == "$EJ"* ]]; then echo; echo "== $f"; RUN "$f.sql"; fi
done
