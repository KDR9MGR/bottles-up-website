-- Sales source and closing reports (20261121100000_sales_source.sql). What matters: only the club's owner or manager chooses the source and sends a closing report; Connected POS is refused in plain words;
-- only a club on "upload" can send one; a report is the club's own figure, labelled VENUE-REPORTED, never added to what BottlesUp recorded; when it says it includes BottlesUp's sales the bar part is the
-- difference (never below 0) so nothing is counted twice; the owner or a payment verifier checks it, never the person who sent it; a newer report replaces the old one and the old one is kept; every refusal
-- is a plain sentence and changes nothing; the tables are closed and an account that sent or checked a report can still be deleted.
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
create function tests.try(p_user uuid, p_email text, p_sql text) returns text language plpgsql as $$
declare r text;
begin
  perform tests.login(p_user, p_email);
  execute p_sql into r;
  perform tests.logout();
  return coalesce(r, 'null');
exception when others then
  perform tests.logout();
  return 'ERROR: ' || sqlerrm;
end $$;
create function tests.try_anon(p_sql text) returns text language plpgsql as $$
declare r text;
begin
  perform tests.login_anon();
  execute p_sql into r;
  perform tests.logout();
  return coalesce(r, 'null');
exception when others then
  perform tests.logout();
  return 'ERROR: ' || sqlerrm;
end $$;
-- Send a closing report: night, gross, discount, refund, includes, note (period 20:00 to 04:00 unless given)
create function tests.send(p_user uuid, p_email text, p_venue uuid, p_night date, p_gross bigint, p_disc bigint, p_ref bigint, p_inc boolean, p_note text,
                           p_start text default null, p_end text default null) returns text language sql as $$
  select tests.try(p_user, p_email, format('select public.submit_closing_report(%L, %L, %L, %L, %s, %s, %s, %s, %L)::text',
    p_venue, p_night, coalesce(p_start, p_night::text || ' 20:00+00'), coalesce(p_end, (p_night + 1)::text || ' 04:00+00'),
    coalesce(p_gross::text, 'null'), coalesce(p_disc::text, 'null'), coalesce(p_ref::text, 'null'), coalesce(p_inc::text, 'null'), p_note))
$$;
create function tests.review(p_user uuid, p_email text, p_report uuid, p_approve boolean, p_note text) returns text language sql as $$
  select tests.try(p_user, p_email, format('select public.review_closing_report(%L, %s, %L)', p_report, coalesce(p_approve::text, 'null'), p_note))
$$;
create function tests.sources(p_user uuid, p_email text, p_venue uuid, p_night date) returns text language sql as $$
  select tests.try(p_user, p_email, format('select public.night_sales_sources(%L, %L)::text', p_venue, p_night))
$$;

do $$
declare
  owner_u constant uuid := '00000000-0000-0000-0000-00000000f1d1';
  mgr_a constant uuid := '00000000-0000-0000-0000-00000000f1d2';
  mgr_b constant uuid := '00000000-0000-0000-0000-00000000f1d3';
  ver_a constant uuid := '00000000-0000-0000-0000-00000000f1d4';
  srv_a constant uuid := '00000000-0000-0000-0000-00000000f1d5';
  other_owner constant uuid := '00000000-0000-0000-0000-00000000f1d6';
  rando constant uuid := '00000000-0000-0000-0000-00000000f1d7';
  ver_b constant uuid := '00000000-0000-0000-0000-00000000f1d8';
  org uuid; org2 uuid; venue_a uuid; venue_b uuid; venue_x uuid; t_a uuid; slot_a uuid; b1 uuid; b2 uuid;
  n1 constant date := current_date - 1;
  n2 constant date := current_date - 2;
  n3 constant date := current_date - 3;
  n5 constant date := current_date - 5;
  n10 constant date := current_date - 10;
  r1 uuid; r2 uuid; r3 uuid; r_owner uuid; r_tmp uuid; j jsonb; n_logs bigint;
