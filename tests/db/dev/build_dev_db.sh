#!/usr/bin/env bash
# Rebuilds a scratch database ("opsdev" by default) exactly as tests/db/run.sh does (shim, production prerequisites, every migration with its
# production-only shapes, helpers and fixtures), so ONE test file at a time can be run quickly with run_one.sh. Never point this at a real project.
#
#   tests/db/dev/build_dev_db.sh          rebuild opsdev
#   DEV_DB=mydb tests/db/dev/build_dev_db.sh
#
# Connects with the standard libpq variables. On this Mac (see memory "local-db-tests-postgres"):
#   export LC_ALL=en_US.UTF-8 PATH=/opt/homebrew/opt/postgresql@15/bin:$PATH PGHOST=127.0.0.1 PGPORT=54329 PGUSER=postgres
set -euo pipefail
cd "$(dirname "$0")/../../.."
DB="${DEV_DB:-opsdev}"
psql -X -q -d postgres -c "drop database if exists \"$DB\" with (force)" -c "create database \"$DB\""
pdb() { psql -X -q -v ON_ERROR_STOP=1 -d "$DB" "$@"; }
pdb -f tests/db/00_supabase_shim.sql -f tests/db/01_prod_prerequisites.sql >/dev/null
for f in $(ls supabase/migrations/*.sql | LC_ALL=C sort); do
  ts=$(basename "$f" | cut -d_ -f1)
  for shape in tests/db/prod_shapes/"$ts"_*.sql; do [ -e "$shape" ] || continue; PGOPTIONS='-c client_min_messages=warning' pdb -f "$shape" >/dev/null; done
  PGOPTIONS='-c client_min_messages=warning' pdb -f "$f" >/dev/null || { echo "MIGRATION FAILED: $f"; exit 1; }
done
pdb -f tests/db/02_test_helpers.sql -f tests/db/03_fixtures.sql >/dev/null
echo "$DB ready ($(ls supabase/migrations/*.sql | wc -l | tr -d ' ') migrations)"
