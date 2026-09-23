#!/usr/bin/env bash
# Builds the database from scratch and runs every file in order.
#   ./run_all.sh                 # uses: mysql -uroot
#   MYSQL="mysql -uuser -p" ./run_all.sh
set -euo pipefail
cd "$(dirname "$0")"
MYSQL=${MYSQL:-"mysql -uroot"}
mkdir -p output

files=(
  level-1-foundations/01_schema.sql
  data/02_seed_data.sql
  level-1-foundations/03_basic_reporting.sql
  level-2-intermediate/04_raw_to_clean_etl.sql
  level-2-intermediate/05_data_quality_audit.sql
  level-2-intermediate/06_weighted_kpis_and_quality.sql
  level-3-advanced/07_campaigns_gaps_and_islands.sql
  level-3-advanced/08_gas_model_regression.sql
  level-3-advanced/09_window_analytics.sql
  level-3-advanced/10_idempotent_migration.sql
)

for f in "${files[@]}"; do
  out="output/$(basename "${f%.sql}").txt"
  printf '%-58s' "$f"
  $MYSQL --table < "$f" > "$out"
  echo "ok  -> $out"
done
