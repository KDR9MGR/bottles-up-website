-- Bottle signs (20261116100000_bottle_signs.sql). What matters: every club starts with signs OFF and nothing existing changes; only the owner or manager of a club changes its sign
-- settings and which bottles may carry a sign; a sign is one line of plain text of 1 to 40 characters on one bottle line, set or cleared only by that club's manager or owner or the
-- table's own server, only while the item has not gone out, and only on a bottle the club's mode allows; typing the same words again changes nothing; with review on a server's sign
-- waits for a manager (never reviewed by its own author), is declined with a reason or approved, and a waiting or declined sign STOPS the order from being prepared or delivered on
-- every path (the app's functions, partial delivery, a plain update), while a review that is off blocks nothing; signs are read only by who may see the order; every change is attributed.
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
create function tests.mkbooking(p_venue uuid, p_type uuid, p_slot uuid, p_date date, p_name text) returns uuid language sql security definer as $$
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, amount_paid_cents, status, confirmation_code)
  values (p_venue, p_type, p_slot, p_date, p_name, lower(replace(p_name, ' ', '')) || '@test.example', 2, 1000, 1000, 'paid', upper(replace(p_name, ' ', '-')))
  returning id $$;
create function tests.mkbottle(p_venue uuid, p_name text) returns uuid language sql security definer as $$
  insert into public.site_bottles (venue_id, name, size, price_cents, category) values (p_venue, p_name, '750ml', 1000, 'Spirits') returning id $$;
create function tests.mkline(p_booking uuid, p_name text, p_bottle uuid, p_svc text default 'awaiting_prep') returns uuid language sql security definer as $$
  insert into public.site_table_booking_bottles (booking_id, bottle_id, bottle_name, size, unit_price_cents, quantity, line_total_cents, payment_status, service_status)
  values (p_booking, p_bottle, p_name, '750ml', 1000, 2, 2000, 'paid', p_svc) returning id $$;
-- Sets a sign as someone: 'changed/status' or 'ERROR: <the sentence>'.
create function tests.sign(p_user uuid, p_email text, p_line uuid, p_text text) returns text language plpgsql as $$
declare j jsonb;
begin
  perform tests.login(p_user, p_email);
  j := public.desk_set_bottle_sign(p_line, p_text);
  perform tests.logout();
  return concat_ws('/', j ->> 'changed', coalesce(j ->> 'sign_status', '-'));
exception when others then
  perform tests.logout();
  return 'ERROR: ' || sqlerrm;
end $$;
create function tests.review(p_user uuid, p_email text, p_line uuid, p_decision text, p_note text default null) returns text language plpgsql as $$
declare j jsonb;
begin
  perform tests.login(p_user, p_email);
  j := public.desk_review_bottle_sign(p_line, p_decision, p_note);
  perform tests.logout();
  return concat_ws('/', j ->> 'changed', j ->> 'sign_status');
exception when others then
  perform tests.logout();
  return 'ERROR: ' || sqlerrm;
end $$;
create function tests.try(p_user uuid, p_email text, p_sql text) returns text language plpgsql as $$
declare r text;
begin
  perform tests.login(p_user, p_email);
  execute p_sql into r;
  perform tests.logout();
  return coalesce(r, 'ok');
exception when others then
  perform tests.logout();
  return 'ERROR: ' || sqlerrm;
end $$;
create function tests.stored(p_line uuid) returns text language sql security definer as $$
  select concat_ws('|', coalesce(sign_text, '-'), coalesce(sign_status, '-'), coalesce(sign_review_note, '-'), case when sign_set_by is null then 'nobody' else 'someone' end) from public.site_table_booking_bottles where id = p_line $$;
create function tests.svc(p_line uuid) returns text language sql security definer as $$ select service_status from public.site_table_booking_bottles where id = p_line $$;
create function tests.audits(p_action text) returns bigint language sql security definer as $$ select count(*) from public.audit_log where action = p_action $$;
create function tests.settings(p_user uuid, p_email text, p_venue uuid) returns jsonb language plpgsql as $$
declare j jsonb;
begin
  perform tests.login(p_user, p_email);
  j := public.venue_sign_settings(p_venue);
  perform tests.logout();
  return j;
exception when others then
  perform tests.logout();
  return jsonb_build_object('error', sqlerrm);
end $$;
create function tests.line_signs(p_user uuid, p_email text, p_lines uuid[]) returns text language plpgsql as $$
declare r text;
begin
  perform tests.login(p_user, p_email);
  select coalesce(string_agg(concat_ws('=', s.line_id::text, coalesce(s.sign_text, '-'), coalesce(s.sign_status, '-'), s.can_set::text, s.review_required::text), ' ; ' order by s.line_id::text), '(none)') into r from public.desk_line_signs(p_lines) s;
  perform tests.logout();
  return r;
exception when others then
  perform tests.logout();
  return 'ERROR: ' || sqlerrm;
end $$;

