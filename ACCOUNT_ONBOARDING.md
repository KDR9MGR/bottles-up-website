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
| Tables & Bookings (owner; a manager's Floor shows the same for their club; read only): each venue's reservations night by night with the guest, table, party size, status (confirmed, awaiting payment, cancelled...), contact details, confirmation code and whether they have arrived; a booking after midnight is counted on the night before | `/w/<membership>/tables` (owner) and `/floor` (manager), `src/account/workspace/BookingsSection.tsx`, rules in `src/lib/bookingsView.ts`, DB `list_venue_bookings`, `booking_night` |
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
   - `supabase/migrations/20261012100000_cancel_business.sql` (lets a person cancel a business they added by mistake; one new function, needs only the tenancy and onboarding migrations above)
   - `supabase/migrations/20261013100000_organizer_events.sql` (the organizer's own draft events; new functions only. Needs the tenancy migration, `site_events` with its `organizer_name` column, and `audit_log`; it does not use the venue setup helpers)
   - `supabase/migrations/20261014100000_table_servers.sql` (giving a booking to a server; one new table and new functions. Needs the tenancy migration, the venue bookings migration for `booking_night`, the venue setup migration for `require_venue_editor`, and `site_table_bookings`, `site_venue_time_slots`, `site_table_types` and `audit_log`)
   - `supabase/migrations/20261014110000_service_requests.sql` (service requests from a table; one new table and new functions. Needs the previous one, for `desk_log`, `booking_venue` and the server link)
   - `supabase/migrations/20261014120000_desk_orders.sql` and `supabase/migrations/20261014130000_desk_payments.sql` (bottle orders, payments and the manager's Tonight numbers for the membership roles; new functions and two storage policies, no new tables. **These need tables and columns that exist only in production** (the money columns of a booking and of a bottle line, the club payments table, the `club-payment-receipts` bucket): on a database that lacks them they stop with a message naming what is missing, and the fix is `supabase db pull` first. Read from production on 14 Oct 2026 with `supabase/audit/06_server_desk_definitions.sql`.)

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
  an event to be invited to; organizers can now create draft events (below), but inviting door staff to one is not built.
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
  manager's own screens are placeholders except Floor (the club's bookings), so only the owner's "My Venues" page exposes the
  editors today.
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

## Leaving onboarding, and cancelling a business added by mistake

"Back" on a business's onboarding page goes to the workspace list (`/workspaces`), **not** to `/home`: Home sends a person who
holds exactly one unfinished business straight back to its onboarding page, which made the page impossible to leave. The
workspace list always shows the personal account first. "Add your business" goes back to the workspace list, or to the
personal account when the person has no workspace yet (Home would send them straight back to adding one).

A business that has not been verified (not submitted, or sent back for more information) shows **Cancel this business** at the
bottom of its onboarding page, behind a confirmation. It calls `cancel_business(p_org)`, which checks in the database that the
caller is the owner or organizer of that business and then deletes the business with its details, draft venues, draft events,
pending venue requests and unaccepted invitations. It is recorded in `audit_log` (`business.cancelled`, with the name, kind and
state), because the verification history goes with the business. It refuses, with a plain sentence each:

- a business under review or verified (only the BottlesUp team handles those, and the page says to contact them),
- a business that still has another active team member (their access would vanish without notice),
- a business with a live venue or a published event,
- a draft venue or event that already has bookings or orders pointing at it (the delete would fail on a foreign key).

After cancelling, the person's sign-up intent in their account metadata is set back to personal, so signing in does not push
them to create another business. Files already uploaded to the business's storage folder are not deleted.

## How organizer events are protected

An event organizer's Home and Events sections list the business's events and let it **create** one, **change** a draft and **remove**
a draft. The organizer gets three database functions (`list_org_events`, `save_org_event`, `remove_org_event`) instead of write access to
`site_events`. Each checks the person holds the organizer role in THAT business (an organization of kind `organizer`), and looks the event
up inside that business, so another business's event, or one made in the CMS, is never reachable.

- **An organizer cannot publish.** Events are always created as drafts, the field list has no `status`, `org_id`, `slug` or
  organizer block, and an unknown field is refused. The public site only shows published events (RLS), so a draft is private until the
  BottlesUp team publishes it in the CMS, which also sets up its ticket tiers.
- **A published event is out of reach.** It cannot be changed or removed here, because tickets may have been sold. The screen says to
  contact BottlesUp.
- Fields: title, description, venue or place name, address, start, end, category, capacity and a cover photo. Times are sent with their
  time zone (the database refuses a time without one, because it would guess), and shown back in the device's zone. A draft event that
  already has an order cannot be removed. A business can hold 200 events.
- Every change is recorded in `audit_log` (`org_event.created`, `.updated`, `.removed`) with who and which business.
- **Not built, and not guessed at:** ticket tiers, linking an event to a venue and the agreement with it, publishing by the organizer,
  and the other event states from the brief (section 7). Whether a verified organizer may publish its own events is a client decision.

## How a booking is given to a server, and how service requests work

The brief (sections 12, 13 and 17) has a manager give tables to servers, a server see their own tables, and the staff deal with requests from
a table (water, ice, the bill). Two migrations add it; the staff area of the old site does not use them.

- **A booking has at most one server** (`site_booking_servers`, keyed by the booking). Individual tables do not exist yet (inventory is a count
  per table type), so what is given out is the **booking**; the brief says "tables" and the client should confirm this is what they mean.
  `assign_booking_server`, `unassign_booking_server` and `list_venue_booking_servers` are for the owner of the business and the manager of THAT
  club (the venue setup check). The booking must be paid; the person must be an active `server` of the same club (not door, not another club's
  server, not someone whose access was revoked, ended or whose shift is over). A server whose access ends later shows as unavailable so the
  manager can see a table that is nobody's in practice.
- **A server's own tables:** `my_assigned_tables(night)` returns the paid bookings given to the caller's current server memberships for one
  business night (a slot before 06:00 belongs to the night before): the table, arrival time, party, lead guest's name, confirmation code and
  whether they have arrived. **No email or phone.** Anyone without a server membership gets an empty list.
- **Service requests** (`site_service_requests`): `create_service_request`, `list_service_requests`, `update_service_request`. Staff of the
  club only (a server, the manager, the owner). Kinds: assistance, water/ice/mixers, order question, bill request, table issue. Statuses: New,
  Acknowledged, In progress, Completed, Escalated, Cancelled. A request goes to the table's server if the booking has one.
  - A server sees their own tables' requests and those of tables nobody has; the manager and owner see all of them. The oldest open request is first.
  - **The first to acknowledge owns it**: a second server is told someone else has it (the request row is locked, and a script in
    `concurrency.sh` presses Acknowledge twice at once). Doing the same thing twice is not an error and records nothing.
  - **Asking for the same thing twice while it is open is one request** (a unique index, so two taps at once cannot both succeed).
  - Escalating and cancelling need a reason. Only a manager hands a request to someone else (it goes back to New for that person). A server
    cannot touch an escalated request.
  - Every change is recorded in `audit_log` (`booking.server_*`, `service_request.*`) with who did it.
- **Not built, and not guessed at:** requests made by the guest from the customer app (the column `source` allows `guest`; nothing creates one),
  billing for a charged item (that goes through an order), and anything that needs production-only columns: what was paid, a table's bottle orders
  and their service state. Those wait for `supabase db pull` (or `supabase/audit/06_server_desk_definitions.sql`).

## How table orders, payments and Tonight work (for servers, verifiers, managers and owners)

Brief sections 13 to 15 and 6. Two migrations (`20261014120000_desk_orders.sql`, `20261014130000_desk_payments.sql`) add functions that do what the website's
own staff functions do (`list_my_bottle_orders`, `update_bottle_service_status`, `record_club_payment`, `manager_verify_club_payment`, ...) **for the membership
roles**. The old ones are left exactly as they are: they authorize through the global `door_staff` and `cms_admins` tables, so an invited server, verifier or
club manager is refused by them. Read in production on 14 Oct 2026, the old ones also let *any* `door_staff` row record a payment for *any* booking at *any* club
(`door_staff.can_record_payments` is never checked), let the person who recorded a payment verify it, overwrite an earlier verification, and file a receipt under
any path. These do not.

- **Who stands where.** `desk_booking_level(booking)` answers only for the caller: `manager` (owns the business or manages that club), `server` (a current
  server role at that club **and** the booking was given to them), `verifier` (a current verifier role at that club), or nothing (also for a booking that
  does not exist, so ids cannot be probed). A person whose access ended, or whose shift is over, is nothing.
- **Orders.** `desk_orders(club, night)`: the night's bottle lines, oldest unfinished first, delivered last (a manager or owner sees the whole club, a server only
  their own tables; cancelled lines, ones still being paid online and closed-out tables are left out; at most 1000). `desk_booking_orders(booking)` is one table's
  sheet, cancelled lines included with their reason. `desk_set_service_status(line, status)` moves one line among the five states the database allows
  (`awaiting_prep`, `preparing`, `ready`, `picked_up`, `served`; the app says New / Preparing / Ready / On the way / Delivered). It answers true when it changed
  and false when it already was so (a repeated tap writes and records nothing). A server cannot take a delivered item back; an item to be paid at the venue
  cannot be delivered until the table's balance is zero **and** a payment was recorded for it; a cancelled line, a closed-out table and a line still being
  paid online cannot be moved.
- **Payments.** `desk_record_payment(...)`: the owner, the manager, or the server the booking was given to. A **server must attach a receipt photo**; a manager
  may instead write why there is none (cash without a printed receipt). The photo's path must start with the booking's id (`<booking id>/<file>`), which is
  what ties it to the booking and decides who may open it. The booking's paid total goes up by what was collected, never past its total (as the old function
  does); the payment keeps the real figure. The same receipt sent again, or the same no-receipt entry within a minute, answers `duplicate: true` and writes
  nothing; a till receipt number or photo already used at that club is refused. Only a confirmed booking that has not been closed out takes a payment.
  The guest's email is stored if given and never returned by these functions or written to the audit log.
