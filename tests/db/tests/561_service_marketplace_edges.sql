-- Hiring professionals, the edges: every limit on its boundary, the days a booking holds, who may do what to a request, a payment that cannot be used, how a cancellation divides the money,
-- and what the daily housekeeping does (and does not) touch.
begin;

create function tests.q(p_user uuid, p_email text, p_expr text) returns text language plpgsql as $$
declare r text;
begin
  perform tests.login(p_user, p_email);
  execute 'select (' || p_expr || ')::text' into r;
  perform tests.logout();
  return coalesce(r, '(null)');
exception when others then
  perform tests.logout();
  return 'ERROR: ' || sqlerrm;
end $$;
create function tests.f(p_user uuid, p_email text, p_expr text, p_path text[]) returns text language plpgsql as $$
declare r text;
begin
  perform tests.login(p_user, p_email);
  execute 'select (' || p_expr || ') #>> $1' into r using p_path;
  perform tests.logout();
  return coalesce(r, '(null)');
exception when others then
  perform tests.logout();
  return 'ERROR: ' || sqlerrm;
end $$;
create function tests.svc(p_expr text) returns text language plpgsql as $$
declare r text;
begin
  perform tests.login_service();
  execute 'select (' || p_expr || ')::text' into r;
  perform tests.logout();
  return coalesce(r, '(null)');
exception when others then
  perform tests.logout();
  return 'ERROR: ' || sqlerrm;
