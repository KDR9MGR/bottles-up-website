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
| Door scanner for invited door staff: scan tickets by camera or by typing the code, entry codes for non-transferable tickets, find a guest by name and admit them from the list, how many are in. Scoped to the person's own event or club | `/w/<membership>/scan` and `/guests`, `src/account/door/`, rules in `src/lib/doorScan.ts`, DB `door_scan_ticket`, `door_verify_ticket_code`, `door_guests`, `door_events` |
| Venue setup (owner, and the database allows managers): floor plan pictures, the kinds of table guests book (capacity, minimum spend, deposit, flat or hourly price, photo, badge), the bottle menu (price, size, stock, on the menu / sold out), and the days and arrival times bookings are accepted | `/w/<membership>/venues`, `src/account/setup/`, rules in `src/lib/venueSetupForms.ts`, DB `list_venue_*`, `save_venue_*`, `remove_venue_*`, `add_venue_time_slot` |
| Tables & Bookings (owner, read only): each venue's reservations night by night with the guest, table, party size, status (confirmed, awaiting payment, cancelled...), contact details, confirmation code and whether they have arrived; a booking after midnight is counted on the night before | `/w/<membership>/tables`, `src/account/workspace/OwnerBookings.tsx`, rules in `src/lib/bookingsView.ts`, DB `list_venue_bookings`, `booking_night` |
| Booking Link (owner): each venue's booking address, copy, a QR code to download for print, whether it works yet (only a published venue's does), and a preview of what guests see | `/w/<membership>/booking-link`, `src/account/workspace/BookingLinkSection.tsx`, rules in `src/lib/bookingLink.ts` |
| Team and invitations (owner and manager): invite with a role, a club, ongoing or temporary access and an optional shift; every invitation state; send a new link, cancel, remove access | `/w/<membership>/team`, `src/account/team/`, rules in `src/lib/team.ts`, DB `list_team`, `list_team_invitations`, `invitable_roles`, email via the `send-team-invitation` edge function |

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
   - `supabase/migrations/20261008100000_team_invitations.sql`
   - `supabase/migrations/20261009100000_door_scanner.sql` (also adds `site_events.venue_id` if it is missing: production already has it, because the CMS event form sets it, but no earlier migration here creates it)
   - `supabase/migrations/20261010100000_venue_setup.sql` (owner venue setup; creates only new functions, no tables or columns, and needs `site_venue_time_slots`, `site_venue_floors`, `site_table_types`, `site_table_bookings`, `site_bottles` and `audit_log`, all of which production has)
   - `supabase/migrations/20261011100000_venue_bookings.sql` (owner view of bookings; read only, new functions only. It calls `require_venue_editor` from the venue setup migration, so apply that one first)

   Functions use plain `CREATE`, so if the live database already has a function with the same name and
   arguments the migration fails instead of overwriting it.
3. **Deploy the invitation email function** (needed for the Team screen to email links; without it the screen still
   works and shows the link to copy):
   `supabase functions deploy send-team-invitation`
   It reuses the secrets the other emails already use: `RESEND_API_KEY` and `TICKETS_FROM_EMAIL`, and optionally
   `SITE_URL` (the address links should point at; defaults to `https://www.bottlesupapp.com`). It runs as the signed-in
   person, never with the service key, and can only email the address stored on the invitation.
4. **Supabase Auth settings** (dashboard, Authentication > URL Configuration):
   - Redirect URLs must allow `https://www.bottlesupapp.com/home` (sign-up and log-in links return there), and
     `http://localhost:*` for development.
   - Decide whether email confirmation is required. The code handles both: with confirmation on, the person is
     told to check their email and the link resumes onboarding on any device; with it off they continue at once.
5. **Turn it on:** set `VITE_ENABLE_ACCOUNT_ONBOARDING=true` in the environment the site is built with
   (Vercel project settings) and redeploy. Turn it off the same way to roll back; no data is lost.
6. Optional: `VITE_APP_STORE_URL` and `VITE_PLAY_STORE_URL` (https only) add app download buttons to the
   homepage once the apps are published. They are not invented; with no value nothing is shown.
   `VITE_SITE_URL` sets the address booking links and QR codes point at (default `https://www.bottlesupapp.com`).
   Only a plain https address is accepted; anything else is ignored, so a typo cannot reach a printed QR code.

If the new database functions are not deployed yet, the site still works for everyone: the account snapshot
treats a missing function as "nothing there" instead of failing.

## What is not built yet

Said plainly so nobody assumes otherwise:

- **Inviting for events.** The Team screen invites people to a club. Door staff for an organizer's events need
  the organizer's Events screens, which are not built.
- **Scoped screens for invited server, security and verifier staff.** They land in `/w/<membership>/...` placeholders,
  not in the existing `/staff` and `/door` pages, on purpose. Those pages and their policies rely on `is_door_staff()`,
  which is global: any row in `door_staff` grants check-in access across the whole platform, with no venue or event
  scoping. Widening it to cover invited staff would give every invited server platform-wide access, which the brief
  forbids ("invited staff access only their assignments"). Door staff now have scoped screens (below); the rest do not.
  Existing `door_staff` people keep their current pages and landing unchanged.