begin
  insert into auth.users (id, email) values (owner_u, 'owner@sales.example'), (mgr_a, 'mgra@sales.example'), (mgr_b, 'mgrb@sales.example'), (ver_a, 'vera@sales.example'),
    (srv_a, 'srva@sales.example'), (other_owner, 'other@sales.example'), (rando, 'rando@sales.example'), (ver_b, 'verb@sales.example');
  perform tests.login(owner_u, 'owner@sales.example');
  org := public.create_organization('Sales Co', 'venue_owner');
  venue_a := public.create_org_venue(org, 'Club A');
  venue_b := public.create_org_venue(org, 'Club B');
  perform tests.login(other_owner, 'other@sales.example');
  org2 := public.create_organization('Other Co', 'venue_owner');
  venue_x := public.create_org_venue(org2, 'Other Club');
  perform tests.logout();
  perform tests.join_as(owner_u, 'owner@sales.example', org, 'mgra@sales.example', 'manager', venue_a, mgr_a);
  perform tests.join_as(owner_u, 'owner@sales.example', org, 'mgrb@sales.example', 'manager', venue_b, mgr_b);
  perform tests.join_as(owner_u, 'owner@sales.example', org, 'vera@sales.example', 'verifier', venue_a, ver_a);
  perform tests.join_as(owner_u, 'owner@sales.example', org, 'verb@sales.example', 'verifier', venue_b, ver_b);
  perform tests.join_as(owner_u, 'owner@sales.example', org, 'srva@sales.example', 'server', venue_a, srv_a);

  insert into public.site_table_types (venue_id, name, max_guests, min_spend_cents, deposit_cents, inventory_count) values (venue_a, 'Booth', 8, 100000, 20000, 9) returning id into t_a;
  insert into public.site_venue_time_slots (venue_id, day_of_week, start_time, label) values (venue_a, 6, '21:00', 'Evening') returning id into slot_a;

  -- ---------------------------------------------------------------- the source: who reads it
  perform tests.assert_eq('a club that never chose is on BottlesUp entries (owner reads)', tests.try(owner_u, 'owner@sales.example', format('select public.venue_sales_source(%L)', venue_a)), 'entries');
  perform tests.assert_eq('the manager reads it', tests.try(mgr_a, 'mgra@sales.example', format('select public.venue_sales_source(%L)', venue_a)), 'entries');
  perform tests.assert_eq('the verifier reads it', tests.try(ver_a, 'vera@sales.example', format('select public.venue_sales_source(%L)', venue_a)), 'entries');
  perform tests.assert_eq('a server does not', tests.try(srv_a, 'srva@sales.example', format('select public.venue_sales_source(%L)', venue_a)), 'ERROR: not allowed');
  perform tests.assert_eq('another club''s manager does not', tests.try(mgr_b, 'mgrb@sales.example', format('select public.venue_sales_source(%L)', venue_a)), 'ERROR: not allowed');
  perform tests.assert_eq('another business''s owner does not', tests.try(other_owner, 'other@sales.example', format('select public.venue_sales_source(%L)', venue_a)), 'ERROR: not allowed');
  perform tests.assert_eq('a stranger does not', tests.try(rando, 'rando@sales.example', format('select public.venue_sales_source(%L)', venue_a)), 'ERROR: not allowed');
  perform tests.assert_eq('a visitor is refused by the database before anything runs', tests.try_anon(format('select public.venue_sales_source(%L)', venue_a)), 'ERROR: permission denied for function venue_sales_source');
  perform tests.assert_eq('nothing is stored until someone chooses', (select count(*) from public.site_venue_sales_source), 0::bigint);

  -- ---------------------------------------------------------------- the source: who changes it, and to what
  perform tests.assert_eq('the manager chooses closing report upload', tests.try(mgr_a, 'mgra@sales.example', format('select public.save_venue_sales_source(%L, %L)', venue_a, 'upload')), 'upload');
  perform tests.assert_eq('and it is stored for that club', (select source from public.site_venue_sales_source where venue_id = venue_a), 'upload');
  perform tests.assert_eq('and who changed it', (select changed_by from public.site_venue_sales_source where venue_id = venue_a), mgr_a);
  perform tests.assert_eq('the other club is untouched', tests.try(mgr_b, 'mgrb@sales.example', format('select public.venue_sales_source(%L)', venue_b)), 'entries');
  perform tests.assert_eq('the change is in the audit trail, once', (select count(*) from public.audit_log where action = 'venue.sales_source' and entity_id = venue_a::text), 1::bigint);
  perform tests.assert_eq('with from and to', (select details ->> 'from' || '>' || (details ->> 'to') from public.audit_log where action = 'venue.sales_source' and entity_id = venue_a::text), 'entries>upload');
  perform tests.assert_eq('choosing the same again changes nothing', tests.try(mgr_a, 'mgra@sales.example', format('select public.save_venue_sales_source(%L, %L)', venue_a, 'upload')), 'upload');
  perform tests.assert_eq('and logs nothing', (select count(*) from public.audit_log where action = 'venue.sales_source' and entity_id = venue_a::text), 1::bigint);
  perform tests.try(owner_u, 'owner@sales.example', format('select public.save_venue_sales_source(%L, %L)', venue_a, 'upload'));
  perform tests.assert_eq('someone else choosing the same again does not take over who changed it', (select changed_by from public.site_venue_sales_source where venue_id = venue_a), mgr_a);
  perform tests.assert_eq('choosing entries for a club that never chose stores it (the choice is explicit) and logs nothing', tests.try(mgr_b, 'mgrb@sales.example', format('select public.save_venue_sales_source(%L, %L)', venue_b, 'entries')), 'entries');
  perform tests.assert_eq('stored', (select source from public.site_venue_sales_source where venue_id = venue_b), 'entries');
  perform tests.assert_eq('no log, since nothing changed', (select count(*) from public.audit_log where action = 'venue.sales_source' and entity_id = venue_b::text), 0::bigint);
  perform tests.assert_eq('a server cannot change it', tests.try(srv_a, 'srva@sales.example', format('select public.save_venue_sales_source(%L, %L)', venue_a, 'entries')), 'ERROR: not allowed');
  perform tests.assert_eq('a verifier cannot change it', tests.try(ver_a, 'vera@sales.example', format('select public.save_venue_sales_source(%L, %L)', venue_a, 'entries')), 'ERROR: not allowed');
  perform tests.assert_eq('another club''s manager cannot', tests.try(mgr_b, 'mgrb@sales.example', format('select public.save_venue_sales_source(%L, %L)', venue_a, 'entries')), 'ERROR: not allowed');
  perform tests.assert_eq('a stranger cannot', tests.try(rando, 'rando@sales.example', format('select public.save_venue_sales_source(%L, %L)', venue_a, 'entries')), 'ERROR: not allowed');
  perform tests.assert_eq('a visitor cannot', tests.try_anon(format('select public.save_venue_sales_source(%L, %L)', venue_a, 'entries')), 'ERROR: permission denied for function save_venue_sales_source');
  perform tests.assert_eq('Connected POS is refused in plain words', tests.try(mgr_a, 'mgra@sales.example', format('select public.save_venue_sales_source(%L, %L)', venue_a, 'pos')),
    'ERROR: Connected POS is not available yet: no point-of-sale provider is connected');
  perform tests.assert_eq('anything else is refused', tests.try(mgr_a, 'mgra@sales.example', format('select public.save_venue_sales_source(%L, %L)', venue_a, 'banana')),
    'ERROR: the sales source is BottlesUp entries or a closing report upload');
  perform tests.assert_eq('nothing at all is refused', tests.try(mgr_a, 'mgra@sales.example', format('select public.save_venue_sales_source(%L, null)', venue_a)), 'ERROR: choose a sales source');
  perform tests.assert_eq('and none of that changed the source', (select source from public.site_venue_sales_source where venue_id = venue_a), 'upload');

  -- ---------------------------------------------------------------- sending a closing report
  perform tests.assert_eq('a club on entries cannot send one', tests.send(mgr_b, 'mgrb@sales.example', venue_b, n1, 50000, 0, 0, false, null),
    'ERROR: this club does not use closing report uploads: change Sales Tracking first');
  perform tests.assert_eq('a server cannot', tests.send(srv_a, 'srva@sales.example', venue_a, n1, 50000, 0, 0, false, null), 'ERROR: not allowed');
  perform tests.assert_eq('a verifier cannot send one either (they check them)', tests.send(ver_a, 'vera@sales.example', venue_a, n1, 50000, 0, 0, false, null), 'ERROR: not allowed');
  perform tests.assert_eq('another club''s manager cannot', tests.send(mgr_b, 'mgrb@sales.example', venue_a, n1, 50000, 0, 0, false, null), 'ERROR: not allowed');
  perform tests.assert_eq('a stranger cannot', tests.send(rando, 'rando@sales.example', venue_a, n1, 50000, 0, 0, false, null), 'ERROR: not allowed');
  perform tests.assert_eq('a visitor cannot', tests.try_anon(format('select public.submit_closing_report(%L, %L, now(), now() + interval ''8 hours'', 1, 0, 0, false, null)', venue_a, n1)),
    'ERROR: permission denied for function submit_closing_report');
  perform tests.assert_eq('no night', tests.send(mgr_a, 'mgra@sales.example', venue_a, null, 50000, 0, 0, false, null, '2026-01-01 20:00+00', '2026-01-02 04:00+00'), 'ERROR: which night is the report for?');
  perform tests.assert_eq('a night that has not happened', tests.send(mgr_a, 'mgra@sales.example', venue_a, current_date + 2, 50000, 0, 0, false, null), 'ERROR: that night has not happened yet');
  perform tests.assert_eq('a night too long ago', tests.send(mgr_a, 'mgra@sales.example', venue_a, current_date - 91, 50000, 0, 0, false, null), 'ERROR: a closing report can be sent for the last 90 days');
  perform tests.assert_true('90 days ago is still fine', tests.send(mgr_a, 'mgra@sales.example', venue_a, current_date - 90, 1000, 0, 0, false, null) ~ '^[0-9a-f-]{36}$');
  perform tests.assert_true('discounts and refunds equal to the gross are allowed (a net of nothing)', tests.send(mgr_a, 'mgra@sales.example', venue_a, current_date - 40, 1000, 600, 400, false, null) ~ '^[0-9a-f-]{36}$');
  perform tests.assert_eq('a period that ends before it starts', tests.send(mgr_a, 'mgra@sales.example', venue_a, n1, 50000, 0, 0, false, null, n1::text || ' 20:00+00', n1::text || ' 19:00+00'),
    'ERROR: the period must end after it starts');
  perform tests.assert_eq('a period of nothing', tests.send(mgr_a, 'mgra@sales.example', venue_a, n1, 50000, 0, 0, false, null, n1::text || ' 20:00+00', n1::text || ' 20:00+00'),
    'ERROR: the period must end after it starts');
  perform tests.assert_eq('a period of more than 36 hours', tests.send(mgr_a, 'mgra@sales.example', venue_a, n1, 50000, 0, 0, false, null, n1::text || ' 08:00+00', (n1 + 2)::text || ' 08:00+00'),
    'ERROR: a closing report covers one night: at most 36 hours');
  perform tests.assert_true('exactly 36 hours is fine', tests.send(mgr_a, 'mgra@sales.example', venue_a, n3, 2000, 0, 0, false, null, n3::text || ' 08:00+00', (n3 + 1)::text || ' 20:00+00') ~ '^[0-9a-f-]{36}$');
  perform tests.assert_eq('no gross', tests.send(mgr_a, 'mgra@sales.example', venue_a, n1, null, 0, 0, false, null), 'ERROR: enter the gross sales for the period');
  perform tests.assert_eq('a negative gross', tests.send(mgr_a, 'mgra@sales.example', venue_a, n1, -1, 0, 0, false, null), 'ERROR: enter the gross sales for the period');
  perform tests.assert_eq('a negative discount', tests.send(mgr_a, 'mgra@sales.example', venue_a, n1, 50000, -1, 0, false, null), 'ERROR: discounts and refunds cannot be negative');
  perform tests.assert_eq('a negative refund', tests.send(mgr_a, 'mgra@sales.example', venue_a, n1, 50000, 0, -1, false, null), 'ERROR: discounts and refunds cannot be negative');
  perform tests.assert_eq('discounts and refunds together above the gross', tests.send(mgr_a, 'mgra@sales.example', venue_a, n1, 50000, 30000, 20001, false, null),
    'ERROR: discounts and refunds cannot be more than the gross sales');
  perform tests.assert_eq('whether it includes BottlesUp must be said', tests.send(mgr_a, 'mgra@sales.example', venue_a, n1, 50000, 0, 0, null, null), 'ERROR: say whether the figures include what BottlesUp recorded');
  perform tests.assert_eq('a note of 301 characters', tests.send(mgr_a, 'mgra@sales.example', venue_a, n1, 50000, 0, 0, false, repeat('x', 301)), 'ERROR: the note is at most 300 characters');
  perform tests.assert_eq('none of the refusals stored anything for last night', (select count(*) from public.site_closing_reports where business_night = n1), 0::bigint);

  r1 := tests.send(mgr_a, 'mgra@sales.example', venue_a, n1, 80000, 5000, 0, false, '  Bar till 1 and 2  ')::uuid;
  perform tests.assert_true('the manager sends last night''s report and gets its id', r1 is not null);
  perform tests.assert_eq('version 1, waiting to be checked', (select version || ':' || status from public.site_closing_reports where id = r1), '1:submitted');
  perform tests.assert_eq('the net is worked out by the database', (select net_cents from public.site_closing_reports where id = r1), 75000::bigint);
  perform tests.assert_eq('the note is trimmed', (select note from public.site_closing_reports where id = r1), 'Bar till 1 and 2');
  perform tests.assert_eq('who sent it', (select submitted_by from public.site_closing_reports where id = r1), mgr_a);
  perform tests.assert_eq('sending is in the audit trail', (select count(*) from public.audit_log where action = 'closing_report.submit' and entity_id = r1::text), 1::bigint);
  r_tmp := tests.send(mgr_a, 'mgra@sales.example', venue_a, n2, 1000, 0, 0, false, '   ')::uuid;
  perform tests.assert_true('a note of only spaces is stored as nothing (and the report exists)', exists (select 1 from public.site_closing_reports where id = r_tmp and note is null));

  -- ---------------------------------------------------------------- sending again replaces, and keeps the old one
  r2 := tests.send(mgr_a, 'mgra@sales.example', venue_a, n1, 90000, 5000, 1000, true, 'Corrected')::uuid;
  perform tests.assert_eq('the new report is version 2 and live', (select version || ':' || status from public.site_closing_reports where id = r2), '2:submitted');
  perform tests.assert_eq('the old one is kept, as superseded', (select version || ':' || status from public.site_closing_reports where id = r1), '1:superseded');
  perform tests.assert_eq('only one report is live for the night', (select count(*) from public.site_closing_reports where venue_id = venue_a and business_night = n1 and status <> 'superseded'), 1::bigint);
  perform tests.assert_eq('the audit trail says which it replaced', (select details ->> 'replaced' from public.audit_log where action = 'closing_report.submit' and entity_id = r2::text), r1::text);
  perform tests.assert_eq('the new net', (select net_cents from public.site_closing_reports where id = r2), 84000::bigint);

  -- ---------------------------------------------------------------- checking a report
  perform tests.assert_eq('a manager cannot check one (the owner or a verifier does)', tests.review(mgr_a, 'mgra@sales.example', r2, true, null), 'ERROR: not allowed');
  perform tests.assert_eq('a server cannot', tests.review(srv_a, 'srva@sales.example', r2, true, null), 'ERROR: not allowed');
  perform tests.assert_eq('another club''s verifier cannot', tests.review(ver_b, 'verb@sales.example', r2, true, null), 'ERROR: not allowed');
  perform tests.assert_eq('another business''s owner cannot', tests.review(other_owner, 'other@sales.example', r2, true, null), 'ERROR: not allowed');
  perform tests.assert_eq('a stranger cannot', tests.review(rando, 'rando@sales.example', r2, true, null), 'ERROR: not allowed');
  perform tests.assert_eq('a report that does not exist looks the same as one that is not yours', tests.review(ver_a, 'vera@sales.example', gen_random_uuid(), true, null), 'ERROR: not allowed');
  perform tests.assert_eq('a visitor cannot', tests.try_anon(format('select public.review_closing_report(%L, true, null)', r2)), 'ERROR: permission denied for function review_closing_report');
  perform tests.assert_eq('a report an older version replaced cannot be checked', tests.review(ver_a, 'vera@sales.example', r1, true, null), 'ERROR: a newer report replaced this one');
  perform tests.assert_eq('accept or say why', tests.review(ver_a, 'vera@sales.example', r2, null, null), 'ERROR: accept the report or say why not');
  perform tests.assert_eq('not accepting needs a reason', tests.review(ver_a, 'vera@sales.example', r2, false, null), 'ERROR: say why the report is not accepted (at least 5 characters)');
  perform tests.assert_eq('a reason of four characters is not enough', tests.review(ver_a, 'vera@sales.example', r2, false, 'nope'), 'ERROR: say why the report is not accepted (at least 5 characters)');
  perform tests.assert_eq('a note of 301 characters', tests.review(ver_a, 'vera@sales.example', r2, true, repeat('y', 301)), 'ERROR: the note is at most 300 characters');
  perform tests.assert_eq('none of those changed the report', (select status from public.site_closing_reports where id = r2), 'submitted');

  -- the owner sends one too, and cannot check their own
  r_owner := tests.send(owner_u, 'owner@sales.example', venue_a, n10, 20000, 0, 0, false, null)::uuid;
  perform tests.assert_true('the owner may send one', r_owner is not null);
  perform tests.assert_eq('but not check it', tests.review(owner_u, 'owner@sales.example', r_owner, true, null), 'ERROR: someone else must review a report you sent');
  perform tests.assert_eq('the verifier can', tests.review(ver_a, 'vera@sales.example', r_owner, true, null), 'reviewed');
  r_tmp := tests.send(owner_u, 'owner@sales.example', venue_a, current_date - 12, 5000, 0, 0, false, null)::uuid;

  perform tests.assert_eq('the verifier accepts the manager''s report', tests.review(ver_a, 'vera@sales.example', r2, true, 'Matches the till'), 'reviewed');
  perform tests.assert_eq('it is reviewed, by the verifier, with the note', (select status || ':' || reviewed_by::text || ':' || review_note from public.site_closing_reports where id = r2), 'reviewed:' || ver_a::text || ':Matches the till');
  perform tests.assert_true('and the time is kept', (select reviewed_at is not null from public.site_closing_reports where id = r2));
  perform tests.assert_eq('checking is in the audit trail', (select details ->> 'status' from public.audit_log where action = 'closing_report.review' and entity_id = r2::text), 'reviewed');
  perform tests.assert_eq('it cannot be checked twice', tests.review(owner_u, 'owner@sales.example', r2, false, 'changed my mind'), 'ERROR: this report has already been accepted');

  r3 := tests.send(mgr_a, 'mgra@sales.example', venue_a, n5, 30000, 0, 0, false, null)::uuid;
  perform tests.assert_eq('the owner does not accept a report', tests.review(owner_u, 'owner@sales.example', r3, false, 'Totals do not add up'), 'rejected');
  perform tests.assert_eq('rejected, with the reason', (select status || ':' || review_note from public.site_closing_reports where id = r3), 'rejected:Totals do not add up');
  perform tests.assert_eq('it cannot be checked again', tests.review(ver_a, 'vera@sales.example', r3, true, null), 'ERROR: this report has already been not accepted');
  r_tmp := tests.send(mgr_a, 'mgra@sales.example', venue_a, n5, 31000, 0, 0, false, null)::uuid;
  perform tests.assert_eq('a rejected night can be sent again, and replaces the rejected one', (select status from public.site_closing_reports where id = r_tmp), 'submitted');
  perform tests.assert_eq('the rejected one is kept as superseded', (select status from public.site_closing_reports where id = r3), 'superseded');

  -- ---------------------------------------------------------------- the list
  perform tests.assert_eq('the manager''s list is newest night first, newest version first', tests.try(mgr_a, 'mgra@sales.example', format($q$select (select string_agg(business_night::text || '=v' || version || ':' || status, ' ' order by business_night desc, version desc) from public.closing_reports(%L, 5))$q$, venue_a)),
    n1::text || '=v2:reviewed ' || n1::text || '=v1:superseded ' || n2::text || '=v1:submitted ' || n3::text || '=v1:submitted ' || n5::text || '=v2:submitted');
  perform tests.assert_eq('the limit is honoured', tests.try(mgr_a, 'mgra@sales.example', format('select count(*) from public.closing_reports(%L, 2)', venue_a)), '2');
  perform tests.assert_eq('and cannot be zero or negative', tests.try(mgr_a, 'mgra@sales.example', format('select count(*) from public.closing_reports(%L, 0)', venue_a)), '1');
  insert into public.site_closing_reports (venue_id, business_night, version, period_start, period_end, gross_cents, includes_bottlesup, status, reviewed_at)
    select venue_a, current_date - 300 - g, 1, now(), now() + interval '8 hours', 1000, false, 'reviewed', now() from generate_series(1, 110) g;
  perform tests.assert_eq('nor more than 100, even when the club has more', tests.try(mgr_a, 'mgra@sales.example', format('select count(*) from public.closing_reports(%L, 100000)', venue_a)), '100');
  perform tests.assert_eq('and the default is 30', tests.try(mgr_a, 'mgra@sales.example', format('select count(*) from public.closing_reports(%L)', venue_a)), '30');
  perform tests.assert_eq('the manager sees their own reports as theirs and cannot review any', tests.try(mgr_a, 'mgra@sales.example', format($q$select string_agg(mine::text || '/' || can_review::text, ' ' order by business_night desc, version desc) from public.closing_reports(%L, 3)$q$, venue_a)), 'true/false true/false true/false');
  perform tests.assert_eq('the verifier may review what waits, and not what is done', tests.try(ver_a, 'vera@sales.example', format($q$select string_agg(can_review::text, ' ' order by business_night desc, version desc) from public.closing_reports(%L, 3)$q$, venue_a)), 'false false true');
  perform tests.assert_eq('the owner may review what the manager sent, but not their own', tests.try(owner_u, 'owner@sales.example', format($q$select string_agg(business_night::text || ':' || mine::text || '/' || can_review::text, ' ' order by business_night desc) from public.closing_reports(%L, 100) where status = 'submitted'$q$, venue_a)),
    n2::text || ':false/true ' || n3::text || ':false/true ' || n5::text || ':false/true ' || (current_date - 12)::text || ':true/false ' || (current_date - 40)::text || ':false/true ' || (current_date - 90)::text || ':false/true');
  perform tests.assert_eq('a server cannot list them', tests.try(srv_a, 'srva@sales.example', format('select count(*) from public.closing_reports(%L, 5)', venue_a)), 'ERROR: not allowed');
  perform tests.assert_eq('another club''s manager cannot', tests.try(mgr_b, 'mgrb@sales.example', format('select count(*) from public.closing_reports(%L, 5)', venue_a)), 'ERROR: not allowed');
  perform tests.assert_eq('a visitor cannot', tests.try_anon(format('select count(*) from public.closing_reports(%L, 5)', venue_a)), 'ERROR: permission denied for function closing_reports');

  -- ---------------------------------------------------------------- what the night's sales mean
  -- BottlesUp's own record for last night: two paid bookings
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, deposit_cents, status, amount_paid_cents, discount_cents, staff_discount_cents)
    values (venue_a, t_a, slot_a, n1, 'Ann', 'ann@sales.example', 4, 20000, 20000, 'paid', 20000, 2000, 1000) returning id into b1;
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, deposit_cents, status, amount_paid_cents)
    values (venue_a, t_a, slot_a, n1, 'Bo', 'bo@sales.example', 4, 30000, 10000, 'paid', 10000) returning id into b2;
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, deposit_cents, status, amount_paid_cents)
    values (venue_a, t_a, slot_a, n1, 'Cy overpaid', 'cy@sales.example', 2, 10000, 10000, 'paid', 12000);
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, deposit_cents, status)
    values (venue_a, t_a, slot_a, n1, 'Pending Pat', 'pat@sales.example', 4, 99000, 10000, 'pending');
  insert into public.site_refund_requests (booking_id, venue_id, requested_by_kind, requested_by, reason, status, approved_cents, method, decided_by, decided_at, completed_at)
    values (b1, venue_a, 'staff', mgr_a, 'Test refund', 'completed', 5000, 'club', mgr_a, now(), now());
  insert into public.site_refund_requests (booking_id, venue_id, requested_by_kind, requested_by, reason, status, approved_cents, method, decided_by, decided_at)
    values (b2, venue_a, 'staff', mgr_a, 'Approved, not paid out yet', 'approved', 700, 'club', mgr_a, now());

  j := tests.sources(mgr_a, 'mgra@sales.example', venue_a, n1)::jsonb;
  perform tests.assert_eq('the night''s source and its label', (j ->> 'source') || ' / ' || (j ->> 'source_label'), 'upload / Closing report upload');
  perform tests.assert_eq('recorded sales are labelled as such', j #>> '{recorded,label}', 'Recorded sales');
  perform tests.assert_eq('and say what they are', j #>> '{recorded,basis}', 'What BottlesUp recorded: table bookings, their bottles and the payments taken.');
  perform tests.assert_eq('only paid bookings count (a pending one does not)', (j #>> '{recorded,bookings}')::int, 3);
  perform tests.assert_eq('gross is what was owed plus what was taken off', (j #>> '{recorded,gross_cents}')::bigint, 63000::bigint);
  perform tests.assert_eq('discounts are both kinds', (j #>> '{recorded,discount_cents}')::bigint, 3000::bigint);
  perform tests.assert_eq('only a completed refund counts (an approved one not yet paid out does not)', (j #>> '{recorded,refund_cents}')::bigint, 5000::bigint);
  perform tests.assert_eq('net is what was owed less refunds', (j #>> '{recorded,net_cents}')::bigint, 55000::bigint);
  perform tests.assert_eq('collected (an overpayment counts as collected)', (j #>> '{recorded,collected_cents}')::bigint, 42000::bigint);
  perform tests.assert_eq('unpaid never goes below 0 for one booking: an overpaid table does not cancel out another''s balance', (j #>> '{recorded,unpaid_cents}')::bigint, 20000::bigint);
  perform tests.assert_true('and it says when it was worked out', (j #>> '{recorded,as_of}') is not null);
  perform tests.assert_eq('the club''s live report is shown, labelled VENUE-REPORTED', j #>> '{venue_reported,label}', 'Venue-reported sales');
  perform tests.assert_eq('and says it is not live bar sales', j #>> '{venue_reported,basis}', 'The club''s own end-of-night report. It is not live bar sales.');
  perform tests.assert_eq('it is the version that replaced the first, and it was checked', (j #>> '{venue_reported,version}') || ':' || (j #>> '{venue_reported,verification}'), '2:Checked');
  perform tests.assert_eq('the keys are exactly these: the two blocks are never added into a total', (select string_agg(k, ',' order by k) from jsonb_object_keys(j) k), 'business_night,recorded,source,source_label,venue_reported');
  perform tests.assert_true('the report says it includes BottlesUp''s sales', (j #>> '{venue_reported,includes_bottlesup}')::boolean);
  perform tests.assert_eq('so the bar and other part is the report''s net less BottlesUp''s net: 84000 - 55000', (j #>> '{venue_reported,bar_and_other_cents}')::bigint, 29000::bigint);
  perform tests.assert_true('and the report is not smaller than what BottlesUp recorded', not (j #>> '{venue_reported,smaller_than_recorded}')::boolean);
  perform tests.assert_eq('the report''s own figures are carried unchanged', (j #>> '{venue_reported,gross_cents}') || '/' || (j #>> '{venue_reported,discount_cents}') || '/' || (j #>> '{venue_reported,refund_cents}') || '/' || (j #>> '{venue_reported,net_cents}'), '90000/5000/1000/84000');
  perform tests.assert_eq('nothing recorded by BottlesUp changed because a report exists', (select amount_total_cents from public.site_table_bookings where id = b1), 20000);

  -- a report that does NOT include BottlesUp's sales is the bar part in full
  perform tests.send(mgr_a, 'mgra@sales.example', venue_a, n1, 60000, 0, 0, false, null);
  j := tests.sources(ver_a, 'vera@sales.example', venue_a, n1)::jsonb;
  perform tests.assert_eq('without the BottlesUp part, the bar and other part is the whole net', (j #>> '{venue_reported,bar_and_other_cents}')::bigint, 60000::bigint);
  perform tests.assert_eq('a new version waits to be checked', (j #>> '{venue_reported,version}') || ':' || (j #>> '{venue_reported,verification}'), '3:Waiting to be checked');
  perform tests.assert_eq('the recorded block did not move', (j #>> '{recorded,net_cents}')::bigint, 55000::bigint);
  -- a report that includes it but is smaller than what BottlesUp recorded is flagged, and the bar part is never negative
  perform tests.send(mgr_a, 'mgra@sales.example', venue_a, n1, 30000, 0, 0, true, null);
  j := tests.sources(owner_u, 'owner@sales.example', venue_a, n1)::jsonb;
  perform tests.assert_eq('smaller than recorded: the bar part is 0, not below', (j #>> '{venue_reported,bar_and_other_cents}')::bigint, 0::bigint);
  perform tests.assert_true('and it is flagged', (j #>> '{venue_reported,smaller_than_recorded}')::boolean);
  -- exactly equal: nothing left over, not flagged
  perform tests.send(mgr_a, 'mgra@sales.example', venue_a, n1, 55000, 0, 0, true, null);
  j := tests.sources(owner_u, 'owner@sales.example', venue_a, n1)::jsonb;
  perform tests.assert_eq('equal to what BottlesUp recorded: nothing left for the bar', (j #>> '{venue_reported,bar_and_other_cents}')::bigint, 0::bigint);
  perform tests.assert_true('and not flagged', not (j #>> '{venue_reported,smaller_than_recorded}')::boolean);
  -- a rejected report is still shown for what it is
  perform tests.review(ver_a, 'vera@sales.example', (select id from public.site_closing_reports where venue_id = venue_a and business_night = n1 and status = 'submitted'), false, 'Does not match the till');
  j := tests.sources(mgr_a, 'mgra@sales.example', venue_a, n1)::jsonb;
  perform tests.assert_eq('a rejected report says so', j #>> '{venue_reported,verification}', 'Not accepted');
  perform tests.assert_eq('superseded versions are never shown: only the latest', j #>> '{venue_reported,version}', '5');

  -- another night, nothing recorded and no report
  j := tests.sources(mgr_a, 'mgra@sales.example', venue_a, current_date - 20)::jsonb;
  perform tests.assert_eq('a quiet night: nothing recorded', (j #>> '{recorded,bookings}') || '/' || (j #>> '{recorded,net_cents}') || '/' || (j #>> '{recorded,unpaid_cents}'), '0/0/0');
  perform tests.assert_true('and no report: the block is null, not an empty report', (j -> 'venue_reported') = 'null'::jsonb);
  -- a club on entries
  j := tests.sources(mgr_b, 'mgrb@sales.example', venue_b, n1)::jsonb;
  perform tests.assert_eq('a club on BottlesUp entries says so', (j ->> 'source') || ' / ' || (j ->> 'source_label'), 'entries / BottlesUp entries');
  perform tests.assert_eq('and has no venue-reported block', (j -> 'venue_reported')::text, 'null');
  perform tests.assert_eq('another club''s bookings never leak in', (j #>> '{recorded,bookings}'), '0');

  -- who may read the night's sales
  perform tests.assert_true('the owner reads it', tests.sources(owner_u, 'owner@sales.example', venue_a, n1) like '{%');
  perform tests.assert_true('the verifier reads it', tests.sources(ver_a, 'vera@sales.example', venue_a, n1) like '{%');
  perform tests.assert_eq('a server does not', tests.sources(srv_a, 'srva@sales.example', venue_a, n1), 'ERROR: not allowed');
  perform tests.assert_eq('another club''s manager does not', tests.sources(mgr_b, 'mgrb@sales.example', venue_a, n1), 'ERROR: not allowed');
  perform tests.assert_eq('another business''s owner does not', tests.sources(other_owner, 'other@sales.example', venue_a, n1), 'ERROR: not allowed');
  perform tests.assert_eq('a stranger does not', tests.sources(rando, 'rando@sales.example', venue_a, n1), 'ERROR: not allowed');
  perform tests.assert_eq('no night is refused', tests.try(mgr_a, 'mgra@sales.example', format('select public.night_sales_sources(%L, null)::text', venue_a)), 'ERROR: not allowed');
  perform tests.assert_eq('a visitor is refused', tests.try_anon(format('select public.night_sales_sources(%L, %L)::text', venue_a, n1)), 'ERROR: permission denied for function night_sales_sources');

  -- ---------------------------------------------------------------- the tables are closed, and the table itself refuses what the functions refuse
  perform tests.assert_eq('signed-in people cannot read the reports table', tests.try(owner_u, 'owner@sales.example', 'select count(*)::text from public.site_closing_reports'), 'ERROR: permission denied for table site_closing_reports');
  perform tests.assert_eq('nor the source table', tests.try(owner_u, 'owner@sales.example', 'select count(*)::text from public.site_venue_sales_source'), 'ERROR: permission denied for table site_venue_sales_source');
  perform tests.assert_eq('nor write to it', tests.try(owner_u, 'owner@sales.example', format('insert into public.site_venue_sales_source (venue_id, source) values (%L, %L)', venue_x, 'upload')), 'ERROR: permission denied for table site_venue_sales_source');
  perform tests.assert_eq('a visitor cannot read it either', tests.try_anon('select count(*)::text from public.site_closing_reports'), 'ERROR: permission denied for table site_closing_reports');
  begin
    insert into public.site_closing_reports (venue_id, business_night, version, period_start, period_end, gross_cents, includes_bottlesup) values (venue_a, current_date - 30, 1, now(), now() + interval '37 hours', 1, false);
    raise exception 'FAIL - the table accepted a period over 36 hours';
  exception when check_violation then perform tests.assert_true('the table refuses a period over 36 hours by itself', true); end;
  begin
    insert into public.site_closing_reports (venue_id, business_night, version, period_start, period_end, gross_cents, discount_cents, refund_cents, includes_bottlesup) values (venue_a, current_date - 30, 1, now(), now() + interval '8 hours', 100, 60, 41, false);
    raise exception 'FAIL - the table accepted discounts and refunds above the gross';
  exception when check_violation then perform tests.assert_true('the table refuses discounts and refunds above the gross by itself', true); end;
  begin
    insert into public.site_closing_reports (venue_id, business_night, version, period_start, period_end, gross_cents, includes_bottlesup) values (venue_a, n1, 99, now(), now() + interval '8 hours', 100, false);
    raise exception 'FAIL - the table accepted a second live report for the night';
  exception when unique_violation then perform tests.assert_true('the table allows only one live report per club per night, by itself', true); end;
  begin
    insert into public.site_closing_reports (venue_id, business_night, version, period_start, period_end, gross_cents, includes_bottlesup, status) values (venue_a, current_date - 31, 1, now(), now() + interval '8 hours', 100, false, 'reviewed');
    raise exception 'FAIL - the table accepted a reviewed report with no review time';
  exception when check_violation then perform tests.assert_true('the table refuses "reviewed" without a review time', true); end;
  begin
    insert into public.site_venue_sales_source (venue_id, source) values (venue_x, 'pos');
    raise exception 'FAIL - the table accepted Connected POS';
  exception when check_violation then perform tests.assert_true('the table refuses Connected POS by itself', true); end;

  -- ---------------------------------------------------------------- an account that sent or checked a report can still be deleted
  delete from auth.users where id = ver_a;
  perform tests.assert_true('deleting the verifier''s account is not blocked, and the report keeps its review', (select reviewed_at is not null and reviewed_by is null from public.site_closing_reports where id = r2));
  delete from auth.users where id = mgr_a;
  perform tests.assert_true('nor the manager''s: the report stays, with no sender', (select submitted_by is null from public.site_closing_reports where id = r2));
  perform tests.assert_eq('a report whose sender is gone can be checked by the owner', tests.review(owner_u, 'owner@sales.example', (select id from public.site_closing_reports where venue_id = venue_a and business_night = n3 and status = 'submitted'), true, null), 'reviewed');
end $$;

rollback;
