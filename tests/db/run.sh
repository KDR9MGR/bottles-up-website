#!/usr/bin/env bash
# Database tests: replay the committed migrations on a plain Postgres, then run
# the SQL tests against check-in, one-time codes and row-level security.
#
#   tests/db/run.sh              run the suite against the migrations as committed
#   tests/db/run.sh --with-fix   also apply supabase/proposed/*.sql first, to prove the
#                                proposed fixes make the known-bug checks pass for real
#
# Connects with the standard libpq variables (PGHOST, PGPORT, PGUSER, PGPASSWORD).
# Needs `psql` and a Postgres whose user may create databases and roles (a CI
# service container is fine). Creates a throwaway database, "bottlesup_test" by
# default (override with TEST_DB_NAME). Never point this at a real project.
set -euo pipefail
cd "$(dirname "$0")/../.."
export LC_ALL=C
DB="${TEST_DB_NAME:-bottlesup_test}"
WITH_FIX=0; [ "${1:-}" = "--with-fix" ] && WITH_FIX=1

psql_admin() { psql -X -q -v ON_ERROR_STOP=1 -d postgres "$@"; }
psql_db()    { psql -X -q -v ON_ERROR_STOP=1 -d "$DB" "$@"; }
strip()      { sed -E 's/^psql:[^ ]+:[0-9]+: NOTICE:  //'; }

echo "==> creating database $DB"
psql_admin -c "drop database if exists \"$DB\" with (force)" -c "create database \"$DB\""

echo "==> supabase shim and production prerequisites"
psql_db -f tests/db/00_supabase_shim.sql -f tests/db/01_prod_prerequisites.sql

COUNT=$(ls supabase/migrations/*.sql | wc -l | tr -d ' ')
echo "==> replaying $COUNT migrations (byte order, like the migration runner)"
for f in $(ls supabase/migrations/*.sql | LC_ALL=C sort); do
  PGOPTIONS='-c client_min_messages=warning' psql_db -f "$f" >/dev/null || { echo "MIGRATION FAILED: $f"; exit 1; }
done

if [ "$WITH_FIX" = "1" ]; then
  for f in $(ls supabase/proposed/*.sql | LC_ALL=C sort); do
    echo "==> applying PROPOSED fix: $(basename "$f")"
    PGOPTIONS='-c client_min_messages=warning' psql_db -f "$f" >/dev/null || { echo "PROPOSED FIX FAILED: $f"; exit 1; }
  done
  export PGOPTIONS='-c tests.fix_applied=on'
fi

echo "==> helpers and fixtures"
psql_db -f tests/db/02_test_helpers.sql -f tests/db/03_fixtures.sql

echo "==> tests"
assertions=0
for t in $(ls tests/db/tests/*.sql | LC_ALL=C sort); do
  echo "--- $(basename "$t")"
  out=$(psql_db -f "$t" 2>&1) || { echo "$out" | strip; echo "FAILED: $t"; exit 1; }
  echo "$out" | strip | grep '^ok - ' | sed 's/^/    /' || true
  assertions=$((assertions + $(echo "$out" | grep -c 'NOTICE:  ok - ')))
done

echo "--- concurrency.sh"
bash tests/db/concurrency.sh

echo "==> all database tests passed ($assertions assertions + the concurrency scenarios)$([ "$WITH_FIX" = "1" ] && echo " WITH the proposed fix applied")"
