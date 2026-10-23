-- Account deletion for people who have acted (20261029100000_account_deletion_actor_fks.sql). The delete-account function deletes the caller from auth.users; until this migration any
-- door person, server or manager who ever accepted an invitation, scanned a ticket, checked a guest in, handled cash or caused an audit row was refused ("Failed to delete account"), and so
-- was an owner who created a business. What matters: each of them can be deleted; every record they touched stays (same rows, same state, same dates, same text) with only the person gone;
-- audit_log keeps actor_email; two people who are each other's counterpart (handed over / received, reported / reviewed) can be deleted together; the rules that tie a person to a state
-- were only relaxed for "the person is gone", never otherwise; nothing else points at auth.users without an on-delete rule; and running the migration again changes nothing.
begin;

create function tests.join_as(p_inviter uuid, p_inviter_email text, p_org uuid, p_email text, p_role text, p_venue uuid, p_user uuid) returns void language plpgsql as $$
declare tok text;
begin
  perform tests.login(p_inviter, p_inviter_email);
  select i.token into tok from public.invite_member(p_org, p_email, p_role, p_venue) i;
  perform tests.login(p_user, p_email);
  perform public.accept_invitation(tok);
  perform tests.logout();
end $$;
-- One cell of one row as text; '(gone)' when the row does not exist, '(null)' when the cell is empty.
create function tests.cell(p_table text, p_col text, p_id uuid) returns text language plpgsql security definer as $$
declare r text; found_row boolean;
begin
  execute format('select true, %I::text from public.%I where id = $1', p_col, p_table) into found_row, r using p_id;
  if found_row is null then return '(gone)'; end if;
  return coalesce(r, '(null)');
end $$;
-- How many rows each table the people touched holds: if a record were deleted with its author, this changes.
create function tests.kept() returns text language plpgsql security definer as $$
declare t text; n bigint; out text := '';
begin
  foreach t in array array['scan_attempts', 'audit_log', 'site_invitations', 'site_orders', 'site_table_bookings', 'guest_tickets', 'site_organizations', 'site_venues', 'site_cash_handovers',
                           'site_payment_flags', 'site_security_alerts', 'site_security_incidents', 'site_security_tasks', 'site_night_closes', 'site_vip_members'] loop
    execute format('select count(*) from public.%I', t) into n;
    out := out || t || '=' || n || ' ';
  end loop;
  return out;
end $$;
-- A fingerprint of every foreign key into auth.users and of the replaced CHECKs, to prove a second run of the migration changes nothing.
create function tests.shape() returns text language sql security definer as $$
  select md5(coalesce(string_agg(pg_get_constraintdef(c.oid) || c.conrelid::regclass::text || c.conname, '|' order by c.conrelid::regclass::text, c.conname), ''))
    from pg_constraint c
   where (c.contype = 'f' and c.confrelid = 'auth.users'::regclass) or (c.contype = 'c' and c.conname ~ '(_together|_not_own|_release_check|_decided_check)$') $$;
-- Nullability of every column that holds a person.
create function tests.nullable_actor_columns() returns text language sql security definer as $$
  select string_agg(c.conrelid::regclass::text || '.' || a.attname, ', ') from pg_constraint c join pg_attribute a on a.attrelid = c.conrelid and a.attnum = any (c.conkey)
   where c.contype = 'f' and c.confrelid = 'auth.users'::regclass and c.confdeltype = 'n' and a.attnotnull $$;

do $$
declare
  owner_u constant uuid := '00000000-0000-0000-0000-000000000d01';
  mgr constant uuid := '00000000-0000-0000-0000-000000000d02';
  srv constant uuid := '00000000-0000-0000-0000-000000000d03';
  door constant uuid := '00000000-0000-0000-0000-0000000000a1';   -- the fixtures' door person, staff@test.example
  bystander constant uuid := '00000000-0000-0000-0000-0000000000a3';   -- signed in, no role: never deleted, the "someone else" in every check
  admin_u constant uuid := '00000000-0000-0000-0000-0000000000a2';   -- the fixtures' admin: another live person to stand on the other side
  bn constant date := current_date;
  org uuid; venue uuid; ttype uuid; slot uuid; booking uuid; pay uuid;
  inv_door uuid; inv_srv uuid; inv_mgr uuid; inv_revoked uuid; tok text;
  ord uuid; ord_pending uuid; guest uuid;
  scan_ok uuid; scan_unpaid uuid; scan_missing uuid;
  audit_door uuid; audit_by uuid;
  handover uuid; flag uuid; alert_ack uuid; alert_done uuid; incident uuid; task uuid; vip uuid;
  before_counts text; shape_before text;
  r record; n int;
