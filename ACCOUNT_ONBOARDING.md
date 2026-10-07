# Account creation, onboarding and workspaces

Implements sections 1 to 3 of the client brief "Website Onboarding and Dashboards" (4 Oct 2026): the public
entry point, personal and business onboarding, verification states, and where each person lands after login.

**It is switched off by default.** Merging this code changes nothing on the live site until you turn it on
(see "Rollout"). With the flag off the header, homepage and routes are exactly as before.

## What it does

| Brief | Where |
|---|---|
| 1. Homepage account prompt (personal / business / log in), dismissible, not shown to signed-in users, keeps a booking link through sign-up and log-in | `src/account/components/AccountPrompt.tsx`, `GetStarted.tsx`, header in `src/components/Header.tsx`, rules in `src/lib/accountPrompt.ts` and `src/lib/safeNext.ts` |
| 2. Personal account: name, available username, photo, bio, city, socials; existing app users complete the same profile | `/signup/personal`, `/onboarding/profile`, DB `save_my_profile`, `username_available` |
| 2. Business account: Venue Owner or Event Organizer, business details, add or claim a venue, submit | `/signup/business`, `/business/new`, `/business/:orgId/onboarding` |
| 3. Verification states (Not submitted, Under review, More information needed, Verified), separate from setup readiness | `src/lib/verification.ts`, DB `site_verifications`, `submit_verification`, `review_verification` |
| 3. After login: personal, owner (one or several venues), organizer, manager, server, door, security, verifier, several roles -> selector that remembers the last one | `src/lib/accountRouting.ts`, `/home`, `/workspaces` |
| 3. Staff join by invitation; revoked or expired access opens nothing | `/accept-invite`, `src/lib/workspaceAccess.ts`, tenancy migration |
| 3. Always show venue, event and night; explicit role switching | `src/account/workspace/WorkspacePage.tsx` |
| Admin review of businesses and ownership requests | `/cms/verifications` |

Access is enforced in the database (row level security and the permission functions), never only by hiding
screens. The unit tests cover the rules; the database tests (`tests/db/tests/040_tenancy.sql`,
`050_accounts_onboarding.sql`) cover who may do what, including the abuse cases (a business verifying itself,
taking someone else's venue, or publishing its own listing).

## Rollout (in this order)

1. **Get access to the real database definitions first.** The migrations assume `public.profiles` and the
   `site_*` tables exist as they do in production; `profiles` is not defined by any migration here. The
   onboarding migration stops with a clear message if `profiles` is missing or already has a column called
   `username`, `bio`, `city`, `social_links` or `profile_completed_at`. Run
   `supabase/audit/01_live_db_audit.sql` (in the monorepo root) against production and read the result before
   applying anything.
2. **Apply to staging first**, then production, in order:
   - `supabase/migrations/20261006120000_tenancy_foundation.sql`
   - `supabase/migrations/20261007100000_accounts_onboarding.sql`

   Functions use plain `CREATE`, so if the live database already has a function with the same name and
   arguments the migration fails instead of overwriting it.
3. **Supabase Auth settings** (dashboard, Authentication > URL Configuration):
   - Redirect URLs must allow `https://www.bottlesupapp.com/home` (sign-up and log-in links return there), and
     `http://localhost:*` for development.
   - Decide whether email confirmation is required. The code handles both: with confirmation on, the person is
     told to check their email and the link resumes onboarding on any device; with it off they continue at once.
4. **Turn it on:** set `VITE_ENABLE_ACCOUNT_ONBOARDING=true` in the environment the site is built with
   (Vercel project settings) and redeploy. Turn it off the same way to roll back; no data is lost.
5. Optional: `VITE_APP_STORE_URL` and `VITE_PLAY_STORE_URL` (https only) add app download buttons to the
   homepage once the apps are published. They are not invented; with no value nothing is shown.

If the new database functions are not deployed yet, the site still works for everyone: the account snapshot
treats a missing function as "nothing there" instead of failing.

## What is not built yet

Said plainly so nobody assumes otherwise:

- **Inviting staff from the website.** The database functions exist (`invite_member` and friends) and
  `/accept-invite` works, but there is no Team screen to create an invitation or email the link.
- **Scoped screens for invited staff (server, door, security, verifier).** They land in `/w/<membership>/...`
  placeholders, not in the existing `/staff` and `/door` pages, on purpose. Those pages and their policies rely on
  `is_door_staff()`, which is global: any row in `door_staff` grants check-in access across the whole platform, with no
  venue or event scoping. Widening it to cover invited staff would give every invited server platform-wide access,
  which the brief forbids ("invited staff access only their assignments"). The scoped replacements are the next
  slice; existing `door_staff` people keep their current pages and landing unchanged.
- **The dashboards behind the sidebar.** Overview and My Venues are real (verification banner, setup progress,
  venue profile editing). Every other section shows "Not available on the website yet" with what it will hold.
- **Editing floor plans, tables, bottles and booking rules as an owner.** They count toward setup progress and
  are done by the BottlesUp team (CMS) for now. Payment configuration and notifications are shown as "Coming soon".
- **Publishing a venue.** An owner cannot publish; the page says what blocks it (verification, setup) and, when
  nothing does, to contact BottlesUp. There is deliberately no self-publish function yet.
- **Short venue links** such as `bottlesupapp.com/xno` (the brief marks this as a URL design, not a live route).
  Existing `/venues/:id` links already keep their destination through sign-up and log-in.
- **Per-venue time zone.** "Tonight" uses the device's clock with the 06:00 night cutoff already used by bookings.
- **Forgot-password and legal verification review.** Out of scope per the brief.
- The older partner pages (`/partners/*`) and the old `partner_accounts` table are untouched. Whether existing
  partner applicants migrate to the new business accounts is an open question for the client.

## Developing and testing

```bash
VITE_ENABLE_ACCOUNT_ONBOARDING=true npm run dev     # see the new pages locally
npm test                                            # unit tests (rules, routing, page rendering)
PGHOST=localhost PGUSER=postgres PGPASSWORD=postgres tests/db/run.sh   # database tests
```

Do not submit sign-up or log-in forms while pointed at the production Supabase project: that creates real accounts.