do $$
declare
  owner_u constant uuid := '00000000-0000-0000-0000-0000000a10d1';
  mgr_a constant uuid := '00000000-0000-0000-0000-0000000a10d2';
  srv_1 constant uuid := '00000000-0000-0000-0000-0000000a10d3';
  srv_2 constant uuid := '00000000-0000-0000-0000-0000000a10d4';
  door_u constant uuid := '00000000-0000-0000-0000-0000000a10d5';
  mgr_b constant uuid := '00000000-0000-0000-0000-0000000a10d6';
  ver_u constant uuid := '00000000-0000-0000-0000-0000000a10d7';
  rando constant uuid := '00000000-0000-0000-0000-0000000a10d8';
  org uuid; venue_a uuid; venue_b uuid; t_a uuid; t_b uuid; s_a uuid; s_b uuid; m_s1 uuid;
  b_one uuid; b_two uuid; b_b uuid; b_closed uuid;
  bot_patron uuid; bot_goose uuid; bot_other uuid;
  l_patron uuid; l_goose uuid; l_ready uuid; l_picked uuid; l_served uuid; l_canc uuid; l_two uuid; l_b uuid; l_nobottle uuid; l_closed uuid;
  night date := current_date;
  r text; j jsonb; n bigint; n2 bigint; long40 text := repeat('x', 40);
