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
| Account routing | `src/lib/accountRouting.test.ts`, `workspaceAccess.test.ts`, `safeNext.test.ts` | Where each role lands after login, remembered workspaces, revoked access, hostile `?next=` values (open redirects) |
| Verification and setup | `src/lib/verification.test.ts`, `venueSetup.test.ts`, `roleNavigation.test.ts` | The four states, what each allows, "why is this blocked and what do I do", setup readiness, each role's own navigation |
| Team and invitations | `src/lib/team.test.ts`, `tests/edge/teamInvitationEmail.test.ts`, `sendTeamInvitation.test.ts`, `sendTeamInvitationEndpoint.test.ts` | Invite validation, temporary access, what each state allows; the email escapes user-typed names, only goes to the address on the invitation, never uses the service key, and builds a real link |
| Door scanner | `src/lib/doorScan.test.ts`, `src/lib/rpcContract.test.ts` | What a camera read should do (cooldown, busy, paused), what each outcome tells the person at the door (only "Admit" is green; unpaid and wrong-event are stops), reading rows, and that every database call matches its SQL |
| Venue setup forms | `src/lib/venueSetupForms.test.ts` | Dollars to whole cents without floating point, every validation message, that opening a saved table or bottle and saving it unchanged sends the same values, and that the fields and limits the forms use are the ones in the SQL (it reads the whitelist from the migration) |
| Tables & bookings view | `src/lib/bookingsView.test.ts` | What each stored status means (an unknown one is never "confirmed"), grouping by night and counting only confirmed guests, the ready-made date ranges in business nights (01:30 is still last night, 06:00 starts a new one), range validation, and that the 06:00 cutoff, the 93-night limit and the 1000-row limit in the SQL are the ones the screen expects |
| Booking link | `src/lib/bookingLink.test.ts` | Which site address is used (a bad configured value is ignored), the link built from a venue slug or id, that only a published venue's link works, and a safe QR file name |
| Account pages | `src/account/**/*.test.tsx` | The real workspace page server-rendered with a simulated account: what each role sees, the no-access page, banners; the venue setup editors' first paint |

The edge functions are written for Deno (`npm:` imports). `vitest.config.ts` aliases those imports to real packages or the stubs in `tests/edge/stubs/`, so the function source runs unmodified. `tests/edge/stubs/fakeDb.ts` is a small in-memory Supabase client; embedded relations are not resolved, so seed rows with nested objects already attached.

## 2. Database tests: `tests/db/run.sh` (needs `psql` and a throwaway Postgres)

```bash
PGHOST=localhost PGUSER=postgres PGPASSWORD=postgres tests/db/run.sh
PGHOST=localhost PGUSER=postgres PGPASSWORD=postgres tests/db/run.sh --with-fix
```

Test files: `010` check-in, `020` entry codes, `030` row level security, `040` tenancy (organizations, roles, invitations),
`050` accounts and onboarding (profiles, business verification, venue claims, venue setup, image storage),
`060` team and invitations (who sees whom, every invitation state, and the rules that make emailing a link safe),
`070` the scoped door scanner (what each door person may scan, every outcome, the entry-code step, guest search, and that the older unscoped functions stay out of reach),
`090` the owner's read-only bookings (who may read a venue's bookings, that one venue never shows another's, the business night including the 05:59 / 06:00 boundary and year ends, ordering, the row and date limits),
`080` owner venue setup (who may edit which venue, that a row id from another venue is unreachable, the field whitelist and every validation, the limits, deletes that bookings block, what the public site sees, and the audit trail).

It creates a database called `bottlesup_test` (never point it at a real project), replays `supabase/migrations` on plain Postgres through a small Supabase stand-in (`00_supabase_shim.sql`), then runs `tests/db/tests/*.sql` and `concurrency.sh`: who may scan, every `checkin_ticket` outcome, the entry-code lockout, RLS on orders, two staff scanning one ticket at the same time (through the old scanner and the scoped one), and two people adding the same arrival time at the same moment.

### Known bug, and the proposed fix

Checks marked **KNOWN BUG** document a real defect: `checkin_ticket()` does not `return` after answering `expired` or `code_required`, so it also admits the ticket. They pass while the bug exists and fail the moment it is fixed, so the marker gets removed. The fix is `supabase/proposed/20260830_fix_checkin_ticket_early_returns.sql` (kept outside `migrations/` so `supabase db push` cannot ship it by accident). `run.sh --with-fix` applies it and requires every check to pass for real. CI runs both modes.

### The migrations do not describe production

`01_prod_prerequisites.sql` exists because the committed migrations assume things that no committed migration creates (`public.set_updated_at()`). More importantly, 17 of the 24 RPCs the website calls (the whole server, pay-at-club and reconciliation system), plus the `profiles`, `promo_codes` and `guest_tickets` tables and several `door_staff` columns, exist **only in the production database**. They cannot be tested here until their definitions are committed (`supabase db pull` against production is the way).

## Type check, lint, and the baseline

`npm run typecheck` fails on any type error that is not in `tsc-baseline.json` (about 127 today, nearly all because `src/types/database.ts` is out of date). When you fix some, run `node scripts/tsc-ratchet.mjs --update` so they cannot come back. `npm run lint:ci` allows at most 8 warnings and no errors.
