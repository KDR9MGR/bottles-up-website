#!/usr/bin/env bash
# Two businesses are renamed to the SAME free name at the same moment (two owners who both picked it). Only ONE may get it: no two businesses may carry the same name.
#
# rename_business() takes an advisory lock on the (tidied, lower-case) name before it looks for another business using it. Owner A renames to the name and keeps its transaction open for 2 seconds;
# owner B asks 0.5 s later and must WAIT for A, then see A's committed name and be refused. Without the lock B would look, find nobody using the name yet, and both would be renamed. Committed rows are
# created for this and removed afterwards.
set -euo pipefail
cd "$(dirname "$0")/../.."
DB="${TEST_DB_NAME:-bottlesup_test}"
psql_db() { psql -X -q -t -A -v ON_ERROR_STOP=1 -d "$DB" "$@"; }
fail() { echo "FAIL - rename business concurrency: $1"; exit 1; }
UA=00000000-0000-0000-0000-0000000006b1
UB=00000000-0000-0000-0000-0000000006b2
ORGA=00000000-0000-0000-0000-0000000006b3
ORGB=00000000-0000-0000-0000-0000000006b4
NAME='Rename Race Prize'

cleanup() {
  psql_db -c "delete from public.audit_log where entity_id in ('$ORGA', '$ORGB') and action = 'business.renamed'" \
          -c "delete from public.site_memberships where org_id in ('$ORGA', '$ORGB')" \
          -c "delete from public.site_organizations where id in ('$ORGA', '$ORGB')" \
          -c "delete from auth.users where id in ('$UA', '$UB')" >/dev/null 2>&1 || true
}
OUT_A=$(mktemp); OUT_B=$(mktemp)
trap 'rm -f "$OUT_A" "$OUT_B"; cleanup' EXIT
cleanup
psql_db >/dev/null <<SQL
insert into auth.users (id, email) values ('$UA', 'ownera@rename.test.example'), ('$UB', 'ownerb@rename.test.example');
insert into public.site_organizations (id, name, kind, created_by) values ('$ORGA', 'Rename Race Alpha', 'venue_owner', '$UA'), ('$ORGB', 'Rename Race Beta', 'venue_owner', '$UB');
insert into public.site_memberships (org_id, user_id, role) values ('$ORGA', '$UA', 'owner'), ('$ORGB', '$UB', 'owner');
SQL
now_ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }
claims() { echo "select set_config('request.jwt.claims', '{\"sub\":\"$1\",\"role\":\"authenticated\",\"email\":\"$2\"}', true) is not null;"; }
rename() { echo "select 'R:' || new_name from public.rename_business('$1', '$NAME');"; }

psql_db >"$OUT_A" <<SQL &
begin;
$(claims "$UA" ownera@rename.test.example)
set local role authenticated;
$(rename "$ORGA")
select pg_sleep(2);
commit;
SQL
PID_A=$!
sleep 0.5
START=$(now_ms)
set +e
psql -X -q -t -A -v ON_ERROR_STOP=1 -d "$DB" >"$OUT_B" 2>&1 <<SQL
begin;
$(claims "$UB" ownerb@rename.test.example)
set local role authenticated;
$(rename "$ORGB")
commit;
SQL
set -e
WAITED=$(( $(now_ms) - START ))
wait "$PID_A"

HOLDERS=$(psql_db -c "select count(*) from public.site_organizations where id in ('$ORGA', '$ORGB') and name = '$NAME'")
BETA=$(psql_db -c "select name from public.site_organizations where id = '$ORGB'")
grep -q "^R:$NAME" "$OUT_A"                                       || fail "owner A should have got the name: $(cat "$OUT_A")"
grep -q 'another business already uses that name' "$OUT_B"       || fail "owner B should have been refused, after waiting: $(cat "$OUT_B")"
[ "$HOLDERS" = "1" ]                                              || fail "exactly one business should carry the name, got $HOLDERS"
[ "$BETA" = "Rename Race Beta" ]                                  || fail "the refused business should keep its own name, got $BETA"
[ "$WAITED" -ge 1000 ]                                            || fail "owner B did not wait for A's lock (${WAITED} ms)"
echo "ok - two businesses renamed to the same free name at once: one got it, the other waited ${WAITED} ms and was refused (no two businesses share a name)"