begin
  insert into auth.users (id, email) values (owner_u, 'owner@sg.example'), (mgr_a, 'mgra@sg.example'), (srv_1, 'srv1@sg.example'), (srv_2, 'srv2@sg.example'),
    (door_u, 'door@sg.example'), (mgr_b, 'mgrb@sg.example'), (ver_u, 'ver@sg.example'), (rando, 'rando@sg.example') on conflict do nothing;
  perform tests.login(owner_u, 'owner@sg.example');
  org := public.create_organization('Sign Co', 'venue_owner');
  venue_a := public.create_org_venue(org, 'Club A');
  venue_b := public.create_org_venue(org, 'Club B');
  perform tests.logout();
  perform tests.join_as(owner_u, 'owner@sg.example', org, 'mgra@sg.example', 'manager', venue_a, mgr_a);
  perform tests.join_as(owner_u, 'owner@sg.example', org, 'mgrb@sg.example', 'manager', venue_b, mgr_b);
  perform tests.join_as(mgr_a, 'mgra@sg.example', org, 'srv1@sg.example', 'server', venue_a, srv_1);
  perform tests.join_as(mgr_a, 'mgra@sg.example', org, 'srv2@sg.example', 'server', venue_a, srv_2);
  perform tests.join_as(mgr_a, 'mgra@sg.example', org, 'door@sg.example', 'door', venue_a, door_u);
  perform tests.join_as(mgr_a, 'mgra@sg.example', org, 'ver@sg.example', 'verifier', venue_a, ver_u);

  insert into public.site_table_types (venue_id, name, max_guests, min_spend_cents, deposit_cents, inventory_count) values (venue_a, 'Booth', 6, 0, 0, 5) returning id into t_a;
  insert into public.site_table_types (venue_id, name, max_guests, min_spend_cents, deposit_cents, inventory_count) values (venue_b, 'Terrace', 4, 0, 0, 5) returning id into t_b;
  insert into public.site_venue_time_slots (venue_id, day_of_week, start_time) values (venue_a, extract(dow from night)::int, '21:00') returning id into s_a;
  insert into public.site_venue_time_slots (venue_id, day_of_week, start_time) values (venue_b, extract(dow from night)::int, '21:00') returning id into s_b;
  b_one := tests.mkbooking(venue_a, t_a, s_a, night, 'Table One');
  b_two := tests.mkbooking(venue_a, t_a, s_a, night, 'Table Two');
  b_closed := tests.mkbooking(venue_a, t_a, s_a, night, 'Closed Table');
  b_b := tests.mkbooking(venue_b, t_b, s_b, night, 'Other Club');
  select m.id into m_s1 from public.site_memberships m where m.user_id = srv_1 and m.role = 'server';
  insert into public.site_booking_servers (booking_id, membership_id, assigned_by) values (b_one, m_s1, mgr_a);   -- Table One is srv_1's; Table Two is nobody's
  update public.site_table_bookings set reconciled_at = now() where id = b_closed;

  bot_patron := tests.mkbottle(venue_a, 'Patron');
  bot_goose := tests.mkbottle(venue_a, 'Grey Goose');
  bot_other := tests.mkbottle(venue_b, 'Other club bottle');
  l_patron := tests.mkline(b_one, 'Patron', bot_patron);
  l_goose := tests.mkline(b_one, 'Grey Goose', bot_goose);
  l_ready := tests.mkline(b_one, 'Patron', bot_patron, 'ready');
  l_picked := tests.mkline(b_one, 'Patron', bot_patron, 'picked_up');
  l_served := tests.mkline(b_one, 'Patron', bot_patron, 'served');
  l_canc := tests.mkline(b_one, 'Cancelled', bot_patron);
  update public.site_table_booking_bottles set cancelled_at = now() where id = l_canc;
  l_nobottle := tests.mkline(b_one, 'Deleted from the menu', null);
  l_two := tests.mkline(b_two, 'Patron', bot_patron);
  l_b := tests.mkline(b_b, 'Other club bottle', bot_other);
  l_closed := tests.mkline(b_closed, 'Closed table bottle', bot_patron);

  ---------------------------------------------------------------- nothing changes until a club switches signs on
  perform tests.assert_eq('every club starts with signs off and no review', (select string_agg(sign_mode || '/' || sign_review::text, ',' order by name) from public.site_venues where id in (venue_a, venue_b)), 'off/false,off/false');
  perform tests.assert_eq('no bottle is a sign bottle and no order carries a sign', (select count(*) from public.site_bottles where sign_eligible) + (select count(*) from public.site_table_booking_bottles where sign_text is not null or sign_status is not null), 0::bigint);
  perform tests.assert_eq('a deleted account does not take the line with it: the author reference is set to null', (select confdeltype::text from pg_constraint where conrelid = 'public.site_table_booking_bottles'::regclass and conkey = array[(select attnum from pg_attribute where attrelid = 'public.site_table_booking_bottles'::regclass and attname = 'sign_set_by')]), 'n');
  perform tests.assert_raises('the table itself refuses a sign with no state', format($q$update public.site_table_booking_bottles set sign_text = 'x' where id = %L$q$, l_goose), 'site_tbb_sign_together');
  perform tests.assert_raises('...a state with no sign', format($q$update public.site_table_booking_bottles set sign_status = 'approved' where id = %L$q$, l_goose), 'site_tbb_sign_together');
  perform tests.assert_raises('...a state that does not exist', format($q$update public.site_table_booking_bottles set sign_text = 'x', sign_status = 'maybe' where id = %L$q$, l_goose), 'site_tbb_sign_status_check');
  perform tests.assert_raises('...a sign over 40 characters', format($q$update public.site_table_booking_bottles set sign_text = %L, sign_status = 'approved' where id = %L$q$, repeat('x', 41), l_goose), 'site_tbb_sign_text_check');
  perform tests.assert_raises('...a sign with a new line in it', format($q$update public.site_table_booking_bottles set sign_text = %L, sign_status = 'approved' where id = %L$q$, E'a\nb', l_goose), 'site_tbb_sign_text_check');
  perform tests.assert_raises('...an empty sign', format($q$update public.site_table_booking_bottles set sign_text = '', sign_status = 'approved' where id = %L$q$, l_goose), 'site_tbb_sign_text_check');
  perform tests.assert_raises('...a review note over 200 characters', format($q$update public.site_table_booking_bottles set sign_review_note = %L where id = %L$q$, repeat('z', 201), l_goose), 'site_tbb_sign_note_check');
  perform tests.assert_raises('a venue cannot have a sign mode that does not exist', format($q$update public.site_venues set sign_mode = 'sometimes' where id = %L$q$, venue_a), 'site_venues_sign_mode_check');
  perform tests.assert_true('the gate is a trigger on the lines table', exists (select 1 from pg_trigger where tgname = 'site_table_booking_bottles_sign_gate' and tgrelid = 'public.site_table_booking_bottles'::regclass));

  ---------------------------------------------------------------- the club's settings: who reads them
  j := tests.settings(mgr_a, 'mgra@sg.example', venue_a);
  perform tests.assert_eq('the manager reads them: off, no review, the club''s own two bottles and not the other club''s', concat_ws('/', j ->> 'mode', j ->> 'review_required', jsonb_array_length(j -> 'bottles'), j #>> '{bottles,0,name}', j #>> '{bottles,1,name}', j #>> '{bottles,0,sign_eligible}'), 'off/false/2/Grey Goose/Patron/false');
  perform tests.assert_eq('the owner reads them', tests.settings(owner_u, 'owner@sg.example', venue_a) ->> 'mode', 'off');
  perform tests.assert_eq('a server does not', tests.settings(srv_1, 'srv1@sg.example', venue_a) ->> 'error', 'not allowed');
  perform tests.assert_eq('a verifier does not', tests.settings(ver_u, 'ver@sg.example', venue_a) ->> 'error', 'not allowed');
  perform tests.assert_eq('the door does not', tests.settings(door_u, 'door@sg.example', venue_a) ->> 'error', 'not allowed');
  perform tests.assert_eq('another club''s manager does not', tests.settings(mgr_b, 'mgrb@sg.example', venue_a) ->> 'error', 'not allowed');
  perform tests.assert_eq('a stranger does not', tests.settings(rando, 'rando@sg.example', venue_a) ->> 'error', 'not allowed');
  perform tests.login_anon();
  perform tests.assert_raises('a visitor cannot', format('select public.venue_sign_settings(%L)', venue_a), 'permission denied');
  perform tests.logout();

  ---------------------------------------------------------------- the club's settings: who changes them, and what
  perform tests.assert_eq('a server cannot change them', tests.try(srv_1, 'srv1@sg.example', format($q$select public.save_venue_sign_settings(%L, '{"mode":"all"}')::text$q$, venue_a)), 'ERROR: not allowed');
  perform tests.assert_eq('another club''s manager cannot', tests.try(mgr_b, 'mgrb@sg.example', format($q$select public.save_venue_sign_settings(%L, '{"mode":"all"}')::text$q$, venue_a)), 'ERROR: not allowed');
  perform tests.assert_eq('nothing was chosen', tests.try(mgr_a, 'mgra@sg.example', format($q$select public.save_venue_sign_settings(%L, '{}')::text$q$, venue_a)), 'ERROR: choose how signs work');
  perform tests.assert_eq('a mode that does not exist', tests.try(mgr_a, 'mgra@sg.example', format($q$select public.save_venue_sign_settings(%L, '{"mode":"maybe"}')::text$q$, venue_a)), 'ERROR: signs must be off, on every bottle, or on the bottles you choose');
  perform tests.assert_eq('review must be yes or no', tests.try(mgr_a, 'mgra@sg.example', format($q$select public.save_venue_sign_settings(%L, '{"review_required":"yes"}')::text$q$, venue_a)), 'ERROR: say whether a sign needs a manager''s approval, yes or no');
  perform tests.assert_eq('a field it does not know', tests.try(mgr_a, 'mgra@sg.example', format($q$select public.save_venue_sign_settings(%L, '{"mode":"all","price":1}')::text$q$, venue_a)), 'ERROR: unknown field: price');
  perform tests.assert_eq('nothing changed after the refusals', (select sign_mode || '/' || sign_review::text from public.site_venues where id = venue_a), 'off/false');
  perform tests.assert_eq('the manager switches signs on for every bottle; the answer is the settings as they now are', tests.try(mgr_a, 'mgra@sg.example', format($q$select (public.save_venue_sign_settings(%L, '{"mode":"all"}') ->> 'mode')$q$, venue_a)), 'all');
  perform tests.assert_eq('...and the other club is untouched', (select sign_mode from public.site_venues where id = venue_b), 'off');
  perform tests.assert_true('the change is attributed with from and to, and who', exists (select 1 from public.audit_log where action = 'venue.bottle_sign_settings_saved' and details ->> 'mode_from' = 'off' and details ->> 'mode_to' = 'all' and actor_email = 'mgra@sg.example'));
  n := tests.audits('venue.bottle_sign_settings_saved');
  perform tests.try(mgr_a, 'mgra@sg.example', format($q$select public.save_venue_sign_settings(%L, '{"mode":"all"}')::text$q$, venue_a));
  perform tests.assert_eq('saving what is already set changes nothing and writes no second entry', tests.audits('venue.bottle_sign_settings_saved'), n);
  perform tests.assert_eq('the owner can change review alone; the mode stays', tests.try(owner_u, 'owner@sg.example', format($q$select (public.save_venue_sign_settings(%L, '{"review_required":true}') ->> 'mode') || '/' || (public.save_venue_sign_settings(%L, '{"review_required":true}') ->> 'review_required')$q$, venue_a, venue_a)), 'all/true');
  perform tests.try(owner_u, 'owner@sg.example', format($q$select public.save_venue_sign_settings(%L, '{"review_required":false}')::text$q$, venue_a));

  ---------------------------------------------------------------- which bottles may carry a sign
  perform tests.assert_eq('a server cannot mark a bottle', tests.try(srv_1, 'srv1@sg.example', format('select public.set_bottle_sign_eligible(%L, %L, true)::text', venue_a, bot_patron)), 'ERROR: not allowed');
  perform tests.assert_eq('another club''s manager cannot', tests.try(mgr_b, 'mgrb@sg.example', format('select public.set_bottle_sign_eligible(%L, %L, true)::text', venue_a, bot_patron)), 'ERROR: not allowed');
  perform tests.assert_eq('a bottle from another club''s menu', tests.try(mgr_a, 'mgra@sg.example', format('select public.set_bottle_sign_eligible(%L, %L, true)::text', venue_a, bot_other)), 'ERROR: that bottle is not on this club''s menu');
  perform tests.assert_eq('yes or no is required', tests.try(mgr_a, 'mgra@sg.example', format('select public.set_bottle_sign_eligible(%L, %L, null)::text', venue_a, bot_patron)), 'ERROR: say whether this bottle may carry a sign');
  perform tests.assert_eq('the manager marks Patron', tests.try(mgr_a, 'mgra@sg.example', format('select public.set_bottle_sign_eligible(%L, %L, true)::text', venue_a, bot_patron)), 'true');
  perform tests.assert_eq('marking it again changes nothing', tests.try(mgr_a, 'mgra@sg.example', format('select public.set_bottle_sign_eligible(%L, %L, true)::text', venue_a, bot_patron)), 'false');
  perform tests.assert_eq('only Patron is marked, and the change is attributed', (select count(*) from public.site_bottles where sign_eligible) || '/' || tests.audits('venue.bottle_sign_eligibility_saved'), '1/1');

  ---------------------------------------------------------------- putting a sign on an order: signs OFF at first
  perform tests.try(mgr_a, 'mgra@sg.example', format($q$select public.save_venue_sign_settings(%L, '{"mode":"off"}')::text$q$, venue_a));
  perform tests.assert_eq('with signs off nobody can', tests.sign(srv_1, 'srv1@sg.example', l_goose, 'Happy Birthday'), 'ERROR: signs are not switched on for this club');
  perform tests.assert_eq('...not even the manager', tests.sign(mgr_a, 'mgra@sg.example', l_goose, 'Happy Birthday'), 'ERROR: signs are not switched on for this club');
  perform tests.try(mgr_a, 'mgra@sg.example', format($q$select public.save_venue_sign_settings(%L, '{"mode":"all"}')::text$q$, venue_a));

  ---------------------------------------------------------------- mode ALL, no review
  perform tests.assert_eq('the table''s own server puts a sign on a bottle: approved at once', tests.sign(srv_1, 'srv1@sg.example', l_goose, 'Happy Birthday'), 'true/approved');
  perform tests.assert_eq('it is stored, with an author', tests.stored(l_goose), 'Happy Birthday|approved|-|someone');
  perform tests.assert_eq('typing the same words again changes nothing', tests.sign(srv_1, 'srv1@sg.example', l_goose, 'Happy Birthday'), 'false/approved');
  perform tests.assert_eq('...spaces around them are not different words', tests.sign(srv_1, 'srv1@sg.example', l_goose, '   Happy Birthday  '), 'false/approved');
  perform tests.assert_eq('different words replace it', tests.sign(srv_1, 'srv1@sg.example', l_goose, 'Happy 30th Sarah'), 'true/approved');
  perform tests.assert_true('the sign and its change are attributed', exists (select 1 from public.audit_log where action = 'table_booking.bottle_sign_set' and entity_id = l_goose::text and details ->> 'old_text' = 'Happy Birthday' and details ->> 'new_text' = 'Happy 30th Sarah' and actor_email = 'srv1@sg.example'));
  perform tests.assert_eq('empty text clears it', tests.sign(srv_1, 'srv1@sg.example', l_goose, '  '), 'true/-');
  perform tests.assert_eq('...and nothing is left behind', tests.stored(l_goose), '-|-|-|nobody');
  perform tests.assert_eq('clearing an empty sign changes nothing', tests.sign(srv_1, 'srv1@sg.example', l_goose, ''), 'false/-');
  perform tests.assert_eq('40 characters is allowed', tests.sign(srv_1, 'srv1@sg.example', l_goose, long40), 'true/approved');
  perform tests.assert_eq('41 is not', tests.sign(srv_1, 'srv1@sg.example', l_goose, long40 || 'y'), 'ERROR: a sign is at most 40 characters');
  perform tests.assert_eq('a new line is not plain text', tests.sign(srv_1, 'srv1@sg.example', l_goose, E'Happy\nBirthday'), 'ERROR: a sign is one line of plain text');
  perform tests.assert_eq('...nor a tab', tests.sign(srv_1, 'srv1@sg.example', l_goose, E'Happy\tBirthday'), 'ERROR: a sign is one line of plain text');
  perform tests.assert_eq('accents and other letters are fine', tests.sign(srv_1, 'srv1@sg.example', l_goose, 'Joyeux anniversaire Zoë'), 'true/approved');
  perform tests.assert_eq('the failed attempts left the last good sign as it was', tests.stored(l_goose), 'Joyeux anniversaire Zoë|approved|-|someone');
  perform tests.sign(srv_1, 'srv1@sg.example', l_goose, '');

  perform tests.assert_eq('the manager can sign any table of the club, even one nobody serves', tests.sign(mgr_a, 'mgra@sg.example', l_two, 'VIP Table 2'), 'true/approved');
  perform tests.assert_eq('the owner can too', tests.sign(owner_u, 'owner@sg.example', l_two, 'VIP Table 2!'), 'true/approved');
  perform tests.assert_eq('a server of another table cannot', tests.sign(srv_2, 'srv2@sg.example', l_goose, 'Not mine'), 'ERROR: not allowed');
  perform tests.assert_eq('...nor a server on a table nobody has', tests.sign(srv_1, 'srv1@sg.example', l_two, 'Not mine'), 'ERROR: not allowed');
  perform tests.assert_eq('a verifier cannot', tests.sign(ver_u, 'ver@sg.example', l_goose, 'Not mine'), 'ERROR: not allowed');
  perform tests.assert_eq('the door cannot', tests.sign(door_u, 'door@sg.example', l_goose, 'Not mine'), 'ERROR: not allowed');
  perform tests.assert_eq('another club''s manager cannot', tests.sign(mgr_b, 'mgrb@sg.example', l_goose, 'Not mine'), 'ERROR: not allowed');
  perform tests.assert_eq('a stranger cannot', tests.sign(rando, 'rando@sg.example', l_goose, 'Not mine'), 'ERROR: not allowed');
  perform tests.assert_eq('a line that does not exist', tests.sign(mgr_a, 'mgra@sg.example', gen_random_uuid(), 'Nothing'), 'ERROR: not allowed');
  perform tests.assert_eq('this club''s manager cannot touch the other club''s order', tests.sign(mgr_a, 'mgra@sg.example', l_b, 'Not mine'), 'ERROR: not allowed');
  perform tests.assert_eq('a cancelled item', tests.sign(mgr_a, 'mgra@sg.example', l_canc, 'Too late'), 'ERROR: this item was cancelled');
  perform tests.assert_eq('an item on its way', tests.sign(mgr_a, 'mgra@sg.example', l_picked, 'Too late'), 'ERROR: this item is already on its way, so its sign can no longer change');
  perform tests.assert_eq('a delivered item', tests.sign(mgr_a, 'mgra@sg.example', l_served, 'Too late'), 'ERROR: this item is already on its way, so its sign can no longer change');
  perform tests.assert_eq('an item that is ready but not yet gone out can still take one', tests.sign(mgr_a, 'mgra@sg.example', l_ready, 'Cheers'), 'true/approved');
  perform tests.assert_eq('a bottle that was taken off the menu can take one when every bottle can', tests.sign(mgr_a, 'mgra@sg.example', l_nobottle, 'Cheers'), 'true/approved');
  perform tests.login_anon();
  perform tests.assert_raises('a visitor cannot', format($q$select public.desk_set_bottle_sign(%L, 'x')$q$, l_goose), 'permission denied');
  perform tests.logout();
  perform tests.sign(mgr_a, 'mgra@sg.example', l_ready, '');
  perform tests.sign(mgr_a, 'mgra@sg.example', l_nobottle, '');

  ---------------------------------------------------------------- mode SELECTED: only the marked bottles
  perform tests.try(mgr_a, 'mgra@sg.example', format($q$select public.save_venue_sign_settings(%L, '{"mode":"selected"}')::text$q$, venue_a));
  perform tests.assert_eq('a marked bottle (Patron) takes a sign', tests.sign(srv_1, 'srv1@sg.example', l_patron, 'Happy Birthday'), 'true/approved');
  perform tests.assert_eq('an unmarked bottle (Grey Goose) does not', tests.sign(srv_1, 'srv1@sg.example', l_goose, 'Happy Birthday'), 'ERROR: this bottle is not one of the club''s sign bottles');
  perform tests.assert_eq('a line with no bottle on the menu does not', tests.sign(mgr_a, 'mgra@sg.example', l_nobottle, 'Cheers'), 'ERROR: this bottle is not one of the club''s sign bottles');
  perform tests.assert_eq('clearing is always allowed, even on a bottle that is no longer marked', tests.try(mgr_a, 'mgra@sg.example', format('select public.set_bottle_sign_eligible(%L, %L, false)::text', venue_a, bot_patron)) || '/' || tests.sign(srv_1, 'srv1@sg.example', l_patron, ''), 'true/true/-');
  perform tests.try(mgr_a, 'mgra@sg.example', format('select public.set_bottle_sign_eligible(%L, %L, true)::text', venue_a, bot_patron));

  ---------------------------------------------------------------- REVIEW on: a server's sign waits for a manager
  perform tests.try(mgr_a, 'mgra@sg.example', format($q$select public.save_venue_sign_settings(%L, '{"mode":"all","review_required":true}')::text$q$, venue_a));
  perform tests.assert_eq('a server''s sign is waiting for review', tests.sign(srv_1, 'srv1@sg.example', l_patron, 'Cheers'), 'true/pending_review');
  perform tests.assert_eq('a manager''s own sign needs no one else', tests.sign(mgr_a, 'mgra@sg.example', l_two, 'VIP Table 2'), 'true/approved');
  perform tests.assert_eq('the server changing the words while it waits keeps it waiting', tests.sign(srv_1, 'srv1@sg.example', l_patron, 'Cheers Sam') || '/' || tests.stored(l_patron), 'true/pending_review/Cheers Sam|pending_review|-|someone');

  perform tests.assert_true('a manager''s own sign is approved by them, with the time', (select sign_reviewed_by is not null and sign_reviewed_at is not null from public.site_table_booking_bottles where id = l_two));
  perform tests.assert_true('a server''s waiting sign has no reviewer yet', (select sign_reviewed_by is null and sign_reviewed_at is null from public.site_table_booking_bottles where id = l_patron));
  perform tests.assert_eq('the manager''s queue holds the waiting sign and only it', tests.try(mgr_a, 'mgra@sg.example', format('select count(*)::text from public.desk_pending_sign_reviews(%L)', venue_a)), '1');
  perform tests.assert_eq('...with the words, who wrote it and for whom', tests.try(mgr_a, 'mgra@sg.example', format($q$select concat_ws('|', p.sign_text, p.set_by_name, p.guest_name, p.quantity, p.service_status) from public.desk_pending_sign_reviews(%L) p$q$, venue_a)), 'Cheers Sam|Staff member|Table One|2|awaiting_prep');
  perform tests.assert_eq('the owner sees the queue too', tests.try(owner_u, 'owner@sg.example', format('select count(*)::text from public.desk_pending_sign_reviews(%L)', venue_a)), '1');
  perform tests.assert_eq('a server does not', tests.try(srv_1, 'srv1@sg.example', format('select count(*)::text from public.desk_pending_sign_reviews(%L)', venue_a)), 'ERROR: not allowed');
  perform tests.assert_eq('another club''s manager does not', tests.try(mgr_b, 'mgrb@sg.example', format('select count(*)::text from public.desk_pending_sign_reviews(%L)', venue_a)), 'ERROR: not allowed');
  perform tests.assert_eq('the other club''s queue is empty', tests.try(mgr_b, 'mgrb@sg.example', format('select count(*)::text from public.desk_pending_sign_reviews(%L)', venue_b)), '0');

  perform tests.assert_eq('a server cannot review', tests.review(srv_1, 'srv1@sg.example', l_patron, 'approve'), 'ERROR: not allowed');
  perform tests.assert_eq('the door cannot', tests.review(door_u, 'door@sg.example', l_patron, 'approve'), 'ERROR: not allowed');
  perform tests.assert_eq('another club''s manager cannot', tests.review(mgr_b, 'mgrb@sg.example', l_patron, 'approve'), 'ERROR: not allowed');
  perform tests.assert_eq('the decision must be approve or reject', tests.review(mgr_a, 'mgra@sg.example', l_patron, 'maybe'), 'ERROR: approve the sign or decline it');
  perform tests.assert_eq('declining needs a reason', tests.review(mgr_a, 'mgra@sg.example', l_patron, 'reject'), 'ERROR: say why the sign is declined (at least 3 characters)');
  perform tests.assert_eq('...a real one', tests.review(mgr_a, 'mgra@sg.example', l_patron, 'reject', 'no'), 'ERROR: say why the sign is declined (at least 3 characters)');
  perform tests.assert_eq('...of at most 200 characters', tests.review(mgr_a, 'mgra@sg.example', l_patron, 'reject', repeat('z', 201)), 'ERROR: keep the reason to 200 characters or fewer');
  perform tests.assert_eq('an item with no sign', tests.review(mgr_a, 'mgra@sg.example', l_goose, 'approve'), 'ERROR: this item has no sign');
  perform tests.assert_eq('the manager declines with a reason', tests.review(mgr_a, 'mgra@sg.example', l_patron, 'reject', '  Please check the spelling  '), 'true/rejected');
  perform tests.assert_eq('...the reason is kept (trimmed) and the sign is as it was', tests.stored(l_patron), 'Cheers Sam|rejected|Please check the spelling|someone');
  perform tests.assert_eq('declining again changes nothing', tests.review(mgr_a, 'mgra@sg.example', l_patron, 'reject', 'Please check the spelling'), 'false/rejected');
  perform tests.assert_eq('approving what was declined is refused: it has to be changed first', tests.review(mgr_a, 'mgra@sg.example', l_patron, 'approve'), 'ERROR: this sign was already reviewed');
  perform tests.assert_eq('the server changes the words: back to review, the reason is gone', tests.sign(srv_1, 'srv1@sg.example', l_patron, 'Cheers, Sam!') || '/' || tests.stored(l_patron), 'true/pending_review/Cheers, Sam!|pending_review|-|someone');
  perform tests.assert_eq('the manager approves', tests.review(mgr_a, 'mgra@sg.example', l_patron, 'approve'), 'true/approved');
  perform tests.assert_eq('approving again changes nothing', tests.review(mgr_a, 'mgra@sg.example', l_patron, 'approve'), 'false/approved');
  perform tests.assert_eq('declining an approved sign is refused', tests.review(mgr_a, 'mgra@sg.example', l_patron, 'reject', 'Changed my mind'), 'ERROR: this sign was already reviewed');
  perform tests.assert_true('the review is attributed with the decision', exists (select 1 from public.audit_log where action = 'table_booking.bottle_sign_reviewed' and entity_id = l_patron::text and details ->> 'decision' = 'approve' and details ->> 'sign_text' = 'Cheers, Sam!' and actor_email = 'mgra@sg.example'));
  perform tests.assert_eq('the queue is empty again', tests.try(mgr_a, 'mgra@sg.example', format('select count(*)::text from public.desk_pending_sign_reviews(%L)', venue_a)), '0');
  perform tests.assert_eq('changing an approved sign sends it back to review when a server does it', tests.sign(srv_1, 'srv1@sg.example', l_patron, 'Cheers all'), 'true/pending_review');
  -- A sign can never be reviewed by the person who wrote it (a waiting sign by a manager cannot arise through the functions; make one to prove the rule).
  update public.site_table_booking_bottles set sign_text = 'My own', sign_status = 'pending_review', sign_set_by = mgr_a where id = l_two;
  perform tests.assert_eq('a manager cannot approve their own sign', tests.review(mgr_a, 'mgra@sg.example', l_two, 'approve'), 'ERROR: someone else has to review your sign');
  perform tests.assert_eq('...the owner can', tests.review(owner_u, 'owner@sg.example', l_two, 'approve'), 'true/approved');

  ---------------------------------------------------------------- REVIEW before service: a waiting or declined sign stops the order, on every path
  perform tests.assert_eq('a waiting sign stops the order being prepared (the app''s own function)', tests.try(mgr_a, 'mgra@sg.example', format($q$select public.desk_set_service_status(%L, 'preparing')::text$q$, l_patron)), 'ERROR: the sign on this order has not been approved yet');
  perform tests.assert_eq('...and nothing moved', tests.svc(l_patron), 'awaiting_prep');
  perform tests.assert_eq('accepting the order is still fine', tests.try(mgr_a, 'mgra@sg.example', format($q$select public.desk_set_service_status(%L, 'accepted')::text$q$, l_patron)), 'true');
  perform tests.assert_raises('...a plain update to ready is stopped by the table itself', format($q$update public.site_table_booking_bottles set service_status = 'ready' where id = %L$q$, l_patron), 'has not been approved yet');
  perform tests.assert_raises('...so is one to delivered', format($q$update public.site_table_booking_bottles set service_status = 'served' where id = %L$q$, l_patron), 'has not been approved yet');
  perform tests.review(mgr_a, 'mgra@sg.example', l_patron, 'reject', 'Wrong spelling');
  perform tests.assert_eq('a declined sign stops it too', tests.try(mgr_a, 'mgra@sg.example', format($q$select public.desk_set_service_status(%L, 'preparing')::text$q$, l_patron)), 'ERROR: the sign on this order has not been approved yet');
  perform tests.assert_eq('typing the same words again does not undo a decline', tests.sign(srv_1, 'srv1@sg.example', l_patron, 'Cheers all') || '/' || (select sign_status from public.site_table_booking_bottles where id = l_patron), 'false/rejected/rejected');
  perform tests.sign(srv_1, 'srv1@sg.example', l_patron, 'Cheers all!');
  perform tests.review(mgr_a, 'mgra@sg.example', l_patron, 'approve');
  perform tests.assert_eq('an approved sign lets it through', tests.try(mgr_a, 'mgra@sg.example', format($q$select public.desk_set_service_status(%L, 'preparing')::text$q$, l_patron)), 'true');
  perform tests.assert_eq('an order without a sign was never in the way', tests.try(mgr_a, 'mgra@sg.example', format($q$select public.desk_set_service_status(%L, 'preparing')::text$q$, l_goose)), 'true');
  -- partial delivery: a ready item whose sign was just changed by the server is waiting again, and cannot be handed over
  perform tests.sign(srv_1, 'srv1@sg.example', l_ready, 'Cheers once more');
  perform tests.assert_eq('the item is waiting for review again', tests.stored(l_ready), 'Cheers once more|pending_review|-|someone');
  perform tests.assert_eq('part of it cannot be handed over', tests.try(mgr_a, 'mgra@sg.example', format('select public.desk_deliver_part(%L, 1, 0)::text', l_ready)), 'ERROR: the sign on this order has not been approved yet');
  perform tests.review(mgr_a, 'mgra@sg.example', l_ready, 'approve');
  perform tests.assert_eq('once approved it can', tests.try(mgr_a, 'mgra@sg.example', format('select (public.desk_deliver_part(%L, 1, 0) ->> %L)', l_ready, 'delivered')), '1');
  -- review switched off: a waiting sign blocks nothing any more
  perform tests.sign(srv_1, 'srv1@sg.example', l_goose, 'Birthday');
  perform tests.assert_eq('a waiting sign again', tests.stored(l_goose), 'Birthday|pending_review|-|someone');
  perform tests.try(mgr_a, 'mgra@sg.example', format($q$select public.save_venue_sign_settings(%L, '{"review_required":false}')::text$q$, venue_a));
  perform tests.assert_eq('with review off the order goes on', tests.try(mgr_a, 'mgra@sg.example', format($q$select public.desk_set_service_status(%L, 'ready')::text$q$, l_goose)), 'true');
  perform tests.try(mgr_a, 'mgra@sg.example', format($q$select public.save_venue_sign_settings(%L, '{"review_required":true}')::text$q$, venue_a));

  ---------------------------------------------------------------- reading the signs
  update public.site_table_booking_bottles set service_status = 'awaiting_prep', sign_text = null, sign_status = null, sign_set_by = null where id in (l_goose, l_patron);
  perform tests.sign(srv_1, 'srv1@sg.example', l_patron, 'Cheers all');
  perform tests.assert_eq('the table''s server is given the signs of their own table''s lines only: this one with its state, and the ones that could take one', tests.line_signs(srv_1, 'srv1@sg.example', array[l_patron, l_goose, l_two, l_b, l_served, l_canc]),
    (select string_agg(x, ' ; ' order by x) from unnest(array[l_patron::text || '=Cheers all=pending_review=true=true', l_goose::text || '=-=-=true=true']) x));
  perform tests.assert_eq('a delivered item and a cancelled one are not offered', tests.line_signs(srv_1, 'srv1@sg.example', array[l_served, l_canc, l_picked]), '(none)');
  perform tests.assert_eq('the manager is given every line of their club that has a sign or could take one, and not the other club''s', tests.line_signs(mgr_a, 'mgra@sg.example', array[l_patron, l_two, l_b]),
    (select string_agg(x, ' ; ' order by x) from unnest(array[l_patron::text || '=Cheers all=pending_review=true=true', l_two::text || '=My own=approved=true=true']) x));
  perform tests.assert_eq('a verifier is given none', tests.line_signs(ver_u, 'ver@sg.example', array[l_patron, l_goose]), '(none)');
  perform tests.assert_eq('the door is given none', tests.line_signs(door_u, 'door@sg.example', array[l_patron, l_goose]), '(none)');
  perform tests.assert_eq('a stranger is given none', tests.line_signs(rando, 'rando@sg.example', array[l_patron, l_goose]), '(none)');
  perform tests.assert_eq('no lines, no answer', tests.line_signs(mgr_a, 'mgra@sg.example', array[]::uuid[]), '(none)');
  perform tests.assert_eq('at most 500 at a time', tests.line_signs(mgr_a, 'mgra@sg.example', (select array_agg(gen_random_uuid()) from generate_series(1, 501))), 'ERROR: ask for at most 500 items at a time');
  perform tests.try(mgr_a, 'mgra@sg.example', format($q$select public.save_venue_sign_settings(%L, '{"mode":"selected"}')::text$q$, venue_a));
  perform tests.try(mgr_a, 'mgra@sg.example', format('select public.set_bottle_sign_eligible(%L, %L, false)::text', venue_a, bot_patron));
  perform tests.assert_eq('with signs limited to marked bottles and none marked, an existing sign still shows but nothing can take a new one', tests.line_signs(mgr_a, 'mgra@sg.example', array[l_patron, l_goose]),
    l_patron::text || '=Cheers all=pending_review=false=true');
  perform tests.try(mgr_a, 'mgra@sg.example', format($q$select public.save_venue_sign_settings(%L, '{"mode":"off"}')::text$q$, venue_a));
  perform tests.assert_eq('with signs off nothing can take one and an existing sign is only shown', tests.line_signs(srv_1, 'srv1@sg.example', array[l_patron, l_goose]), l_patron::text || '=Cheers all=pending_review=false=true');
  perform tests.login_anon();
  perform tests.assert_raises('a visitor cannot read signs', format('select * from public.desk_line_signs(array[%L]::uuid[])', l_patron), 'permission denied');
  perform tests.assert_raises('...nor the queue', format('select * from public.desk_pending_sign_reviews(%L)', venue_a), 'permission denied');
  perform tests.logout();

  ---------------------------------------------------------------- the queue leaves out work that is not work
  perform tests.try(mgr_a, 'mgra@sg.example', format($q$select public.save_venue_sign_settings(%L, '{"mode":"all"}')::text$q$, venue_a));
  update public.site_table_booking_bottles set sign_text = 'Closed one', sign_status = 'pending_review', sign_set_by = srv_1, sign_set_at = now() where id = l_closed;
  update public.site_table_booking_bottles set sign_text = 'Cancelled one', sign_status = 'pending_review', sign_set_by = srv_1, sign_set_at = now() where id = l_canc;
  update public.site_table_booking_bottles set sign_text = 'On its way', sign_status = 'pending_review', sign_set_by = srv_1, sign_set_at = now() where id = l_picked;
  perform tests.assert_eq('an item that has gone out or was cancelled still shows its sign, but can no longer take a new one', tests.line_signs(mgr_a, 'mgra@sg.example', array[l_picked, l_canc]),
    (select string_agg(x, ' ; ' order by x) from unnest(array[l_picked::text || '=On its way=pending_review=false=true', l_canc::text || '=Cancelled one=pending_review=false=true']) x));
  perform tests.assert_eq('a closed-out table, a cancelled item and one already on its way are not in the queue: only the real waiting sign is', tests.try(mgr_a, 'mgra@sg.example', format($q$select coalesce(string_agg(p.sign_text, ',' order by p.sign_text), '(none)') from public.desk_pending_sign_reviews(%L) p$q$, venue_a)), 'Cheers all');
end $$;

rollback;