- **Door Sale, and table check-in at the door.** Door Sale (selling a ticket at the door) is not built. Checking in a
  table booking uses functions (`lookup_table_booking_for_checkin` and friends) that exist only in production, so they
  could not be reviewed or tested from this repository; a door person can scan event tickets only.
- **QR decoding was not tested in a browser.** The pane used for checking blocks the camera. The camera, its failure
  message and every other part of the screen were exercised, and manual entry works when the camera does not, but try
  the camera on a real phone before relying on it at a door.
- **The dashboards behind the sidebar.** Overview and My Venues are real (verification banner, setup progress,
  venue profile and setup editing), Tables & Bookings (read only), Booking Link and Team. Every other section shows "Not available on the website yet" with what it will hold.
- **Bottle Orders, and money actually collected.** Production has columns on bookings and bottle lines that no committed migration
  defines (what was paid, cancellation reason and time, reconciliation, each bottle line's service and payment state and whether it was
  cancelled). Showing bottle orders without them would count cancelled lines as live, and showing "paid" without them would guess. So
  Tables & Bookings shows what was booked (total and deposit), not what was collected, and bottle orders are not shown at all, until
  `supabase db pull` brings those definitions into the repository and they can be tested.
- **Walk-ins, guest allowances, table assignment and check-in for table bookings** (also production-only functions) are not in the owner's view.
- **Parts of venue setup that stay with the BottlesUp team (CMS).** Placing a table on the floor plan (position and
  size), and each table's seating type, view, privacy level, amenities and policy note. The last five columns exist in
  production but in no committed migration, so they could not be tested here; owners' edits never touch them (an
  existing value survives an owner's edit). Payment configuration and notifications are shown as "Coming soon".
- **Venue setup for managers.** The database lets a manager of a club run the same setup functions for that club, but the
  manager's own screens (Floor, More) are placeholders, so only the owner's "My Venues" page exposes the editors today.
- **Publishing a venue.** An owner cannot publish; the page says what blocks it (verification, setup) and, when
  nothing does, to contact BottlesUp. There is deliberately no self-publish function yet.
- **Short venue links** such as `bottlesupapp.com/xno` (the brief marks this as a URL design, not a live route), and
  **counting the bookings that came through a link**. The Booking Link section shows the existing `/venues/<slug>` address;
  those links already keep their destination through sign-up and log-in. Nothing records where a booking came from yet.
- **Per-venue time zone.** "Tonight" uses the device's clock with the 06:00 night cutoff already used by bookings.
- **Forgot-password and legal verification review.** Out of scope per the brief.
- The older partner pages (`/partners/*`) and the old `partner_accounts` table are untouched. Whether existing
  partner applicants migrate to the new business accounts is an open question for the client.

## How venue setup is protected

Owners and managers do **not** get write access to the venue tables. Each editor calls a database function that checks
the person may edit *that* venue (`can_access_venue`, role owner or manager), then writes only the fields the CMS already
writes and nothing else (no status, slug, owner or currency; a key it does not know is refused). A row id from another
venue is never reachable: the function looks the row up inside the venue it was given. Deleting something bookings still
point at (an arrival time or a table type) is refused with a plain sentence. Removing a bottle is allowed because past
orders keep their own copy of its name and price. Every change is recorded in `audit_log` with who, what and which venue
(the writer is not callable from the app, so entries cannot be forged). Per venue limits keep a runaway client from
filling the tables: 150 arrival times, 10 floors, 50 table types, 300 bottles. Changes to a venue that is already live
take effect for guests immediately.

## How the door scanner is scoped

A door person holds a `door` membership for one **event** or for one **club**. A club covers every event linked to it
(`site_events.venue_id`, set when an admin picks a venue in the CMS event form). The screen shows events that are running,
start within 24 hours, or ended in the last 3 hours, with how many guests are in. A ticket for any other event, at another
club or business, comes back as "Not for this event" without the guest's name, tier or event, and is logged against the
person who scanned it. The older `checkin_ticket()` and `verify_ticket_otp()` are untouched and stay unreachable to invited
staff. The new functions also fix a flaw in the old scanner: it admits a ticket it has just refused as expired or
code-protected (a missing `RETURN`; see `supabase/proposed/20260830_fix_checkin_ticket_early_returns.sql`).

## Developing and testing

```bash
VITE_ENABLE_ACCOUNT_ONBOARDING=true npm run dev     # see the new pages locally
npm test                                            # unit tests (rules, routing, page rendering)
PGHOST=localhost PGUSER=postgres PGPASSWORD=postgres tests/db/run.sh   # database tests
```

Do not submit sign-up or log-in forms while pointed at the production Supabase project: that creates real accounts.