- **Checking.** `desk_pending_verifications(club)` is the owner's, manager's and verifier's queue: unchecked payments and disputed ones (those first, even if
  they were checked earlier), oldest first, at most 300. `desk_verify_payment(payment, note)`: **never the person who recorded it, never twice, and not once the
  customer has answered**. A photo alone does not verify anything: a payment reads "Recorded - verification pending" until someone else checks it.
  Not built: flagging a payment, settling a dispute, cash handover from server to cashier, corrections and refunds (these wait for client decisions).
- **Receipts in storage.** Two policies on the private `club-payment-receipts` bucket: a manager or the table's server may add a photo under their booking's
  id, and the manager, owner, that table's server and a verifier may read it. The old policies (any `door_staff` or CMS admin, any club) are untouched.
- **Tonight.** `desk_tonight(club, night)` (owner/manager only): tables, guests, arrived, tables without a server, tables with a balance and how much, items
  new / in progress / delivered, then club-wide payments to check, disputed payments, closings asked for, open service requests. `desk_table_status(club, night)`
  is one line per confirmed booking (what is due, items still to deliver, payments recorded and unchecked, closed out, closing asked for) to lay over the lists
  the app already has; a server gets only their tables.
- **Tests.** `140` (orders) and `150` (payments, checking, Tonight, receipts) in `tests/db`, plus four races in `concurrency.sh` (a receipt sent twice at once, two
  verifiers on one payment, one order tapped twice, a payment and a delivery at the same moment). The production-only columns come from
  `tests/db/prod_shapes/` (see its README). A mutation check of these two migrations (`tests/db/tools/mutate_migrations.py`) killed 137 of 140 changes; the
  three left are equivalent or defensive: an extra role filter, `<> 'paid'` where `= 'due_at_venue'` is the same once unpaid lines are refused, and the lock on
  the bottle line itself (the booking lock already serializes every writer in this file; it only matters against the old production function).

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