end $$;
-- A booking, from the request to the acceptance (the customer's older requests are moved a few days back so the daily limit never gets in the way).
create function tests.mk(c uuid, c_e text, prov uuid, pu uuid, pe text, p_day date, p_total int, p_dep int, p_due date) returns uuid language plpgsql as $$
declare rq uuid;
begin
  rq := (tests.f(c, c_e, format($q$public.pro_request_create(%L, null, %L, null, null, 50, 'A job for the test', null)$q$, prov, p_day), '{id}'))::uuid;
  perform tests.q(pu, pe, format($q$public.pro_quote_send(%L, %L, %s, %s, %s, 'What is included in this job', 5)$q$, prov, rq, p_total, p_dep, case when p_due is null then 'null' else quote_literal(p_due) end));
  update public.site_pro_requests set created_at = created_at - interval '3 days' where client = c;
  return (tests.f(c, c_e, format($q$public.pro_quote_accept(%L)$q$, rq), '{id}'))::uuid;
end $$;
-- A payment of the whole amount asked for now, taken (answers what the database said).
create function tests.pay(c uuid, c_e text, bk uuid, p_session text) returns text language plpgsql as $$
declare j jsonb; pid uuid;
begin
  j := tests.q(c, c_e, format($q$public.pro_payment_begin(%L)$q$, bk))::jsonb;
  pid := (j ->> 'payment_id')::uuid;
  perform tests.svc(format($q$public.pro_payment_attach(%L, %L, now() + interval '31 minutes')$q$, pid, p_session));
  return tests.svc(format($q$public.pro_payment_paid(%L, %L, %s)$q$, p_session, 'pi_' || p_session, j ->> 'amount_cents'));
end $$;

do $$
declare
  admin_u constant uuid := '00000000-0000-0000-0000-0000000000a2';
  adm constant text := 'admin@test.example';
  ann constant uuid := '00000000-0000-0000-0000-0000000009c1';
  bob constant uuid := '00000000-0000-0000-0000-0000000009c2';
  dee constant uuid := '00000000-0000-0000-0000-0000000009c3';   -- a DJ and a photographer
  gus constant uuid := '00000000-0000-0000-0000-0000000009c4';   -- another professional
  orgu constant uuid := '00000000-0000-0000-0000-0000000009c5';  -- runs an event group
  a_e constant text := 'ann@edge.example'; b_e constant text := 'bob@edge.example'; d_e constant text := 'dee@edge.example'; g_e constant text := 'gus@edge.example'; o_e constant text := 'orgu@edge.example';
  p_ann uuid; p_dj uuid; p_ph uuid; p_gus uuid; p_grp uuid; org uuid;
  sv uuid; svg uuid; dsp uuid; rq uuid; rq2 uuid; bk uuid; bk2 uuid; bk3 uuid; pid uuid; q uuid;
  j jsonb; r text; n int;
begin
  insert into auth.users (id, email) values (ann, a_e), (bob, b_e), (dee, d_e), (gus, g_e), (orgu, o_e);
  insert into public.profiles (id, name, email) values (ann, 'Ann Lee', a_e), (bob, 'Bob Ray', b_e), (dee, 'Dee Dee', d_e), (gus, 'Gus Gray', g_e), (orgu, 'Org U', o_e);
  perform tests.login(admin_u, adm); perform public.cms_set_feature('social', true); perform public.cms_set_feature('marketplace', true);
  perform public.cms_publish_rules('Be kind to people. No spam. No hate. Respect each other.'); perform public.cms_set_banned_term('forbiddenword', true); perform tests.logout();
  perform tests.login(ann, a_e); perform public.save_my_profile('Ann Lee', 'annedge', 'Toronto'); perform public.profile_save_personal('public'); perform public.rules_accept(2);
  perform tests.login(bob, b_e); perform public.save_my_profile('Bob Ray', 'bobedge', 'Toronto'); perform public.profile_save_personal('public'); perform public.rules_accept(2);
  perform tests.login(dee, d_e); perform public.save_my_profile('Dee Dee', 'deeedge', 'Toronto'); perform public.profile_save_personal('public'); perform public.rules_accept(2);
  perform public.profile_create_business('dj', 'DJ Dee', 'djdeeedge'); perform public.profile_create_business('photographer', 'Dee Photos', 'deephotosedge');
  perform tests.login(gus, g_e); perform public.save_my_profile('Gus Gray', 'gusedge', 'Toronto'); perform public.profile_save_personal('public'); perform public.rules_accept(2);
  perform public.profile_create_business('mc', 'MC Gus', 'mcgusedge');
  perform tests.login(orgu, o_e); perform public.save_my_profile('Org U', 'orguedge', 'Toronto'); perform public.profile_save_personal('public');
  org := public.create_organization('Night Org', 'organizer'); perform public.profile_create_business('event_group', 'Night Crew', 'nightcrewedge', null, null, org);
  perform tests.logout();
  select id into p_ann from public.site_profiles where user_id = ann and kind = 'personal';
  select id into p_dj from public.site_profiles where handle = 'djdeeedge'; select id into p_ph from public.site_profiles where handle = 'deephotosedge';
  select id into p_gus from public.site_profiles where handle = 'mcgusedge'; select id into p_grp from public.site_profiles where handle = 'nightcrewedge';

  ---------------------------------------------------------------- who counts as a professional
  perform tests.assert_eq('an event group is not a professional', tests.q(ann, a_e, format($q$public.pro_request_create(%L, null, current_date + 40, null, null, 50, 'Please come', null)$q$, p_grp)), 'ERROR: This professional is not available.');
  update public.site_profiles set status = 'suspended' where id = p_gus;
  perform tests.assert_eq('a suspended professional cannot be hired', tests.q(ann, a_e, format($q$public.pro_request_create(%L, null, current_date + 40, null, null, 50, 'Please come', null)$q$, p_gus)), 'ERROR: This professional is not available.');
  perform tests.assert_eq('...nor sell', tests.q(gus, g_e, format($q$public.pro_service_save(%L, null, 'MC for hire', null, null, null)$q$, p_gus)), 'ERROR: You cannot act as this profile.');
  update public.site_profiles set status = 'active' where id = p_gus;
  -- a service that sits on a club's profile is never offered
  insert into public.site_pro_services (profile, title) values (p_grp, 'Not a service');
  perform tests.assert_eq('services of an event group are not listed', tests.q(ann, a_e, format($q$public.pro_services_of(%L)$q$, p_grp)), '[]');

  ---------------------------------------------------------------- services on their edges
  perform tests.assert_eq('a name of 80 characters is fine', tests.f(dee, d_e, format($q$public.pro_service_save(%L, null, %L, null, null, null)$q$, p_dj, repeat('n', 80)), '{title}'), repeat('n', 80));
  perform tests.assert_eq('...81 is not', tests.q(dee, d_e, format($q$public.pro_service_save(%L, null, %L, null, null, null)$q$, p_dj, repeat('n', 81))), 'ERROR: Give the service a name of 3 to 80 characters.');
  perform tests.assert_eq('...nor a banned word in the description', tests.q(dee, d_e, format($q$public.pro_service_save(%L, null, 'DJ set', 'Includes forbiddenword', null, null)$q$, p_dj)), 'ERROR: That wording is not allowed here.');
  perform tests.assert_eq('...nor in the price note', tests.q(dee, d_e, format($q$public.pro_service_save(%L, null, 'DJ set', null, null, 'forbiddenword')$q$, p_dj)), 'ERROR: That wording is not allowed here.');
  perform tests.assert_eq('...a price of nothing is allowed (on request)', tests.f(dee, d_e, format($q$public.pro_service_save(%L, null, 'Free consultation', null, 0, null)$q$, p_dj), '{from_cents}'), '0');
  perform tests.assert_eq('...and the top price', tests.f(dee, d_e, format($q$public.pro_service_save(%L, null, 'Festival headline', null, 5000000, null)$q$, p_dj), '{from_cents}'), '5000000');
  for n in 1..16 loop
    perform tests.q(dee, d_e, format($q$public.pro_service_save(%L, null, 'Service number %s', null, null, null)$q$, p_dj, n));
  end loop;
  perform tests.assert_eq('the twentieth service is allowed', tests.f(dee, d_e, format($q$public.pro_service_save(%L, null, 'The twentieth', null, null, null)$q$, p_dj), '{title}'), 'The twentieth');
  perform tests.assert_eq('...and the next is not', tests.q(dee, d_e, format($q$public.pro_service_save(%L, null, 'The twenty-first', null, null, null)$q$, p_dj)), 'ERROR: A profile can list up to 20 services.');
  delete from public.site_pro_services where profile = p_dj;
  sv := (tests.f(dee, d_e, format($q$public.pro_service_save(%L, null, 'Wedding DJ set', 'Four hours', 100000, null)$q$, p_dj), '{id}'))::uuid;
  svg := (tests.f(gus, g_e, format($q$public.pro_service_save(%L, null, 'MC for an evening', null, null, null)$q$, p_gus), '{id}'))::uuid;
  perform tests.assert_eq('today can be a day off', tests.q(dee, d_e, format($q$public.pro_busy_set(%L, current_date, true)$q$, p_dj)), '');
  perform tests.q(dee, d_e, format($q$public.pro_busy_set(%L, current_date, false)$q$, p_dj));
  insert into public.site_pro_busy (profile, day) values (p_dj, current_date + 500);
  perform tests.assert_eq('a window is at most 400 days, however many are asked for', tests.q(ann, a_e, format($q$public.pro_busy_days(%L, current_date, 1000)$q$, p_dj)), '[]');
  perform tests.assert_eq('...and a window that reaches it shows it', tests.q(ann, a_e, format($q$public.pro_busy_days(%L, current_date + 450, 100)$q$, p_dj)), format('["%s"]', current_date + 500));
  delete from public.site_pro_busy where profile = p_dj;

  ---------------------------------------------------------------- requests on their edges
  perform tests.assert_eq('a service of another professional is not this one''s', tests.q(ann, a_e, format($q$public.pro_request_create(%L, %L, current_date + 40, null, null, 50, 'Please come', null)$q$, p_dj, svg)), 'ERROR: That service is not available.');
  perform tests.assert_eq('a message of 1001 characters', tests.q(ann, a_e, format($q$public.pro_request_create(%L, null, current_date + 40, null, null, 50, %L, null)$q$, p_dj, repeat('m', 1001))), 'ERROR: Tell them about the job in 3 to 1000 characters.');
  perform tests.assert_eq('100,001 guests', tests.q(ann, a_e, format($q$public.pro_request_create(%L, null, current_date + 40, null, null, 100001, 'Big one', null)$q$, p_dj)), 'ERROR: Choose a number of guests between 1 and 100,000.');
  perform tests.assert_eq('a budget of -1', tests.q(ann, a_e, format($q$public.pro_request_create(%L, null, current_date + 40, null, null, 50, 'Small one', -1)$q$, p_dj)), 'ERROR: Choose a budget between 0 and 500,000.00.');
  perform tests.assert_eq('a budget over 500,000.00', tests.q(ann, a_e, format($q$public.pro_request_create(%L, null, current_date + 40, null, null, 50, 'Large one', 50000001)$q$, p_dj)), 'ERROR: Choose a budget between 0 and 500,000.00.');
  rq := (tests.f(ann, a_e, format($q$public.pro_request_create(%L, %L, current_date + 41, null, null, 100000, %L, 0)$q$, p_dj, sv, repeat('m', 1000)), '{id}'))::uuid;
  perform tests.assert_true('the largest guest count, a budget of nothing and a message of 1000 characters are fine', rq is not null);
  perform tests.q(dee, d_e, format($q$public.pro_quote_send(%L, %L, 100000, 30000, %L, 'Four hours of music', 5)$q$, p_dj, rq, current_date + 30));
  perform tests.assert_eq('a day twice is also refused while the first has a quote', tests.q(ann, a_e, format($q$public.pro_request_create(%L, null, current_date + 41, null, null, 50, 'Again please', null)$q$, p_dj)), 'ERROR: You already have a request open with this professional for that day.');
  update public.site_pro_requests set created_at = now() - interval '2 hours' where id = rq;
  for n in 1..4 loop
    perform tests.q(ann, a_e, format($q$public.pro_request_create(%L, null, current_date + 50 + %s, null, null, 50, 'Request number %s', null)$q$, p_dj, n, n));
  end loop;
  update public.site_pro_requests set created_at = now() - interval '2 hours' where client = ann;
  perform tests.assert_eq('requests made hours ago still count against today', tests.q(ann, a_e, format($q$public.pro_request_create(%L, null, current_date + 60, null, null, 50, 'One more', null)$q$, p_dj)), 'ERROR: You have sent a lot of requests today. Try again tomorrow.');
  update public.site_pro_requests set created_at = now() - interval '25 hours' where client = ann;
  delete from public.site_pro_requests where client = ann and id <> rq;
  update public.site_pro_requests set created_at = now() - interval '3 days' where id = rq;

  -- who may do what to a request
  perform tests.assert_eq('another profile of the same login cannot withdraw a quote', tests.q(dee, d_e, format($q$public.pro_quote_withdraw(%L, %L)$q$, p_ph, rq)), 'ERROR: This request is not available.');
  perform tests.assert_eq('...nor decline the request', tests.q(dee, d_e, format($q$public.pro_request_decline(%L, %L, 'no')$q$, p_ph, rq)), 'ERROR: This request is not available.');
  perform tests.assert_eq('...nor can a customer decline it for the professional', tests.q(ann, a_e, format($q$public.pro_request_decline(%L, %L, 'no')$q$, p_dj, rq)), 'ERROR: You cannot act as this profile.');
  perform tests.assert_eq('a note over 300 characters', tests.q(dee, d_e, format($q$public.pro_request_decline(%L, %L, %L)$q$, p_dj, rq, repeat('n', 301))), 'ERROR: Keep the note to 300 characters.');
  perform tests.assert_eq('...a banned word in it', tests.q(dee, d_e, format($q$public.pro_request_decline(%L, %L, 'forbiddenword')$q$, p_dj, rq)), 'ERROR: That wording is not allowed here.');
  perform tests.assert_eq('the professional declines: the quote goes with it', tests.f(dee, d_e, format($q$public.pro_request_decline(%L, %L, 'I am away')$q$, p_dj, rq), '{status}'), 'declined');
  perform tests.assert_eq('...the quote is withdrawn', (select status from public.site_pro_quotes where request = rq), 'withdrawn');
  perform tests.assert_eq('...the customer sees why', tests.f(ann, a_e, format($q$public.pro_request_get(%L)$q$, rq), '{decline_note}'), 'I am away');
  perform tests.assert_eq('...a closed request cannot be declined again', tests.q(dee, d_e, format($q$public.pro_request_decline(%L, %L, 'again')$q$, p_dj, rq)), 'ERROR: This request is closed.');
  perform tests.assert_eq('...or quoted', tests.q(dee, d_e, format($q$public.pro_quote_send(%L, %L, 100000, 30000, %L, 'Four hours of music', 5)$q$, p_dj, rq, current_date + 30)), 'ERROR: This request is closed.');
  perform tests.assert_eq('...or withdrawn by the customer', tests.q(ann, a_e, format($q$public.pro_request_withdraw(%L)$q$, rq)), 'ERROR: This request is closed.');
  rq2 := (tests.f(ann, a_e, format($q$public.pro_request_create(%L, null, current_date + 70, null, null, 50, 'To be taken back', null)$q$, p_dj), '{id}'))::uuid;
  perform tests.assert_eq('a stranger cannot withdraw it', tests.q(bob, b_e, format($q$public.pro_request_withdraw(%L)$q$, rq2)), 'ERROR: This request is not available.');
  perform tests.assert_eq('the customer can', tests.f(ann, a_e, format($q$public.pro_request_withdraw(%L)$q$, rq2), '{status}'), 'withdrawn');
  rq2 := (tests.f(ann, a_e, format($q$public.pro_request_create(%L, null, current_date + 71, null, null, 50, 'To be quoted', null)$q$, p_dj), '{id}'))::uuid;
  update public.site_pro_requests set event_date = current_date where id = rq2;
  perform tests.assert_eq('a quote for a date that is today or past', tests.q(dee, d_e, format($q$public.pro_quote_send(%L, %L, 100000, 30000, %L, 'Four hours of music', 5)$q$, p_dj, rq2, current_date - 2)), 'ERROR: The date of this request has passed.');
  update public.site_pro_requests set event_date = current_date + 71 where id = rq2;

  -- quotes on their edges
  perform tests.assert_eq('a deposit just under a tenth (rounded up) is refused', tests.q(dee, d_e, format($q$public.pro_quote_send(%L, %L, 100005, 10000, %L, 'Four hours of music', 5)$q$, p_dj, rq2, current_date + 60)), 'ERROR: The deposit must be at least a tenth of the total, and no more than the total.');
  perform tests.assert_eq('a scope of 9 characters', tests.q(dee, d_e, format($q$public.pro_quote_send(%L, %L, 100000, 30000, %L, '123456789', 5)$q$, p_dj, rq2, current_date + 60)), 'ERROR: Say what is included in 10 to 1500 characters.');
  perform tests.assert_eq('a scope of 1501', tests.q(dee, d_e, format($q$public.pro_quote_send(%L, %L, 100000, 30000, %L, %L, 5)$q$, p_dj, rq2, current_date + 60, repeat('s', 1501))), 'ERROR: Say what is included in 10 to 1500 characters.');
  perform tests.q(dee, d_e, format($q$public.pro_quote_send(%L, %L, 100005, 10001, %L, %L, 5)$q$, p_dj, rq2, current_date + 60, repeat('s', 1500)));
  perform tests.assert_eq('the smallest deposit that rounds up and the longest scope are fine, and the quote stays open the days asked', (select (valid_until > now() + interval '4 days 23 hours' and valid_until < now() + interval '5 days 1 hour')::text from public.site_pro_quotes where request = rq2 and status = 'sent'), 'true');
  perform tests.assert_eq('the live quote is the one shown', tests.f(ann, a_e, format($q$public.pro_request_get(%L)$q$, rq2), '{quote,deposit_cents}'), '10001');

  ---------------------------------------------------------------- accepting, on its edges
  update public.site_pro_requests set event_date = current_date - 1 where id = rq2;
  perform tests.assert_eq('a date that has passed since the quote', tests.q(ann, a_e, format($q$public.pro_quote_accept(%L)$q$, rq2)), 'ERROR: The date of this job has passed.');
  update public.site_pro_requests set event_date = current_date + 71 where id = rq2;
  update public.site_profiles set status = 'suspended' where id = p_dj;
  perform tests.assert_eq('a professional who has been suspended since', tests.q(ann, a_e, format($q$public.pro_quote_accept(%L)$q$, rq2)), 'ERROR: This professional is not available.');
  update public.site_profiles set status = 'active' where id = p_dj;
  bk := (tests.f(ann, a_e, format($q$public.pro_quote_accept(%L)$q$, rq2), '{id}'))::uuid;
  perform tests.assert_eq('accepted: the quote is marked accepted and shown as it was', tests.f(ann, a_e, format($q$public.pro_request_get(%L)$q$, rq2), '{quote,status}'), 'accepted');
  perform tests.assert_eq('...the booking has 24 hours to be paid', (select (pay_by > now() + interval '23 hours 59 minutes' and pay_by < now() + interval '24 hours 1 minute')::text from public.site_pro_bookings where id = bk), 'true');
  perform tests.assert_eq('...the customer''s view carries no client', tests.f(ann, a_e, format($q$public.pro_booking_get(%L)$q$, bk), '{client}'), '(null)');
  perform tests.assert_eq('...the professional''s view names the customer', tests.f(dee, d_e, format($q$public.pro_booking_get(%L)$q$, bk), '{client,name}'), 'Ann Lee');

  ---------------------------------------------------------------- the days a booking holds
  perform tests.assert_eq('a booking that waits for its deposit holds the day', tests.q(bob, b_e, format($q$public.pro_busy_days(%L, current_date + 71, 1)$q$, p_dj)), format('["%s"]', current_date + 71));
  perform tests.assert_eq('...only for this professional', tests.q(bob, b_e, format($q$public.pro_busy_days(%L, current_date + 71, 1)$q$, p_ph)), '[]');
  perform tests.assert_eq('...and the other profile of the same login can be hired that day', tests.f(bob, b_e, format($q$public.pro_request_create(%L, null, current_date + 71, null, null, 50, 'Photos please', null)$q$, p_ph), '{status}'), 'requested');
  perform tests.pay(ann, a_e, bk, 'cs_hold1');
  perform tests.assert_eq('once it is paid nobody else can ask for the day', tests.q(bob, b_e, format($q$public.pro_request_create(%L, null, current_date + 71, null, null, 50, 'Same day please', null)$q$, p_dj)), 'ERROR: This professional is not free on that day.');
  perform tests.assert_eq('once it is paid the day is still held', tests.q(bob, b_e, format($q$public.pro_busy_days(%L, current_date + 71, 1)$q$, p_dj)), format('["%s"]', current_date + 71));
  update public.site_pro_bookings set event_date = current_date - 1 where id = bk;
  update public.site_pro_bookings set status = 'disputed' where id = bk;
  update public.site_pro_bookings set event_date = current_date + 71 where id = bk;
  perform tests.assert_eq('...and while it is in dispute', tests.q(bob, b_e, format($q$public.pro_busy_days(%L, current_date + 71, 1)$q$, p_dj)), format('["%s"]', current_date + 71));
  perform tests.assert_eq('...when nobody else can ask for it either', tests.q(bob, b_e, format($q$public.pro_request_create(%L, null, current_date + 71, null, null, 50, 'Same day please', null)$q$, p_dj)), 'ERROR: This professional is not free on that day.');
  update public.site_pro_bookings set status = 'cancelled', cancelled_at = now(), cancelled_by = 'system' where id = bk;
  perform tests.assert_eq('...but not once it is cancelled', tests.q(bob, b_e, format($q$public.pro_busy_days(%L, current_date + 71, 1)$q$, p_dj)), '[]');
  update public.site_pro_bookings set status = 'awaiting_deposit', cancelled_at = null, cancelled_by = null, pay_by = now() - interval '1 minute' where id = bk;
  perform tests.assert_eq('...nor when it waited for a deposit that never came', tests.q(bob, b_e, format($q$public.pro_busy_days(%L, current_date + 71, 1)$q$, p_dj)), '[]');
  perform tests.assert_eq('...and a request for that day is accepted again', tests.f(bob, b_e, format($q$public.pro_request_create(%L, null, current_date + 71, null, null, 50, 'This day is free again', null)$q$, p_dj), '{status}'), 'requested');
  delete from public.site_pro_bookings where id = bk;

  ---------------------------------------------------------------- paying, on its edges
  bk := tests.mk(ann, a_e, p_dj, dee, d_e, current_date + 80, 100000, 30000, current_date + 70);
  j := tests.q(ann, a_e, format($q$public.pro_payment_begin(%L)$q$, bk))::jsonb;
  pid := (j ->> 'payment_id')::uuid;
  perform tests.svc(format($q$public.pro_payment_attach(%L, 'cs_edge1', now() + interval '31 minutes')$q$, pid));
  perform tests.assert_eq('a payment page that lapsed is replaced: a second payment, the first void', (select status from public.site_pro_payments where id = pid), 'pending');
  update public.site_pro_payments set pending_until = now() - interval '1 minute' where id = pid;
  j := tests.q(ann, a_e, format($q$public.pro_payment_begin(%L)$q$, bk))::jsonb;
  perform tests.assert_eq('...the old one is void, the new one is another', (select status from public.site_pro_payments where id = pid) || '/' || ((j ->> 'payment_id')::uuid <> pid)::text || '/' || (j ->> 'pending_session' is null)::text, 'void/true/true');
  perform tests.assert_eq('a payment that was paid cannot be given a page', tests.svc(format($q$public.pro_payment_attach(%L, 'cs_again', now())$q$, pid)), 'ERROR: this payment cannot be started now');
  perform tests.assert_eq('...and a page needs a session', tests.svc(format($q$public.pro_payment_attach(%L, '  ', now())$q$, (j ->> 'payment_id')::uuid)), 'ERROR: a Stripe session is needed');
  perform tests.assert_eq('a payment of nothing is not a payment', tests.svc($q$public.pro_payment_paid('cs_edge1', 'pi_x', 0)$q$), 'ERROR: an amount is needed');
  -- the old page is paid after all: the payment is void, so it is paid back in full and nothing is counted
  r := tests.svc($q$public.pro_payment_paid('cs_edge1', 'pi_edge1', 30000)$q$);
  perform tests.assert_eq('money paid on a page that had lapsed is paid back in full', (r::jsonb ->> 'result') || '/' || (r::jsonb ->> 'refund_cents') || '/' || (select paid_cents from public.site_pro_bookings where id = bk), 'refund/30000/0');
  -- the booking waited more than an hour past its time
  perform tests.svc(format($q$public.pro_payment_attach(%L, 'cs_edge2', now() + interval '31 minutes')$q$, (j ->> 'payment_id')::uuid));
  update public.site_pro_bookings set pay_by = now() - interval '2 hours' where id = bk;
  r := tests.svc($q$public.pro_payment_paid('cs_edge2', 'pi_edge2', 30000)$q$);
  perform tests.assert_eq('a payment that arrives more than an hour after the time to pay is paid back in full', (r::jsonb ->> 'result') || '/' || (select status from public.site_pro_bookings where id = bk), 'refund/awaiting_deposit');
  update public.site_pro_bookings set pay_by = now() - interval '30 minutes' where id = bk;
  perform tests.svc(format($q$public.pro_payment_attach(%L, 'cs_edge3', now() + interval '31 minutes')$q$, (select id from public.site_pro_payments where booking = bk and status = 'pending' limit 1)));
  insert into public.site_pro_payments (booking, kind, amount_cents, status, stripe_session_id, pending_until) values (bk, 'deposit', 30000, 'pending', 'cs_edge4', now() + interval '20 minutes');
  r := tests.svc($q$public.pro_payment_paid('cs_edge4', 'pi_edge4', 30000)$q$);
  perform tests.assert_eq('...but within the hour it still counts (the page was opened in time)', (r::jsonb ->> 'result') || '/' || (select status from public.site_pro_bookings where id = bk), 'applied/active');

  -- two pages paid for the same money: the second can only be used up to what is left
  bk2 := tests.mk(bob, b_e, p_dj, dee, d_e, current_date + 81, 100000, 30000, current_date + 70);
  j := tests.q(bob, b_e, format($q$public.pro_payment_begin(%L)$q$, bk2))::jsonb;
  perform tests.svc(format($q$public.pro_payment_attach(%L, 'cs_two1', now() + interval '31 minutes')$q$, (j ->> 'payment_id')::uuid));
  insert into public.site_pro_payments (booking, kind, amount_cents, status, stripe_session_id, pending_until) values (bk2, 'balance', 90000, 'pending', 'cs_two2', now() + interval '20 minutes');
  perform tests.svc($q$public.pro_payment_paid('cs_two1', 'pi_two1', 30000)$q$);
  r := tests.svc($q$public.pro_payment_paid('cs_two2', 'pi_two2', 90000)$q$);
  perform tests.assert_eq('only what was left is counted, the surplus is paid back', (r::jsonb ->> 'result') || '/' || (r::jsonb ->> 'applied_cents') || '/' || (r::jsonb ->> 'refund_cents') || '/' || (select paid_cents from public.site_pro_bookings where id = bk2), 'applied/70000/20000/100000');
  perform tests.assert_eq('...the surplus is due on that payment', (select refund_due_cents from public.site_pro_payments where stripe_session_id = 'cs_two2'), 20000);
  perform tests.assert_eq('a payment on a booking that is already paid in full is paid back whole', (r::jsonb ->> 'result'), 'applied');
  insert into public.site_pro_payments (booking, kind, amount_cents, status, stripe_session_id, pending_until) values (bk2, 'balance', 5000, 'pending', 'cs_two3', now() + interval '20 minutes');
  r := tests.svc($q$public.pro_payment_paid('cs_two3', 'pi_two3', 5000)$q$);
  perform tests.assert_eq('...nothing is counted twice', (r::jsonb ->> 'result') || '/' || (r::jsonb ->> 'refund_cents') || '/' || (select paid_cents from public.site_pro_bookings where id = bk2), 'refund/5000/100000');
  perform tests.assert_eq('the partly paid back payment lists only what is left', tests.svc($q$(select r.cents from public.pro_refunds_due() r where r.payment_id = (select id from public.site_pro_payments where stripe_session_id = 'cs_two2'))$q$), '20000');
  perform tests.svc(format($q$public.pro_payment_refunded(%L, 're_part', 8000)$q$, (select id from public.site_pro_payments where stripe_session_id = 'cs_two2')));
  perform tests.assert_eq('...after 80.00 is paid back, 120.00 remains', tests.svc($q$(select r.cents from public.pro_refunds_due() r where r.payment_id = (select id from public.site_pro_payments where stripe_session_id = 'cs_two2'))$q$), '12000');

  -- a booking that was cancelled by hand while a page was open
  bk3 := tests.mk(ann, a_e, p_dj, dee, d_e, current_date + 82, 100000, 30000, current_date + 70);
  j := tests.q(ann, a_e, format($q$public.pro_payment_begin(%L)$q$, bk3))::jsonb;
  perform tests.svc(format($q$public.pro_payment_attach(%L, 'cs_can1', now() + interval '31 minutes')$q$, (j ->> 'payment_id')::uuid));
  update public.site_pro_payments set status = 'pending' where stripe_session_id = 'cs_can1';
  update public.site_pro_bookings set status = 'cancelled', cancelled_at = now(), cancelled_by = 'system' where id = bk3;
  r := tests.svc($q$public.pro_payment_paid('cs_can1', 'pi_can1', 30000)$q$);
  perform tests.assert_eq('a payment for a booking that was cancelled is paid back in full', (r::jsonb ->> 'result') || '/' || (select paid_cents from public.site_pro_bookings where id = bk3), 'refund/0');
  perform tests.assert_eq('...and a cancelled booking can no longer be paid', tests.q(ann, a_e, format($q$public.pro_payment_begin(%L)$q$, bk3)), 'ERROR: This booking cannot be paid now.');

  ---------------------------------------------------------------- cancelling, on its edges
  -- two payments, cancelled early: both are paid back, newest first, each only what it took
  bk := tests.mk(ann, a_e, p_dj, dee, d_e, current_date + 90, 100000, 30000, current_date + 80);
  perform tests.pay(ann, a_e, bk, 'cs_a1');
  perform tests.pay(ann, a_e, bk, 'cs_a2');
  perform tests.assert_eq('a stranger cannot cancel', tests.q(bob, b_e, format($q$public.pro_booking_cancel(%L, 'x')$q$, bk)), 'ERROR: This booking is not available.');
  perform tests.q(ann, a_e, format($q$public.pro_booking_cancel(%L, 'plans changed')$q$, bk));
  perform tests.assert_eq('cancelled well ahead: all 1000.00 is paid back across both payments', (select string_agg(refund_due_cents::text, ',' order by paid_at desc) from public.site_pro_payments where booking = bk), '70000,30000');
  perform tests.assert_eq('...and no payout', (select count(*) from public.site_pro_payouts where booking = bk)::int, 0);
  -- exactly the free-cancellation number of days ahead is still free; one day less is not
  bk := tests.mk(ann, a_e, p_dj, dee, d_e, current_date + 7, 100000, 30000, current_date + 5);
  perform tests.pay(ann, a_e, bk, 'cs_b1');
  perform tests.q(ann, a_e, format($q$public.pro_booking_cancel(%L, 'x')$q$, bk));
  perform tests.assert_eq('seven days ahead is still free', (select refund_due_cents from public.site_pro_payments where booking = bk), 30000);
  bk := tests.mk(ann, a_e, p_dj, dee, d_e, current_date + 6, 100000, 30000, current_date + 4);
  perform tests.pay(ann, a_e, bk, 'cs_b2');
  perform tests.q(ann, a_e, format($q$public.pro_booking_cancel(%L, 'x')$q$, bk));
  perform tests.assert_eq('six days ahead is late: the 30% minimum is kept (the deposit was 30%)', (select refund_due_cents from public.site_pro_payments where booking = bk) || '/' || (select gross_cents from public.site_pro_payouts where booking = bk), '0/30000');
  -- late, with a big deposit: the deposit is kept, not 30%
  bk := tests.mk(ann, a_e, p_dj, dee, d_e, current_date + 5, 100000, 50000, current_date + 3);
  perform tests.pay(ann, a_e, bk, 'cs_b3');
  perform tests.pay(ann, a_e, bk, 'cs_b4');
  perform tests.q(ann, a_e, format($q$public.pro_booking_cancel(%L, 'x')$q$, bk));
  perform tests.assert_eq('a late cancel keeps a deposit that is more than 30%: 500.00', (select gross_cents || '/' || net_cents from public.site_pro_payouts where booking = bk), '50000/47500');
  -- late, with only a small deposit paid: no more than what was paid is kept
  bk := tests.mk(ann, a_e, p_dj, dee, d_e, current_date + 4, 100000, 10000, current_date + 2);
  perform tests.pay(ann, a_e, bk, 'cs_b5');
  perform tests.q(ann, a_e, format($q$public.pro_booking_cancel(%L, 'x')$q$, bk));
  perform tests.assert_eq('...never more than was paid: 100.00 paid, 100.00 kept, nothing to pay back', (select gross_cents from public.site_pro_payouts where booking = bk) || '/' || (select refund_due_cents from public.site_pro_payments where booking = bk), '10000/0');
  -- a page that is open when the booking is cancelled is closed
  bk := tests.mk(bob, b_e, p_dj, dee, d_e, current_date + 95, 100000, 30000, current_date + 80);
  j := tests.q(bob, b_e, format($q$public.pro_payment_begin(%L)$q$, bk))::jsonb;
  perform tests.svc(format($q$public.pro_payment_attach(%L, 'cs_open1', now() + interval '31 minutes')$q$, (j ->> 'payment_id')::uuid));
  perform tests.q(bob, b_e, format($q$public.pro_booking_cancel(%L, 'x')$q$, bk));
  perform tests.assert_eq('cancelling closes the open payment page', (select status from public.site_pro_payments where id = (j ->> 'payment_id')::uuid), 'void');

  ---------------------------------------------------------------- after the job, on its edges
  bk := tests.mk(ann, a_e, p_dj, dee, d_e, current_date + 100, 100000, 30000, current_date + 90);
  perform tests.pay(ann, a_e, bk, 'cs_d1');
  update public.site_pro_bookings set event_date = current_date where id = bk;
  perform tests.assert_eq('not paid in full, it cannot be marked done', tests.q(dee, d_e, format($q$public.pro_booking_done(%L, %L)$q$, p_dj, bk)), 'ERROR: It has not been paid in full yet.');
  perform tests.assert_eq('...and a stranger cannot confirm', tests.q(bob, b_e, format($q$public.pro_booking_confirm(%L)$q$, bk)), 'ERROR: This booking is not available.');
  perform tests.pay(ann, a_e, bk, 'cs_d2');
  perform tests.q(dee, d_e, format($q$public.pro_booking_done(%L, %L)$q$, p_dj, bk));
  update public.site_pro_bookings set event_date = current_date - 7 where id = bk;
  perform tests.assert_eq('a dispute seven days after the job is still in time', tests.f(ann, a_e, format($q$public.pro_dispute_open(%L, '1234567890')$q$, bk), '{state}'), 'disputed');
  perform tests.assert_eq('...a dispute on a booking already disputed or closed is refused', tests.q(ann, a_e, format($q$public.pro_dispute_open(%L, 'Another long reason here')$q$, bk)), 'ERROR: This booking cannot be disputed now.');
  bk3 := tests.mk(ann, a_e, p_dj, dee, d_e, current_date + 110, 100000, 100000, null);
  perform tests.pay(ann, a_e, bk3, 'cs_e1');
  update public.site_pro_bookings set event_date = current_date where id = bk3;
  perform tests.assert_eq('a reason of nine characters', tests.q(ann, a_e, format($q$public.pro_dispute_open(%L, '123456789')$q$, bk3)), 'ERROR: Say what went wrong in 10 to 1000 characters.');
  perform tests.assert_eq('...and of 1001', tests.q(ann, a_e, format($q$public.pro_dispute_open(%L, %L)$q$, bk3, repeat('r', 1001))), 'ERROR: Say what went wrong in 10 to 1000 characters.');
  perform tests.assert_eq('...1000 is fine', tests.f(ann, a_e, format($q$public.pro_dispute_open(%L, %L)$q$, bk3, repeat('r', 1000)), '{state}'), 'disputed');
  bk3 := tests.mk(bob, b_e, p_dj, dee, d_e, current_date + 120, 100000, 100000, null);
  perform tests.q(bob, b_e, format($q$public.pro_booking_cancel(%L, 'x')$q$, bk3));
  perform tests.assert_eq('a cancelled booking cannot be disputed', tests.q(bob, b_e, format($q$public.pro_dispute_open(%L, 'Because I would like to')$q$, bk3)), 'ERROR: This booking cannot be disputed now.');

  ---------------------------------------------------------------- the staff, on their edges
  perform tests.assert_eq('a payout list needs a known status', tests.q(admin_u, adm, $q$public.cms_pro_payouts('x')$q$), 'ERROR: Choose releasable, paid or all.');
  perform tests.assert_eq('...for admins only', tests.q(ann, a_e, $q$public.cms_pro_payouts('all')$q$), 'ERROR: Only a BottlesUp admin can see this.');
  bk := tests.mk(bob, b_e, p_dj, dee, d_e, current_date + 130, 100000, 100000, null);
  perform tests.pay(bob, b_e, bk, 'cs_f1');
  update public.site_pro_bookings set event_date = current_date - 1 where id = bk;
  perform tests.q(bob, b_e, format($q$public.pro_dispute_open(%L, 'The set was not what we agreed')$q$, bk));
  dsp := (select id from public.site_pro_disputes where booking = bk);
  perform tests.assert_eq('a part refund of nothing', tests.q(admin_u, adm, format($q$public.cms_pro_dispute_resolve(%L, 'refund_part', 0, 'half')$q$, dsp)), 'ERROR: A part refund must be more than nothing and less than everything paid (1,000.00).');
  perform tests.assert_eq('...a negative one', tests.q(admin_u, adm, format($q$public.cms_pro_dispute_resolve(%L, 'refund_part', -5, 'half')$q$, dsp)), 'ERROR: A part refund must be more than nothing and less than everything paid (1,000.00).');
  perform tests.assert_eq('...a refund of one cent is fine', tests.f(admin_u, adm, format($q$public.cms_pro_dispute_resolve(%L, 'refund_part', 1, 'tiny')$q$, dsp), '{refund_cents}'), '1');
  perform tests.assert_eq('...and the professional is released the rest', (select gross_cents from public.site_pro_payouts where booking = bk), 99999);

  ---------------------------------------------------------------- housekeeping, on its edges
  bk := tests.mk(ann, a_e, p_dj, dee, d_e, current_date + 140, 100000, 30000, current_date + 130);
  update public.site_pro_bookings set pay_by = now() - interval '30 minutes' where id = bk;
  perform tests.assert_eq('a booking that is a little late with its deposit is not yet cancelled', tests.svc('public.market_housekeeping()')::jsonb ->> 'lapsed', '0');
  update public.site_pro_bookings set pay_by = now() + interval '30 minutes' where id = bk;
  perform tests.assert_eq('...nor one that still has time', tests.svc('public.market_housekeeping()')::jsonb ->> 'lapsed', '0');
  update public.site_pro_bookings set pay_by = now() - interval '61 minutes' where id = bk;
  perform tests.assert_eq('...it is cancelled an hour after the time to pay', tests.svc('public.market_housekeeping()')::jsonb ->> 'lapsed', '1');
  -- the balance
  bk := tests.mk(ann, a_e, p_dj, dee, d_e, current_date + 150, 100000, 30000, current_date + 140);
  perform tests.pay(ann, a_e, bk, 'cs_g1');
  update public.site_pro_bookings set balance_due_by = current_date where id = bk;
  perform tests.assert_eq('a balance due today is not late yet', tests.svc('public.market_housekeeping()')::jsonb ->> 'balance_unpaid', '0');
  update public.site_pro_bookings set balance_due_by = current_date - 1 where id = bk;
  j := tests.svc('public.market_housekeeping()')::jsonb;
  perform tests.assert_eq('...yesterday it is: the deposit is kept even though the job is months away', (j ->> 'balance_unpaid') || '/' || (select gross_cents from public.site_pro_payouts where booking = bk), '1/30000');
  bk := tests.mk(ann, a_e, p_dj, dee, d_e, current_date + 151, 100000, 30000, current_date + 141);
  perform tests.pay(ann, a_e, bk, 'cs_g2');
  perform tests.pay(ann, a_e, bk, 'cs_g3');
  update public.site_pro_bookings set balance_due_by = current_date - 1 where id = bk;
  j := tests.svc('public.market_housekeeping()')::jsonb;
  perform tests.assert_eq('a booking paid in full is not cancelled for a balance date', (j ->> 'balance_unpaid') || '/' || (select status from public.site_pro_bookings where id = bk), '0/active');
  -- confirmation after a few days
  update public.site_pro_bookings set event_date = current_date - 1, provider_done_at = now() - interval '2 days' where id = bk;
  perform tests.assert_eq('marked done two days ago, it waits for the customer', tests.svc('public.market_housekeeping()')::jsonb ->> 'completed', '0');
  update public.site_pro_bookings set provider_done_at = now() - interval '4 days' where id = bk;
  j := tests.svc('public.market_housekeeping()')::jsonb;
  perform tests.assert_eq('...four days ago it is confirmed for them', (j ->> 'completed') || '/' || (select status from public.site_pro_bookings where id = bk), '1/completed');
  bk := tests.mk(bob, b_e, p_dj, dee, d_e, current_date + 152, 100000, 100000, null);
  perform tests.pay(bob, b_e, bk, 'cs_g4');
  update public.site_pro_bookings set event_date = current_date - 10 where id = bk;
  j := tests.svc('public.market_housekeeping()')::jsonb;
  perform tests.assert_eq('a job nobody marked done is not confirmed by time alone', (j ->> 'completed') || '/' || (select status from public.site_pro_bookings where id = bk), '0/active');
  -- old payment pages
  insert into public.site_pro_payments (booking, kind, amount_cents, status, stripe_session_id, created_at) values (bk, 'balance', 100, 'pending', 'cs_old', now() - interval '3 days');
  perform tests.svc('public.market_housekeeping()');
  perform tests.assert_eq('a payment page older than two days is closed', (select status from public.site_pro_payments where stripe_session_id = 'cs_old'), 'void');
  -- accounts that close, near the date
  bk := tests.mk(bob, b_e, p_ph, dee, d_e, current_date + 3, 100000, 30000, current_date + 1);
  perform tests.pay(bob, b_e, bk, 'cs_h1');
  delete from auth.users where id = dee;
  j := tests.svc('public.market_housekeeping()')::jsonb;
  perform tests.assert_eq('a professional whose account closed three days before the job: everything is paid back, however late', (select status || '/' || cancelled_by from public.site_pro_bookings where id = bk) || '/' || (select refund_due_cents from public.site_pro_payments where booking = bk) || '/' || (select count(*) from public.site_pro_payouts where booking = bk), 'cancelled/provider/30000/0');
  perform tests.assert_true('...and the others of that professional were cancelled in the same run', (j ->> 'accounts_gone')::int >= 1);
  update public.site_pro_bookings set provider = (select id from public.site_profiles where handle = 'mcgusedge') where id in (select id from public.site_pro_bookings where client = ann and status = 'active' limit 0);
  bk := tests.mk(bob, b_e, p_gus, gus, g_e, current_date + 3, 100000, 30000, current_date + 1);
  perform tests.pay(bob, b_e, bk, 'cs_h2');
  delete from auth.users where id = bob;
  j := tests.svc('public.market_housekeeping()')::jsonb;
  perform tests.assert_eq('a customer whose account closed three days before the job: the deposit is kept like any late cancel', (select status || '/' || cancelled_by from public.site_pro_bookings where id = bk) || '/' || (select gross_cents from public.site_pro_payouts where booking = bk), 'cancelled/client/30000');

  ---------------------------------------------------------------- a different commission for a while
  perform tests.assert_eq('the commission is the standard one to begin with', public.market_commission_bps(p_gus), 500);
  insert into public.site_commission_overrides (profile, commission_bps, until, source) values (p_gus, 0, now() + interval '30 days', 'subscription');
  perform tests.assert_eq('a subscription''s override replaces it', public.market_commission_bps(p_gus), 0);
  perform tests.assert_eq('...for that professional only', public.market_commission_bps(p_grp), 500);
  update public.site_commission_overrides set until = now() - interval '1 second' where profile = p_gus;
  perform tests.assert_eq('...and not once it has run out', public.market_commission_bps(p_gus), 500);
  update public.site_commission_overrides set until = now() + interval '1 day', commission_bps = 250, source = 'staff' where profile = p_gus;
  perform tests.assert_eq('staff can set another figure', public.market_commission_bps(p_gus), 250);
  delete from public.site_commission_overrides;
end $$;

rollback;
