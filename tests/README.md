# Tests

Two kinds, both run in CI (`.github/workflows/ci.yml`).

## 1. Unit tests: `npm test` (vitest, about a second)

| Area | File | What it pins down |
|---|---|---|
| Stripe webhook | `tests/edge/siteStripeWebhook.test.ts` | Real Stripe signatures: wrong secret, tampered body and missing header are rejected; test or live secret accepted; routes to ticket / table / bottle add-on; ignores sessions it did not create; does not swallow a fulfillment failure |
| Fulfillment | `tests/edge/fulfillment.test.ts` | Marks paid and emails exactly once; redelivery is a no-op; a retry after a failed email re-sends the same code without re-counting; competing writers (atomic claim); pay-at-club amounts |
| Pricing | `tests/edge/pricing.test.ts` | Tax and platform fee, due-at-venue bottles, deposit credit, discounts before tax, cancelled lines, rounding |
| Promo and access codes | `tests/edge/promoCode.test.ts`, `tierAccessCode.test.ts` | Every rejection reason, limits, venue scoping, rounding; real bcrypt |
| After-midnight logic | `tests/edge/bookingNight.test.ts` | Browser and edge copies of `bookingNight` agree, round-trip, year and leap-day rollover |
| Small helpers | `src/lib/*.test.ts` | `formatMoney`, `derivePaymentStatus`, disposable emails, delete-blocked errors |

The edge functions are written for Deno (`npm:` imports). `vitest.config.ts` aliases those imports to real packages or the stubs in `tests/edge/stubs/`, so the function source runs unmodified. `tests/edge/stubs/fakeDb.ts` is a small in-memory Supabase client; embedded relations are not resolved, so seed rows with nested objects already attached.

## 2. Database tests: `tests/db/run.sh` (needs `psql` and a throwaway Postgres)

```bash
PGHOST=localhost PGUSER=postgres PGPASSWORD=postgres tests/db/run.sh
PGHOST=localhost PGUSER=postgres PGPASSWORD=postgres tests/db/run.sh --with-fix
```

It creates a database called `bottlesup_test` (never point it at a real project), replays `supabase/migrations` on plain Postgres through a small Supabase stand-in (`00_supabase_shim.sql`), then runs `tests/db/tests/*.sql`, `concurrency.sh` `concurrency.sh`, `migration_guard.sh` and `migration_guard_verify.sh`: who may scan, every `checkin_ticket` outcome, the entry-code lockout, RLS on orders, two staff scanning one ticket at the same time, and the safe application of the check-in fix.

### The check-in expiry fix, and how it is applied safely

`checkin_ticket()` used to answer `expired` and `code_required` without returning, so it also admitted the ticket (an expired ticket showed as checked in, and a non-transferable ticket was admitted before its entry code was checked). It is fixed by `supabase/migrations/20260830120000_fix_checkin_ticket_early_returns.sql`.

That migration replaces a **live** function that may differ from this repository (not every change to the live database is in a migration), so it is a compare-and-swap: it replaces `checkin_ticket()` only if the live one is exactly the version it was written against, does nothing if it already has the fix, and **stops without changing anything** if the live one is anything else. `tests/db/migration_guard.sh` runs the real migration against a database in each of those situations (and with Windows line endings, which must not count as a difference), and also checks that the fingerprints the migration declares are the ones the functions really have. `tests/db/fixtures/checkin_ticket_before_fix.sql` is the old function, used to recreate the "before" state.

To see what the bug already did to real guests, run `supabase/audit/checkin_fallthrough.sql` (read-only) in production. The test suite runs it against a database where the bug has just happened.

The entry-code function had its own gaps, fixed the same guarded way by `supabase/migrations/20260830130000_fix_verify_ticket_otp_expiry.sql`: it ignored whether the event had ended (a correct code admitted a guest of an event that was over), it answered "ok" for an ordinary ticket without marking it used, and a call with no code at all skipped the wrong-code branch and admitted the guest. The scanner screen never reaches these (it asks for a code only after a "code required" answer), so they were only possible by calling the function directly. `tests/db/migration_guard_verify.sh` reproduces all three on the old function and shows them cured; `supabase/audit/verify_otp_after_event.sql` finds the one that leaves a trace. Both guards share their scenarios through `tests/db/guard_lib.sh`.

`supabase/proposed/` is where a written-but-unshipped fix would live (see its README). `run.sh --with-fix` applies whatever is there and requires its `assert_known_bug` checks to pass for real; there is nothing proposed right now.

### The migrations do not describe production

`01_prod_prerequisites.sql` exists because the committed migrations assume things that no committed migration creates (`public.set_updated_at()`). More importantly, 17 of the 24 RPCs the website calls (the whole server, pay-at-club and reconciliation system), plus the `profiles`, `promo_codes` and `guest_tickets` tables and several `door_staff` columns, exist **only in the production database**. They cannot be tested here until their definitions are committed (`supabase db pull` against production is the way).

## Type check, lint, and the baseline

`npm run typecheck` fails on any type error that is not in `tsc-baseline.json` (about 127 today, nearly all because `src/types/database.ts` is out of date). When you fix some, run `node scripts/tsc-ratchet.mjs --update` so they cannot come back. `npm run lint:ci` allows at most 8 warnings and no errors.