begin
  insert into auth.users (id, email) values (owner_u, 'owner@bye.example'), (mgr, 'mgr@bye.example'), (srv, 'srv@bye.example');

  ---------------------------------------------------------------- a business with real history: who invited whom, who scanned what
  perform tests.login(owner_u, 'owner@bye.example');
  org := public.create_organization('Goodbye Co', 'venue_owner');
  venue := public.create_org_venue(org, 'Last Call');
  perform tests.logout();
  insert into public.site_table_types (venue_id, name, max_guests, min_spend_cents, deposit_cents, inventory_count) values (venue, 'Booth', 6, 0, 10000, 5) returning id into ttype;
  insert into public.site_venue_time_slots (venue_id, day_of_week, start_time) values (venue, extract(dow from bn)::int, '22:00') returning id into slot;
  perform tests.join_as(owner_u, 'owner@bye.example', org, 'mgr@bye.example', 'manager', venue, mgr);
  perform tests.join_as(mgr, 'mgr@bye.example', org, 'srv@bye.example', 'server', venue, srv);
  perform tests.join_as(mgr, 'mgr@bye.example', org, 'staff@test.example', 'door', venue, door);
  perform tests.login(mgr, 'mgr@bye.example');
  select i.invitation_id into inv_revoked from public.invite_member(org, 'nobody@bye.example', 'server', venue) i;
  perform public.revoke_invitation(inv_revoked);
  perform tests.logout();
  select id into inv_mgr from public.site_invitations where org_id = org and email = 'mgr@bye.example';
  select id into inv_srv from public.site_invitations where org_id = org and email = 'srv@bye.example';
  select id into inv_door from public.site_invitations where org_id = org and email = 'staff@test.example';

  -- the door person scans three codes (the fixtures' Future Night is held at this club, so a door person of the club covers it)
  update public.site_events set venue_id = venue where id = '00000000-0000-0000-0000-0000000000e1';
  perform tests.login(door, 'staff@test.example');
  perform public.door_scan_ticket('T-PAID');
  perform public.door_scan_ticket('T-PENDING');
  perform public.door_scan_ticket('NO-SUCH-CODE');
  perform tests.logout();
  select id into ord from public.site_orders where ticket_code = 'T-PAID';
  select id into ord_pending from public.site_orders where ticket_code = 'T-PENDING';
  select id into scan_ok from public.scan_attempts where ticket_code_attempted = 'T-PAID';
  select id into scan_unpaid from public.scan_attempts where ticket_code_attempted = 'T-PENDING';
  select id into scan_missing from public.scan_attempts where ticket_code_attempted = 'NO-SUCH-CODE';

  -- a booking checked in at the door, with a guest ticket checked in too
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, amount_paid_cents, status, confirmation_code, checked_in_at, checked_in_by)
  values (venue, ttype, slot, bn, 'Bye Guest', 'guest@bye.example', 2, 10000, 10000, 'paid', 'BYE-1', now(), door) returning id into booking;
  insert into public.guest_tickets (booking_id, guest_name, guest_email, guest_code, checked_in_at, checked_in_by) values (booking, 'Plus One', 'plusone@bye.example', 'BYE-G1', now(), door) returning id into guest;
  insert into public.site_table_booking_club_payments (booking_id, billed_amount_cents, amount_paid_cents, payment_method, recorded_by, missing_receipt_reason) values (booking, 10000, 10000, 'cash', srv, 'seeded') returning id into pay;

  -- audit rows: one by the door person, one by the bystander (who must be left alone)
  insert into public.audit_log (actor_id, actor_email, action, entity_type, entity_id, details) values (door, 'staff@test.example', 'door.checked_in', 'order', ord::text, '{"code":"T-PAID"}') returning id into audit_door;
  insert into public.audit_log (actor_id, actor_email, action, entity_type, entity_id) values (bystander, 'rando@test.example', 'cms.viewed', 'order', ord::text) returning id into audit_by;

  -- the records whose rules tie a person to a state (resolved BY someone, received BY someone, reviewed BY someone, ...)
  insert into public.site_cash_handovers (venue_id, business_night, from_user, claimed_cents, status, received_by, received_at, counted_cents) values (venue, bn, srv, 5000, 'acknowledged', mgr, now(), 4900) returning id into handover;
  insert into public.site_payment_flags (payment_id, venue_id, raised_by, reason, status, resolved_by, resolved_at, resolution) values (pay, venue, srv, 'amount looks wrong', 'resolved', mgr, now(), 'confirmed_ok') returning id into flag;
  insert into public.site_security_alerts (venue_id, business_night, kind, location, status, raised_by, acknowledged_by, acknowledged_at) values (venue, bn, 'medical', 'Dance floor', 'acknowledged', srv, door, now()) returning id into alert_ack;
  insert into public.site_security_alerts (venue_id, business_night, kind, location, status, raised_by, acknowledged_by, acknowledged_at, resolved_by, resolved_at, escalated_by, escalated_at)
    values (venue, bn, 'fight', 'Main bar', 'resolved', srv, door, now(), mgr, now(), owner_u, now()) returning id into alert_done;
  insert into public.site_security_incidents (venue_id, business_night, kind, occurred_at, location, details, reported_by, status, reviewed_by, reviewed_at)
    values (venue, bn, 'theft', now(), 'Cloakroom', 'A jacket was taken from the cloakroom', srv, 'reviewed', mgr, now()) returning id into incident;
  insert into public.site_security_tasks (venue_id, business_night, title, assigned_to, status, created_by, closed_by, closed_at) values (venue, bn, 'Check the back door', door, 'done', mgr, srv, now()) returning id into task;
  insert into public.site_night_closes (venue_id, business_night, status, closed_by, closed_at, report, reopened_by, reopened_at) values (venue, bn, 'reopened', mgr, now(), '{}', owner_u, now());
  insert into public.site_vip_members (venue_id, name, email, credential_code, created_by, ended_at, ended_by) values (venue, 'Vera Vip', 'vera@bye.example', 'VIP-BYE-1', mgr, now(), mgr) returning id into vip;

  ---------------------------------------------------------------- the setup really involves each person (so the deletions below prove something)
  perform tests.assert_eq('the door person has scanned 3 codes', (select count(*)::int from public.scan_attempts where scanned_by = door), 3);
  perform tests.assert_eq('...checked in an order, a booking and a guest ticket', (select (select count(*) from public.site_orders where checked_in_by = door) + (select count(*) from public.site_table_bookings where checked_in_by = door)
                                                                                           + (select count(*) from public.guest_tickets where checked_in_by = door))::int, 3);
  perform tests.assert_eq('...accepted an invitation', tests.cell('site_invitations', 'accepted_by', inv_door), door::text);
  perform tests.assert_eq('...and has an audit row', tests.cell('audit_log', 'actor_id', audit_door), door::text);
  perform tests.assert_eq('the manager invited two people and revoked an invitation', (select count(*)::int from public.site_invitations where invited_by = mgr), 3);
  perform tests.assert_eq('the owner created the business', tests.cell('site_organizations', 'created_by', org), owner_u::text);
  before_counts := tests.kept();
  shape_before := tests.shape();

  ---------------------------------------------------------------- 1. the door person: everything they scanned or accepted stays, the person is gone
  delete from auth.users where id = door;
  perform tests.assert_eq('the door person is deleted', (select count(*)::int from auth.users where id = door), 0);
  perform tests.assert_eq('their three scans are still there', (select count(*)::int from public.scan_attempts where id in (scan_ok, scan_unpaid, scan_missing)), 3);
  perform tests.assert_eq('...with the outcome they had', (select string_agg(result, ',' order by result) from public.scan_attempts where id in (scan_ok, scan_unpaid, scan_missing)), 'not_found,not_paid,ok');
  perform tests.assert_eq('...and nobody named on them any more', (select count(*)::int from public.scan_attempts where id in (scan_ok, scan_unpaid, scan_missing) and scanned_by is null), 3);
  perform tests.assert_eq('the order they checked in is still checked in', tests.cell('site_orders', 'checked_in_at', ord) not in ('(null)', '(gone)'), true);
  perform tests.assert_eq('...with nobody named as the one who did it', tests.cell('site_orders', 'checked_in_by', ord), '(null)');
  perform tests.assert_eq('the booking they checked in stays checked in, nobody named', tests.cell('site_table_bookings', 'checked_in_by', booking) || '/' || (tests.cell('site_table_bookings', 'checked_in_at', booking) <> '(null)'), '(null)/true');
  perform tests.assert_eq('the guest ticket they checked in stays checked in, nobody named', tests.cell('guest_tickets', 'checked_in_by', guest) || '/' || (tests.cell('guest_tickets', 'checked_in_at', guest) <> '(null)'), '(null)/true');
  perform tests.assert_eq('the invitation they accepted is still accepted, nobody named', tests.cell('site_invitations', 'status', inv_door) || '/' || tests.cell('site_invitations', 'accepted_by', inv_door), 'accepted/(null)');
  perform tests.assert_eq('their audit row stays, with the same action', tests.cell('audit_log', 'action', audit_door), 'door.checked_in');
  perform tests.assert_eq('...its email stays (the trail keeps its meaning)', tests.cell('audit_log', 'actor_email', audit_door), 'staff@test.example');
  perform tests.assert_eq('...and nobody is named by id', tests.cell('audit_log', 'actor_id', audit_door), '(null)');
  perform tests.assert_eq('...its details stay', tests.cell('audit_log', 'details', audit_door), '{"code": "T-PAID"}');
  perform tests.assert_eq('the invitation they accepted no longer points at their (deleted) membership', tests.cell('site_invitations', 'membership_id', inv_door), '(null)');
  perform tests.assert_eq('their access to the business is gone with them', (select count(*)::int from public.site_memberships where org_id = org and user_id = door), 0);
  perform tests.assert_eq('their door-staff entry is gone with them', (select count(*)::int from public.door_staff where id = door), 0);
  perform tests.assert_eq('a task assigned to them is kept, unassigned', tests.cell('site_security_tasks', 'assigned_to', task), '(null)');
  perform tests.assert_eq('an alert they acknowledged is kept, still acknowledged', tests.cell('site_security_alerts', 'status', alert_ack) || '/' || tests.cell('site_security_alerts', 'acknowledged_by', alert_ack), 'acknowledged/(null)');
  perform tests.assert_eq('someone else''s audit row is untouched', tests.cell('audit_log', 'actor_id', audit_by), bystander::text);
  perform tests.assert_eq('the business and the club are untouched', (select count(*)::int from public.site_organizations where id = org) + (select count(*)::int from public.site_venues where id = venue), 2);

  ---------------------------------------------------------------- 2. a server and a manager TOGETHER: each is the other's counterpart on records that forbid "the same person on both sides"
  delete from auth.users where id in (srv, mgr);
  perform tests.assert_eq('both are deleted in one statement', (select count(*)::int from auth.users where id in (srv, mgr)), 0);
  perform tests.assert_eq('the cash handover stays acknowledged with its amounts', (select concat_ws('/', status, claimed_cents, counted_cents) from public.site_cash_handovers where id = handover), 'acknowledged/5000/4900');
  perform tests.assert_eq('...nobody named on either side', tests.cell('site_cash_handovers', 'from_user', handover) || '/' || tests.cell('site_cash_handovers', 'received_by', handover), '(null)/(null)');
  perform tests.assert_eq('the payment flag stays resolved, with its resolution', (select concat_ws('/', status, resolution, (resolved_at is not null)::text, coalesce(resolved_by::text, 'nobody'), coalesce(raised_by::text, 'nobody')) from public.site_payment_flags where id = flag),
                                                                                  'resolved/confirmed_ok/true/nobody/nobody');
  perform tests.assert_eq('the recorded payment stays, nobody named as the one who took it', tests.cell('site_table_booking_club_payments', 'amount_paid_cents', pay) || '/' || tests.cell('site_table_booking_club_payments', 'recorded_by', pay), '10000/(null)');
  perform tests.assert_eq('the resolved alert stays resolved', (select concat_ws('/', status, (resolved_at is not null)::text, coalesce(resolved_by::text, 'nobody'), coalesce(raised_by::text, 'nobody'), coalesce(escalated_by::text, 'nobody'), (escalated_at is not null)::text) from public.site_security_alerts where id = alert_done),
                                                                                  'resolved/true/nobody/nobody/' || owner_u::text || '/true');
  perform tests.assert_eq('the reviewed incident stays reviewed (its reporter and reviewer are both gone)', (select concat_ws('/', status, (reviewed_at is not null)::text, coalesce(reviewed_by::text, 'nobody'), coalesce(reported_by::text, 'nobody')) from public.site_security_incidents where id = incident),
                                                                                  'reviewed/true/nobody/nobody');
  perform tests.assert_eq('the closed task stays done', (select concat_ws('/', status, (closed_at is not null)::text, coalesce(closed_by::text, 'nobody'), coalesce(created_by::text, 'nobody')) from public.site_security_tasks where id = task), 'done/true/nobody/nobody');
  perform tests.assert_eq('the VIP membership stays ended', (select concat_ws('/', (ended_at is not null)::text, coalesce(ended_by::text, 'nobody'), coalesce(created_by::text, 'nobody')) from public.site_vip_members where id = vip), 'true/nobody/nobody');
  perform tests.assert_eq('the reopened night stays reopened', (select concat_ws('/', status, (reopened_at is not null)::text, coalesce(closed_by::text, 'nobody')) from public.site_night_closes where venue_id = venue and business_night = bn), 'reopened/true/nobody');
  perform tests.assert_eq('the three invitations the manager sent stay, nobody named as the sender', (select count(*)::int from public.site_invitations where org_id = org and invited_by is null), 3);
  perform tests.assert_eq('...and the revoked one is still revoked', tests.cell('site_invitations', 'status', inv_revoked) || '/' || tests.cell('site_invitations', 'revoked_by', inv_revoked), 'revoked/(null)');

  ---------------------------------------------------------------- 3. the owner who created the business
  delete from auth.users where id = owner_u;
  perform tests.assert_eq('the owner is deleted', (select count(*)::int from auth.users where id = owner_u), 0);
  perform tests.assert_eq('the business is still there, nobody named as its creator', tests.cell('site_organizations', 'name', org) || '/' || tests.cell('site_organizations', 'created_by', org), 'Goodbye Co/(null)');
  perform tests.assert_eq('the invitation that brought the manager in is still there', tests.cell('site_invitations', 'status', inv_mgr) || '/' || tests.cell('site_invitations', 'invited_by', inv_mgr) || '/' || tests.cell('site_invitations', 'accepted_by', inv_mgr), 'accepted/(null)/(null)');
  perform tests.assert_eq('the alert they escalated stays escalated', tests.cell('site_security_alerts', 'escalated_by', alert_done) || '/' || (tests.cell('site_security_alerts', 'escalated_at', alert_done) <> '(null)'), '(null)/true');

  ---------------------------------------------------------------- tables that only exist once the later branches are in (table blocks, concessions): skipped until then
  if to_regclass('public.site_table_blocks') is not null and to_regclass('public.site_concessions') is not null then
    declare late constant uuid := '00000000-0000-0000-0000-000000000d09'; blk uuid; conc uuid;
    begin
      insert into auth.users (id, email) values (late, 'late@bye.example');
      insert into public.site_table_blocks (venue_id, table_type_id, time_slot_id, booking_date, kind, reason, created_by, released_at, released_by) values (venue, ttype, slot, bn, 'unavailable', 'kept free for a friend', late, now(), late) returning id into blk;
      insert into public.site_concessions (venue_id, booking_id, kind, amount_cents, reason, requested_role, status, business_night, requested_by, decided_by, decided_role, decided_at)
        values (venue, booking, 'discount', 500, 'regular guest', 'server', 'applied', bn, late, late, 'manager', now()) returning id into conc;
      delete from auth.users where id = late;
      perform tests.assert_eq('a table hold they released stays released, nobody named', (select concat_ws('/', (released_at is not null)::text, coalesce(released_by::text, 'nobody'), coalesce(created_by::text, 'nobody')) from public.site_table_blocks where id = blk), 'true/nobody/nobody');
      perform tests.assert_eq('a concession they asked for and decided stays decided by a manager, nobody named', (select concat_ws('/', status, decided_role, coalesce(decided_by::text, 'nobody'), coalesce(requested_by::text, 'nobody')) from public.site_concessions where id = conc), 'applied/manager/nobody/nobody');
    end;
  end if;

  ---------------------------------------------------------------- nothing was lost along the way
  perform tests.assert_eq('every table the people touched holds exactly the rows it held before anyone was deleted', tests.kept(), before_counts);
  perform tests.assert_eq('the other person''s data (the bystander) is untouched', (select count(*)::int from auth.users where id = bystander), 1);
  perform tests.assert_eq('no row in the whole database still names a person who is gone', (select count(*)::int from public.scan_attempts where scanned_by in (door, srv, mgr, owner_u))
                                                                                           + (select count(*)::int from public.audit_log where actor_id in (door, srv, mgr, owner_u))
                                                                                           + (select count(*)::int from public.site_invitations where invited_by in (door, srv, mgr, owner_u) or accepted_by in (door, srv, mgr, owner_u) or revoked_by in (door, srv, mgr, owner_u)), 0);

  ---------------------------------------------------------------- the rules were relaxed ONLY for "the person is gone": the same mistakes are still refused while the people are alive
  perform tests.assert_raises('a handover cannot be received by the person who handed it in',
    format($q$insert into public.site_cash_handovers (venue_id, business_night, from_user, claimed_cents, status, received_by, received_at, counted_cents) values (%L, %L, %L, 100, 'acknowledged', %L, now(), 100)$q$, venue, bn, bystander, bystander), 'site_cash_handovers_not_own');
  perform tests.assert_raises('an acknowledged handover still needs the time it was received',
    format($q$insert into public.site_cash_handovers (venue_id, business_night, from_user, claimed_cents, status, received_by, counted_cents) values (%L, %L, %L, 100, 'acknowledged', %L, 100)$q$, venue, bn, bystander, admin_u), 'site_cash_handovers_received_together');
  perform tests.assert_raises('a submitted handover cannot already have a receiver',
    format($q$insert into public.site_cash_handovers (venue_id, business_night, from_user, claimed_cents, status, received_by) values (%L, %L, %L, 100, 'submitted', %L)$q$, venue, bn, bystander, admin_u), 'site_cash_handovers_received_together');
  perform tests.assert_raises('a flag is not resolved without the time it was resolved',
    format($q$insert into public.site_payment_flags (payment_id, venue_id, raised_by, reason, status, resolved_by, resolution) values (%L, %L, %L, 'not resolved yet', 'resolved', %L, 'other')$q$, pay, venue, bystander, bystander), 'site_payment_flags_resolved_together');
  perform tests.assert_raises('an open flag cannot carry a resolver',
    format($q$insert into public.site_payment_flags (payment_id, venue_id, raised_by, reason, status, resolved_by) values (%L, %L, %L, 'still open flag', 'open', %L)$q$, pay, venue, bystander, bystander), 'site_payment_flags_resolved_together');
  perform tests.assert_raises('an alert is not resolved without the time it was resolved',
    format($q$insert into public.site_security_alerts (venue_id, business_night, kind, location, status, resolved_by) values (%L, %L, 'fight', 'Door', 'resolved', %L)$q$, venue, bn, bystander), 'site_security_alerts_resolved_together');
  perform tests.assert_raises('an open alert cannot carry a resolver',
    format($q$insert into public.site_security_alerts (venue_id, business_night, kind, location, status, resolved_by, resolved_at) values (%L, %L, 'fight', 'Door', 'open', %L, now())$q$, venue, bn, bystander), 'site_security_alerts_resolved_together');
  perform tests.assert_raises('an acknowledged alert still needs the time it was acknowledged',
    format($q$insert into public.site_security_alerts (venue_id, business_night, kind, location, status, acknowledged_by) values (%L, %L, 'fight', 'Door', 'acknowledged', %L)$q$, venue, bn, bystander), 'site_security_alerts_taken_together');
  perform tests.assert_raises('nobody reviews their own incident report',
    format($q$insert into public.site_security_incidents (venue_id, business_night, kind, occurred_at, location, details, reported_by, status, reviewed_by, reviewed_at) values (%L, %L, 'theft', now(), 'Cloakroom', 'A coat was taken from the cloakroom', %L, 'reviewed', %L, now())$q$, venue, bn, bystander, bystander), 'site_security_incidents_not_own_review');
  perform tests.assert_raises('an incident is not reviewed without the time of the review',
    format($q$insert into public.site_security_incidents (venue_id, business_night, kind, occurred_at, location, details, status, reviewed_by) values (%L, %L, 'theft', now(), 'Cloakroom', 'A coat was taken from the cloakroom', 'reviewed', %L)$q$, venue, bn, bystander), 'site_security_incidents_reviewed_together');
  perform tests.assert_raises('a task is not done without a time it was closed',
    format($q$insert into public.site_security_tasks (venue_id, business_night, title, status) values (%L, %L, 'Check the fire exit', 'done')$q$, venue, bn), 'site_security_tasks_closed_together');
  perform tests.assert_raises('an open task cannot carry a closer',
    format($q$insert into public.site_security_tasks (venue_id, business_night, title, status, closed_by, closed_at) values (%L, %L, 'Check the fire exit', 'open', %L, now())$q$, venue, bn, bystander), 'site_security_tasks_closed_together');
  perform tests.assert_raises('a night is not reopened without the time it was reopened',
    format($q$insert into public.site_night_closes (venue_id, business_night, status, closed_at, report, reopened_by) values (%L, %L, 'reopened', now(), '{}', %L)$q$, venue, bn + 1, bystander), 'site_night_closes_reopened_together');
  perform tests.assert_raises('a closed night cannot carry a person who reopened it',
    format($q$insert into public.site_night_closes (venue_id, business_night, status, closed_at, report, reopened_by, reopened_at) values (%L, %L, 'closed', now(), '{}', %L, now())$q$, venue, bn + 1, bystander), 'site_night_closes_reopened_together');
  perform tests.assert_raises('a VIP membership is not ended by someone without a time',
    format($q$insert into public.site_vip_members (venue_id, name, email, credential_code, ended_by) values (%L, 'Walt Vip', 'walt@bye.example', 'VIP-BYE-2', %L)$q$, venue, bystander), 'site_vip_ended_together');

  ---------------------------------------------------------------- nothing else can block a deletion
  perform tests.assert_eq('no foreign key into auth.users, or into anything deleted together with the person, is left without an on-delete rule', (
    with recursive gone(rel) as (select 'auth.users'::regclass union select c.conrelid from pg_constraint c join gone on c.confrelid = gone.rel where c.contype = 'f' and c.confdeltype = 'c')
    select coalesce(string_agg(c.conrelid::regclass::text || '.' || a.attname, ', '), 'none')
      from pg_constraint c join gone on c.confrelid = gone.rel join pg_attribute a on a.attrelid = c.conrelid and a.attnum = any (c.conkey) where c.contype = 'f' and c.confdeltype in ('a', 'r')), 'none');
  perform tests.assert_eq('every column that is set to null on deletion can be null', coalesce(tests.nullable_actor_columns(), 'none'), 'none');
  perform tests.assert_eq('the five columns that were reported are all set-null now', (select count(*)::int from pg_constraint c join pg_attribute a on a.attrelid = c.conrelid and a.attnum = any (c.conkey)
    where c.contype = 'f' and c.confrelid = 'auth.users'::regclass and c.confdeltype = 'n'
      and c.conrelid::regclass::text || '.' || a.attname in ('site_orders.checked_in_by', 'guest_tickets.checked_in_by', 'scan_attempts.scanned_by', 'audit_log.actor_id', 'site_invitations.accepted_by')), 5);
end $$;

---------------------------------------------------------------- running the migration again changes nothing (it is safe to repeat)
create temp table shape_run as select tests.shape() as before;
\i supabase/migrations/20261029100000_account_deletion_actor_fks.sql
select tests.assert_eq('the migration run a second time changes no constraint', tests.shape(), (select before from shape_run));

rollback;
