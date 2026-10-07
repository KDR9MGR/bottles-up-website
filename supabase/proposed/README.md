# Proposed fixes

SQL that is written and tested but deliberately **not** in `supabase/migrations/`, so `supabase db push` cannot ship it by
accident. `tests/db/run.sh --with-fix` applies everything here before running the suite, to prove each proposal makes its
"known bug" checks pass for real (see `assert_known_bug` in `tests/db/02_test_helpers.sql`), so a proposal cannot rot.

**There are none right now.** The `checkin_ticket()` fix lived here until it was shipped as
`supabase/migrations/20260830120000_fix_checkin_ticket_early_returns.sql`.

To propose a fix: add the SQL here, mark the checks that currently document the defect with `assert_known_bug`, and CI will
run the suite both ways. To ship it, move the file into `migrations/` with a unique 14-digit version and turn the markers
into `assert_eq`.
