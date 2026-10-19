#!/usr/bin/env bash
# Runs ONE test file (a name under tests/db/tests) against the scratch database built by build_dev_db.sh.
#   tests/db/dev/run_one.sh 190_chat.sql
# Prints how many assertions passed and the first failure. Exit code is psql's. The full suite is still tests/db/run.sh (it also runs the races).
cd "$(dirname "$0")/../../.."
DB="${DEV_DB:-opsdev}"
[ -n "${1:-}" ] || { echo "usage: $0 <file under tests/db/tests>"; exit 2; }
out=$(psql -X -v ON_ERROR_STOP=1 -d "$DB" -f "tests/db/tests/$1" 2>&1); code=$?
echo "ok lines: $(echo "$out" | grep -c 'NOTICE:  ok - ')"
echo "$out" | grep -E "ERROR|FAIL|CONTEXT|LINE" | head -8 | cut -c1-260
exit $code
