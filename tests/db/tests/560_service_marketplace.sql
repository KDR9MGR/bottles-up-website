-- Hiring professionals. What matters most: only a professional profile sells services and only whoever runs it acts as it; a customer cannot hire themselves, someone who blocked them or on a
-- day that is taken; a quote is the professional's alone, one live at a time, and what the customer accepts is exactly what was quoted; money is added once per Stripe session and paid back
-- once per Stripe refund; cancelling pays back everything or keeps the deposit by the rules; nothing is released to the professional until the job is confirmed (or three days pass) and a dispute holds
-- it for BottlesUp's staff; every table is closed.
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
create function tests.svcf(p_expr text, p_path text[]) returns text language plpgsql as $$
declare r text;
begin
  perform tests.login_service();
  execute 'select (' || p_expr || ') #>> $1' into r using p_path;
  perform tests.logout();
  return coalesce(r, '(null)');
exception when others then
  perform tests.logout();
  return 'ERROR: ' || sqlerrm;
end $$;

do $$
declare
  admin_u constant uuid := '00000000-0000-0000-0000-0000000000a2';
  adm constant text := 'admin@test.example';
  ann constant uuid := '00000000-0000-0000-0000-0000000009b1';   -- a customer
  bob constant uuid := '00000000-0000-0000-0000-0000000009b2';   -- another customer
  dee constant uuid := '00000000-0000-0000-0000-0000000009b3';   -- the DJ
  eve constant uuid := '00000000-0000-0000-0000-0000000009b4';   -- a customer who blocked the DJ
  olly constant uuid := '00000000-0000-0000-0000-0000000009b5';  -- runs the club
  zed constant uuid := '00000000-0000-0000-0000-0000000009b6';   -- someone else
  a_e constant text := 'ann@pro.example'; b_e constant text := 'bob@pro.example'; d_e constant text := 'dee@pro.example'; e_e constant text := 'eve@pro.example';
  o_e constant text := 'olly@pro.example'; z_e constant text := 'zed@pro.example';
  p_ann uuid; p_bob uuid; p_dee uuid; p_eve uuid; p_dj uuid; p_club uuid; p_dj2 uuid;
  org uuid; va uuid;
  sv1 uuid; sv2 uuid; rq uuid; rq2 uuid; rq3 uuid; bk uuid; bk2 uuid; bk3 uuid; bk4 uuid; bk5 uuid; q1 uuid; pay1 uuid; pay2 uuid; pay3 uuid; po uuid; dsp uuid;
  d1 date := current_date + 30;
  r text; n int; j jsonb;
begin
  insert into auth.users (id, email) values (ann, a_e), (bob, b_e), (dee, d_e), (eve, e_e), (olly, o_e), (zed, z_e);
  insert into public.profiles (id, name, email) values (ann, 'Ann Lee', a_e), (bob, 'Bob Ray', b_e), (dee, 'Dee Dee', d_e), (eve, 'Eve Ng', e_e), (olly, 'Olly Owner', o_e), (zed, 'Zed Zed', z_e);
  perform tests.login(admin_u, adm); perform public.cms_set_feature('social', true); perform public.cms_publish_rules('Be kind to people. No spam. No hate. Respect each other.'); perform tests.logout();
  perform tests.login(ann, a_e); perform public.save_my_profile('Ann Lee', 'annpro', 'Toronto'); perform public.profile_save_personal('public'); perform public.rules_accept(2);
  perform tests.login(bob, b_e); perform public.save_my_profile('Bob Ray', 'bobpro', 'Toronto'); perform public.profile_save_personal('public'); perform public.rules_accept(2);
  perform tests.login(eve, e_e); perform public.save_my_profile('Eve Ng', 'evepro', 'Toronto'); perform public.profile_save_personal('public'); perform public.rules_accept(2);
  perform tests.login(dee, d_e); perform public.save_my_profile('Dee Dee', 'deepro', 'Toronto'); perform public.profile_save_personal('public'); perform public.rules_accept(2);
  perform public.profile_create_business('dj', 'DJ Dee', 'djdeepro');
  perform public.profile_create_business('photographer', 'Dee Photos', 'deephotos');
  perform tests.login(olly, o_e); perform public.save_my_profile('Olly Owner', 'ollypro', 'Toronto'); perform public.profile_save_personal('public');
  org := public.create_organization('Pro Club Co', 'venue_owner'); va := public.create_org_venue(org, 'Pro Club');
  perform tests.login(zed, z_e); perform public.save_my_profile('Zed Zed', 'zedpro', 'Toronto'); perform public.profile_save_personal('public');
  perform tests.logout();
  update public.site_venues set status = 'published' where id = va;
  select id into p_ann from public.site_profiles where user_id = ann and kind = 'personal'; select id into p_bob from public.site_profiles where user_id = bob and kind = 'personal';
  select id into p_eve from public.site_profiles where user_id = eve and kind = 'personal'; select id into p_dee from public.site_profiles where user_id = dee and kind = 'personal';
  select id into p_dj from public.site_profiles where handle = 'djdeepro'; select id into p_dj2 from public.site_profiles where handle = 'deephotos';
  perform tests.login(olly, o_e); perform public.profile_create_business('venue', 'Pro Club', 'proclub', null, null, null, va); perform tests.logout();
  select id into p_club from public.site_profiles where venue_id = va;
  perform tests.login(eve, e_e); perform public.block_set(p_eve, p_dj, true); perform tests.logout();

  ---------------------------------------------------------------- the switch
  perform tests.assert_eq('hiring is off at first', tests.q(ann, a_e, format($q$public.pro_request_create(%L, null, %L, null, null, null, 'Need a DJ', null)$q$, p_dj, d1)), 'ERROR: Hiring professionals is not open yet.');
  perform tests.assert_eq('...and so is selling', tests.q(dee, d_e, format($q$public.pro_service_save(%L, null, 'DJ set', null, null, null)$q$, p_dj)), 'ERROR: Hiring professionals is not open yet.');
  perform tests.login(admin_u, adm); perform public.cms_set_feature('marketplace', true); perform tests.logout();
  perform tests.login_anon();
  perform tests.assert_raises('a visitor cannot ask for anything', format($q$select public.pro_services_of(%L)$q$, p_dj), 'permission denied');
  perform tests.logout();

  ---------------------------------------------------------------- services
  perform tests.assert_eq('only a professional profile sells: not a club', tests.q(olly, o_e, format($q$public.pro_service_save(%L, null, 'Table service', null, null, null)$q$, p_club)), 'ERROR: Only a professional profile can do this.');
  perform tests.assert_eq('...not a personal profile', tests.q(dee, d_e, format($q$public.pro_service_save(%L, null, 'Table service', null, null, null)$q$, p_dee)), 'ERROR: Only a professional profile can do this.');
  perform tests.assert_eq('...and only as a profile you run', tests.q(ann, a_e, format($q$public.pro_service_save(%L, null, 'DJ set', null, null, null)$q$, p_dj)), 'ERROR: You cannot act as this profile.');
  perform tests.assert_eq('a name of 3 to 80 characters', tests.q(dee, d_e, format($q$public.pro_service_save(%L, null, 'DJ', null, null, null)$q$, p_dj)), 'ERROR: Give the service a name of 3 to 80 characters.');
  perform tests.assert_eq('...the description at most 1000', tests.q(dee, d_e, format($q$public.pro_service_save(%L, null, 'DJ set', %L, null, null)$q$, p_dj, repeat('x', 1001))), 'ERROR: Keep the description to 1000 characters.');
  perform tests.assert_eq('...the note at most 80', tests.q(dee, d_e, format($q$public.pro_service_save(%L, null, 'DJ set', null, null, %L)$q$, p_dj, repeat('x', 81))), 'ERROR: Keep the price note to 80 characters.');
  perform tests.assert_eq('...a price from 0 to 50,000.00', tests.q(dee, d_e, format($q$public.pro_service_save(%L, null, 'DJ set', null, 5000001, null)$q$, p_dj)), 'ERROR: Choose a price between 0 and 50,000.00.');
  perform tests.assert_eq('...and not a negative one', tests.q(dee, d_e, format($q$public.pro_service_save(%L, null, 'DJ set', null, -1, null)$q$, p_dj)), 'ERROR: Choose a price between 0 and 50,000.00.');
  perform tests.login(admin_u, adm); perform public.cms_set_banned_term('forbiddenword', true); perform tests.logout();
  perform tests.assert_eq('...and no banned words', tests.q(dee, d_e, format($q$public.pro_service_save(%L, null, 'A forbiddenword set', null, null, null)$q$, p_dj)), 'ERROR: That wording is not allowed here.');
  sv1 := (tests.f(dee, d_e, format($q$public.pro_service_save(%L, null, 'Wedding DJ set', 'Four hours with lights', 120000, 'from, per night')$q$, p_dj), '{id}'))::uuid;
  sv2 := (tests.f(dee, d_e, format($q$public.pro_service_save(%L, null, 'Club night', null, null, null, false)$q$, p_dj), '{id}'))::uuid;
  perform tests.assert_true('services were made', sv1 is not null and sv2 is not null);
  perform tests.assert_eq('anyone sees the active ones only', tests.q(ann, a_e, format($q$jsonb_array_length(public.pro_services_of(%L))$q$, p_dj)), '1');
  perform tests.assert_eq('...the professional sees all', tests.q(dee, d_e, format($q$jsonb_array_length(public.pro_services_of(%L))$q$, p_dj)), '2');
  perform tests.assert_eq('...someone who blocked the professional sees nothing', tests.q(eve, e_e, format($q$public.pro_services_of(%L)$q$, p_dj)), '[]');
  perform tests.assert_eq('...a club has no services', tests.q(ann, a_e, format($q$public.pro_services_of(%L)$q$, p_club)), '[]');
  perform tests.assert_eq('a service is changed in place', tests.f(dee, d_e, format($q$public.pro_service_save(%L, %L, 'Wedding DJ set (4h)', 'Four hours with lights', 125000, 'from', true)$q$, p_dj, sv1), '{title}'), 'Wedding DJ set (4h)');
  perform tests.assert_eq('...only by its own profile', tests.q(dee, d_e, format($q$public.pro_service_save(%L, %L, 'Taken over', null, null, null)$q$, p_dj2, sv1)), 'ERROR: That service is not available.');
  perform tests.assert_eq('a service of another profile cannot be removed', tests.q(dee, d_e, format($q$public.pro_service_remove(%L, %L)$q$, p_dj2, sv1)), 'ERROR: That service is not available.');
  perform tests.assert_eq('...a profile lists up to 20', (select count(*) from public.site_pro_services where profile = p_dj)::int, 2);
  for n in 1..18 loop
    perform tests.q(dee, d_e, format($q$public.pro_service_save(%L, null, 'Extra service %s', null, null, null)$q$, p_dj, n));
  end loop;
  perform tests.assert_eq('the twenty-first is refused', tests.q(dee, d_e, format($q$public.pro_service_save(%L, null, 'One too many', null, null, null)$q$, p_dj)), 'ERROR: A profile can list up to 20 services.');
  delete from public.site_pro_services where profile = p_dj and title like 'Extra service%';

  ---------------------------------------------------------------- days off
  perform tests.assert_eq('a day in the past', tests.q(dee, d_e, format($q$public.pro_busy_set(%L, current_date - 1, true)$q$, p_dj)), 'ERROR: Choose a day within the next two years.');
  perform tests.assert_eq('...a day too far', tests.q(dee, d_e, format($q$public.pro_busy_set(%L, current_date + 731, true)$q$, p_dj)), 'ERROR: Choose a day within the next two years.');
  perform tests.q(dee, d_e, format($q$public.pro_busy_set(%L, %L, true)$q$, p_dj, d1 + 5));
  perform tests.assert_eq('a busy day is listed', tests.q(ann, a_e, format($q$public.pro_busy_days(%L, current_date, 120)$q$, p_dj)), format('["%s"]', d1 + 5));
  perform tests.q(dee, d_e, format($q$public.pro_busy_set(%L, %L, false)$q$, p_dj, d1 + 5));
  perform tests.assert_eq('...and freed again', tests.q(ann, a_e, format($q$public.pro_busy_days(%L, current_date, 120)$q$, p_dj)), '[]');
  perform tests.assert_eq('only the professional sets it', tests.q(ann, a_e, format($q$public.pro_busy_set(%L, %L, true)$q$, p_dj, d1 + 5)), 'ERROR: You cannot act as this profile.');
  perform tests.q(dee, d_e, format($q$public.pro_busy_set(%L, %L, true)$q$, p_dj, d1 + 9));

  ---------------------------------------------------------------- requests
  perform tests.assert_eq('a day today or past', tests.q(ann, a_e, format($q$public.pro_request_create(%L, null, current_date, null, null, null, 'Need a DJ', null)$q$, p_dj)), 'ERROR: Choose a date between tomorrow and two years from now.');
  perform tests.assert_eq('...a day too far', tests.q(ann, a_e, format($q$public.pro_request_create(%L, null, current_date + 731, null, null, null, 'Need a DJ', null)$q$, p_dj)), 'ERROR: Choose a date between tomorrow and two years from now.');
  perform tests.assert_eq('...a message that is too short', tests.q(ann, a_e, format($q$public.pro_request_create(%L, null, %L, null, null, null, 'Hi', null)$q$, p_dj, d1)), 'ERROR: Tell them about the job in 3 to 1000 characters.');
  perform tests.assert_eq('...a time note that is too long', tests.q(ann, a_e, format($q$public.pro_request_create(%L, null, %L, %L, null, null, 'Need a DJ', null)$q$, p_dj, d1, repeat('x', 61))), 'ERROR: Keep the time to 60 characters.');
  perform tests.assert_eq('...a place that is too long', tests.q(ann, a_e, format($q$public.pro_request_create(%L, null, %L, null, %L, null, 'Need a DJ', null)$q$, p_dj, d1, repeat('x', 161))), 'ERROR: Keep the place to 160 characters.');
  perform tests.assert_eq('...guests under one', tests.q(ann, a_e, format($q$public.pro_request_create(%L, null, %L, null, null, 0, 'Need a DJ', null)$q$, p_dj, d1)), 'ERROR: Choose a number of guests between 1 and 100,000.');
  perform tests.assert_eq('...a budget out of range', tests.q(ann, a_e, format($q$public.pro_request_create(%L, null, %L, null, null, 50, 'Need a DJ', -5)$q$, p_dj, d1)), 'ERROR: Choose a budget between 0 and 500,000.00.');
  perform tests.assert_eq('...banned words', tests.q(ann, a_e, format($q$public.pro_request_create(%L, null, %L, null, null, 50, 'Need a forbiddenword please', null)$q$, p_dj, d1)), 'ERROR: That wording is not allowed here.');
  perform tests.assert_eq('...a club is not a professional', tests.q(ann, a_e, format($q$public.pro_request_create(%L, null, %L, null, null, 50, 'Need a DJ', null)$q$, p_club, d1)), 'ERROR: This professional is not available.');
  perform tests.assert_eq('...nor is a person', tests.q(ann, a_e, format($q$public.pro_request_create(%L, null, %L, null, null, 50, 'Need a DJ', null)$q$, p_bob, d1)), 'ERROR: This professional is not available.');
  perform tests.assert_eq('...you cannot hire yourself', tests.q(dee, d_e, format($q$public.pro_request_create(%L, null, %L, null, null, 50, 'Need a DJ', null)$q$, p_dj, d1)), 'ERROR: You cannot hire yourself.');
  perform tests.assert_eq('...nor someone who blocked you or whom you blocked', tests.q(eve, e_e, format($q$public.pro_request_create(%L, null, %L, null, null, 50, 'Need a DJ', null)$q$, p_dj, d1)), 'ERROR: This professional is not available.');
  perform tests.assert_eq('...a service that is not theirs, or is switched off', tests.q(ann, a_e, format($q$public.pro_request_create(%L, %L, %L, null, null, 50, 'Need a DJ', null)$q$, p_dj, sv2, d1)), 'ERROR: That service is not available.');
  perform tests.assert_eq('...a day the professional has taken', tests.q(ann, a_e, format($q$public.pro_request_create(%L, null, %L, null, null, 50, 'Need a DJ', null)$q$, p_dj, d1 + 9)), 'ERROR: This professional is not free on that day.');
  perform tests.assert_eq('...the community rules are accepted first', tests.q(zed, z_e, format($q$public.pro_request_create(%L, null, %L, null, null, 50, 'Need a DJ', null)$q$, p_dj, d1)), 'ERROR: Read and accept the community rules first.');
  rq := (tests.f(ann, a_e, format($q$public.pro_request_create(%L, %L, %L, '9pm to 1am', 'Pro Club', 120, 'A birthday night for 120', 150000)$q$, p_dj, sv1, d1), '{id}'))::uuid;
  perform tests.assert_true('a request was made', rq is not null);
  perform tests.assert_eq('the same day twice is refused', tests.q(ann, a_e, format($q$public.pro_request_create(%L, null, %L, null, null, 50, 'Again', null)$q$, p_dj, d1)), 'ERROR: You already have a request open with this professional for that day.');
  perform tests.assert_eq('the customer sees the professional and the request is requested', tests.f(ann, a_e, format($q$public.pro_request_get(%L)$q$, rq), '{status}') || '/' || tests.f(ann, a_e, format($q$public.pro_request_get(%L)$q$, rq), '{provider,handle}'), 'requested/djdeepro');
  perform tests.assert_eq('...and never the customer''s own name echoed as a client', tests.f(ann, a_e, format($q$public.pro_request_get(%L)$q$, rq), '{client}'), '(null)');
  perform tests.assert_eq('the professional sees the customer''s name and handle', tests.f(dee, d_e, format($q$public.pro_request_get(%L)$q$, rq), '{client,name}') || '/' || tests.f(dee, d_e, format($q$public.pro_request_get(%L)$q$, rq), '{client,handle}'), 'Ann Lee/annpro');
  perform tests.assert_eq('a stranger sees nothing', tests.q(bob, b_e, format($q$public.pro_request_get(%L)$q$, rq)), 'ERROR: This request is not available.');
  perform tests.assert_eq('...the customer''s list', tests.q(ann, a_e, 'jsonb_array_length(public.pro_requests_mine())'), '1');
  perform tests.assert_eq('...someone else''s list is empty', tests.q(bob, b_e, 'public.pro_requests_mine()'), '[]');
  perform tests.assert_eq('...the professional''s list, only as a profile they run', tests.q(dee, d_e, format($q$jsonb_array_length(public.pro_requests_for(%L))$q$, p_dj)), '1');
  perform tests.assert_eq('...not by someone else', tests.q(ann, a_e, format($q$public.pro_requests_for(%L)$q$, p_dj)), 'ERROR: You cannot act as this profile.');
  perform tests.assert_eq('...and not for the professional''s other profile', tests.q(dee, d_e, format($q$public.pro_requests_for(%L)$q$, p_dj2)), '[]');

  ---------------------------------------------------------------- quotes
  perform tests.assert_eq('a quote is for a request of the professional''s own', tests.q(dee, d_e, format($q$public.pro_quote_send(%L, %L, 100000, 30000, %L, 'Four hours, lights and sound', 7)$q$, p_dj2, rq, d1 - 3)), 'ERROR: This request is not available.');
  perform tests.assert_eq('...a customer cannot quote', tests.q(ann, a_e, format($q$public.pro_quote_send(%L, %L, 100000, 30000, %L, 'Four hours, lights and sound', 7)$q$, p_dj, rq, d1 - 3)), 'ERROR: You cannot act as this profile.');
  perform tests.assert_eq('...a total under 10.00', tests.q(dee, d_e, format($q$public.pro_quote_send(%L, %L, 999, 500, %L, 'Four hours, lights and sound', 7)$q$, p_dj, rq, d1 - 3)), 'ERROR: Choose a total between 10.00 and 50,000.00.');
  perform tests.assert_eq('...a total over 50,000.00', tests.q(dee, d_e, format($q$public.pro_quote_send(%L, %L, 5000001, 500000, %L, 'Four hours, lights and sound', 7)$q$, p_dj, rq, d1 - 3)), 'ERROR: Choose a total between 10.00 and 50,000.00.');
  perform tests.assert_eq('...a deposit under a tenth', tests.q(dee, d_e, format($q$public.pro_quote_send(%L, %L, 100000, 9999, %L, 'Four hours, lights and sound', 7)$q$, p_dj, rq, d1 - 3)), 'ERROR: The deposit must be at least a tenth of the total, and no more than the total.');
  perform tests.assert_eq('...a deposit over the total', tests.q(dee, d_e, format($q$public.pro_quote_send(%L, %L, 100000, 100001, null, 'Four hours, lights and sound', 7)$q$, p_dj, rq)), 'ERROR: The deposit must be at least a tenth of the total, and no more than the total.');
  perform tests.assert_eq('...a balance with no date', tests.q(dee, d_e, format($q$public.pro_quote_send(%L, %L, 100000, 30000, null, 'Four hours, lights and sound', 7)$q$, p_dj, rq)), 'ERROR: The balance must be due before the date of the job.');
  perform tests.assert_eq('...a balance due on the day of the job', tests.q(dee, d_e, format($q$public.pro_quote_send(%L, %L, 100000, 30000, %L, 'Four hours, lights and sound', 7)$q$, p_dj, rq, d1)), 'ERROR: The balance must be due before the date of the job.');
  perform tests.assert_eq('...a balance due in the past', tests.q(dee, d_e, format($q$public.pro_quote_send(%L, %L, 100000, 30000, current_date - 1, 'Four hours, lights and sound', 7)$q$, p_dj, rq)), 'ERROR: The balance must be due before the date of the job.');
  perform tests.assert_eq('...a date for a balance when all of it is the deposit', tests.q(dee, d_e, format($q$public.pro_quote_send(%L, %L, 100000, 100000, %L, 'Four hours, lights and sound', 7)$q$, p_dj, rq, d1 - 3)), 'ERROR: There is no balance when the deposit is the whole amount.');
  perform tests.assert_eq('...a scope that says too little', tests.q(dee, d_e, format($q$public.pro_quote_send(%L, %L, 100000, 30000, %L, 'Short', 7)$q$, p_dj, rq, d1 - 3)), 'ERROR: Say what is included in 10 to 1500 characters.');
  perform tests.assert_eq('...banned words', tests.q(dee, d_e, format($q$public.pro_quote_send(%L, %L, 100000, 30000, %L, 'Four hours of forbiddenword music', 7)$q$, p_dj, rq, d1 - 3)), 'ERROR: That wording is not allowed here.');
  perform tests.assert_eq('...open for 0 days', tests.q(dee, d_e, format($q$public.pro_quote_send(%L, %L, 100000, 30000, %L, 'Four hours, lights and sound', 0)$q$, p_dj, rq, d1 - 3)), 'ERROR: A quote can stay open for 1 to 14 days.');
  perform tests.assert_eq('...open for 15 days', tests.q(dee, d_e, format($q$public.pro_quote_send(%L, %L, 100000, 30000, %L, 'Four hours, lights and sound', 15)$q$, p_dj, rq, d1 - 3)), 'ERROR: A quote can stay open for 1 to 14 days.');
  perform tests.assert_eq('the quote goes out', tests.f(dee, d_e, format($q$public.pro_quote_send(%L, %L, 100000, 30000, %L, 'Four hours, lights and sound', 7)$q$, p_dj, rq, d1 - 3), '{status}'), 'quoted');
  perform tests.assert_eq('the customer sees it, as sent', tests.f(ann, a_e, format($q$public.pro_request_get(%L)$q$, rq), '{quote,status}') || '/' || tests.f(ann, a_e, format($q$public.pro_request_get(%L)$q$, rq), '{quote,total_cents}'), 'sent/100000');
  q1 := (select id from public.site_pro_quotes where request = rq and status = 'sent');
  r := tests.f(dee, d_e, format($q$public.pro_quote_send(%L, %L, 110000, 30000, %L, 'Four hours, lights, sound and a smoke machine', 7)$q$, p_dj, rq, d1 - 3), '{quote,total_cents}');
  perform tests.assert_eq('a second quote withdraws the first: one live quote', r || '/' || (select string_agg(status, ',' order by status) from public.site_pro_quotes where request = rq), '110000/sent,withdrawn');
  perform tests.assert_eq('the professional can withdraw the quote', tests.f(dee, d_e, format($q$public.pro_quote_withdraw(%L, %L)$q$, p_dj, rq), '{status}'), 'requested');
  perform tests.assert_eq('...and there is nothing to withdraw twice', tests.q(dee, d_e, format($q$public.pro_quote_withdraw(%L, %L)$q$, p_dj, rq)), 'ERROR: There is no open quote to withdraw.');
  perform tests.assert_eq('a day that has been taken since stops a quote', tests.q(dee, d_e, format($q$public.pro_busy_set(%L, %L, true)$q$, p_dj, d1)), '');
  perform tests.assert_eq('...you are not free that day', tests.q(dee, d_e, format($q$public.pro_quote_send(%L, %L, 100000, 30000, %L, 'Four hours, lights and sound', 7)$q$, p_dj, rq, d1 - 3)), 'ERROR: You are not free on that day: change your days off first.');
  perform tests.q(dee, d_e, format($q$public.pro_busy_set(%L, %L, false)$q$, p_dj, d1));

  -- customer: nothing to accept, then a quote to turn down
  perform tests.assert_eq('nothing to accept before a quote', tests.q(ann, a_e, format($q$public.pro_quote_accept(%L)$q$, rq)), 'ERROR: There is no quote to accept.');
  perform tests.q(dee, d_e, format($q$public.pro_quote_send(%L, %L, 100000, 30000, %L, 'Four hours, lights and sound', 7)$q$, p_dj, rq, d1 - 3));
  perform tests.assert_eq('the customer turns it down: the request is open again', tests.f(ann, a_e, format($q$public.pro_quote_decline(%L)$q$, rq), '{status}'), 'requested');
  perform tests.assert_eq('...and there is nothing to turn down twice', tests.q(ann, a_e, format($q$public.pro_quote_decline(%L)$q$, rq)), 'ERROR: There is no open quote to turn down.');
  perform tests.assert_eq('only the customer', tests.q(bob, b_e, format($q$public.pro_quote_decline(%L)$q$, rq)), 'ERROR: This request is not available.');
  perform tests.q(dee, d_e, format($q$public.pro_quote_send(%L, %L, 100000, 30000, %L, 'Four hours, lights and sound', 7)$q$, p_dj, rq, d1 - 3));

  ---------------------------------------------------------------- accepting
  perform tests.assert_eq('a stranger cannot accept', tests.q(bob, b_e, format($q$public.pro_quote_accept(%L)$q$, rq)), 'ERROR: This request is not available.');
  perform tests.assert_eq('...nor the professional', tests.q(dee, d_e, format($q$public.pro_quote_accept(%L)$q$, rq)), 'ERROR: This request is not available.');
  update public.site_pro_quotes set valid_until = now() - interval '1 minute' where request = rq and status = 'sent';
  perform tests.assert_eq('an expired quote is read as expired', tests.f(ann, a_e, format($q$public.pro_request_get(%L)$q$, rq), '{quote,status}'), 'expired');
  perform tests.assert_eq('...and cannot be accepted', tests.q(ann, a_e, format($q$public.pro_quote_accept(%L)$q$, rq)), 'ERROR: This quote has expired. Ask for a new one.');
  perform tests.assert_eq('...nor turned down any more', tests.q(ann, a_e, format($q$public.pro_quote_decline(%L)$q$, rq)), 'ERROR: There is no open quote to turn down.');
  perform tests.q(dee, d_e, format($q$public.pro_quote_send(%L, %L, 100000, 30000, %L, 'Four hours, lights and sound', 7)$q$, p_dj, rq, d1 - 3));
  update public.site_pro_quotes set balance_due_by = current_date - 1 where request = rq and status = 'sent';
  perform tests.assert_eq('a balance date that has passed', tests.q(ann, a_e, format($q$public.pro_quote_accept(%L)$q$, rq)), 'ERROR: The balance date of this quote has passed. Ask for a new quote.');
  update public.site_pro_quotes set balance_due_by = d1 - 3 where request = rq and status = 'sent';
  insert into public.site_pro_busy (profile, day) values (p_dj, d1);
  perform tests.assert_eq('a day taken in the meantime', tests.q(ann, a_e, format($q$public.pro_quote_accept(%L)$q$, rq)), 'ERROR: This professional is no longer free on that day.');
  delete from public.site_pro_busy where profile = p_dj and day = d1;
  j := tests.q(ann, a_e, format($q$public.pro_quote_accept(%L)$q$, rq))::jsonb;
  bk := (j ->> 'id')::uuid;
  perform tests.assert_true('accepted: a booking', bk is not null);
  perform tests.assert_eq('...waiting for the deposit', j ->> 'state', 'awaiting_deposit');
  perform tests.assert_eq('...with the quote''s money exactly', (j ->> 'total_cents') || '/' || (j ->> 'deposit_cents') || '/' || (j ->> 'owed_cents') || '/' || (j ->> 'paid_cents'), '100000/30000/100000/0');
  perform tests.assert_eq('...the commission fixed at 5% and not shown to the customer', (select commission_bps from public.site_pro_bookings where id = bk)::text || '/' || coalesce(j ->> 'commission_bps', 'hidden'), '500/hidden');
  perform tests.assert_eq('...the provider sees the commission and what they will get', tests.f(dee, d_e, format($q$public.pro_booking_get(%L)$q$, bk), '{commission_bps}') || '/' || tests.f(dee, d_e, format($q$public.pro_booking_get(%L)$q$, bk), '{net_cents}'), '500/95000');
  perform tests.assert_eq('...the title is the service''s', j ->> 'title', 'Wedding DJ set (4h)');
  perform tests.assert_eq('...the request is accepted', (select status from public.site_pro_requests where id = rq), 'accepted');
  perform tests.assert_eq('...it cannot be accepted twice', tests.q(ann, a_e, format($q$public.pro_quote_accept(%L)$q$, rq)), 'ERROR: There is no quote to accept.');
  perform tests.assert_eq('...the day is held while it waits to be paid', tests.q(bob, b_e, format($q$public.pro_busy_days(%L, current_date, 120)$q$, p_dj)), format('["%s", "%s"]', d1, d1 + 9));
  perform tests.assert_eq('...so nobody else can ask for it', tests.q(bob, b_e, format($q$public.pro_request_create(%L, null, %L, null, null, 50, 'Need a DJ', null)$q$, p_dj, d1)), 'ERROR: This professional is not free on that day.');
  perform tests.assert_eq('a stranger cannot read the booking', tests.q(bob, b_e, format($q$public.pro_booking_get(%L)$q$, bk)), 'ERROR: This booking is not available.');
  perform tests.assert_eq('...the customer can', tests.f(ann, a_e, format($q$public.pro_booking_get(%L)$q$, bk), '{state}'), 'awaiting_deposit');

  ---------------------------------------------------------------- paying
  perform tests.assert_eq('a stranger cannot pay for it', tests.q(bob, b_e, format($q$public.pro_payment_begin(%L)$q$, bk)), 'ERROR: This booking is not available.');
  j := tests.q(ann, a_e, format($q$public.pro_payment_begin(%L)$q$, bk))::jsonb;
  pay1 := (j ->> 'payment_id')::uuid;
  perform tests.assert_eq('the deposit is what is asked first', (j ->> 'kind') || '/' || (j ->> 'amount_cents') || '/' || (j ->> 'provider'), 'deposit/30000/DJ Dee');
  perform tests.login(ann, a_e);
  perform tests.assert_raises('the website''s functions are not for a person', format($q$select public.pro_payment_attach(%L, 'cs_x', now())$q$, pay1), 'permission denied');
  perform tests.logout();
  perform tests.assert_eq('attach the payment page', tests.svc(format($q$public.pro_payment_attach(%L, 'cs_dep1', now() + interval '31 minutes')$q$, pay1)), '');
  r := tests.f(ann, a_e, format($q$public.pro_payment_begin(%L)$q$, bk), '{pending_session}');
  perform tests.assert_eq('asking again hands back the same page and makes no second payment', r || '/' || (select count(*) from public.site_pro_payments where booking = bk), 'cs_dep1/1');
  perform tests.assert_eq('a session nobody knows', tests.svcf($q$public.pro_payment_paid('cs_none', 'pi_n', 30000)$q$, '{result}'), 'unknown');
  r := tests.svc($q$public.pro_payment_paid('cs_dep1', 'pi_dep1', 30000)$q$);
  perform tests.assert_eq('the deposit is taken: counted, nothing to pay back', (r::jsonb ->> 'result') || '/' || (r::jsonb ->> 'applied_cents') || '/' || (r::jsonb ->> 'refund_cents'), 'applied/30000/0');
  perform tests.assert_eq('...the booking is confirmed with 700.00 to pay', tests.f(ann, a_e, format($q$public.pro_booking_get(%L)$q$, bk), '{state}') || '/' || tests.f(ann, a_e, format($q$public.pro_booking_get(%L)$q$, bk), '{owed_cents}'), 'confirmed/70000');
  r := tests.svcf($q$public.pro_payment_paid('cs_dep1', 'pi_dep1', 30000)$q$, '{result}');
  perform tests.assert_eq('...said twice, nothing changes', r || '/' || (select paid_cents from public.site_pro_bookings where id = bk), 'already/30000');
  j := tests.q(ann, a_e, format($q$public.pro_payment_begin(%L)$q$, bk))::jsonb;
  pay2 := (j ->> 'payment_id')::uuid;
  perform tests.assert_eq('then the balance', (j ->> 'kind') || '/' || (j ->> 'amount_cents'), 'balance/70000');
  perform tests.svc(format($q$public.pro_payment_attach(%L, 'cs_bal1', now() + interval '31 minutes')$q$, pay2));
  r := tests.svc($q$public.pro_payment_paid('cs_bal1', 'pi_bal1', 70000)$q$);
  perform tests.assert_eq('the balance is taken', (r::jsonb ->> 'result') || '/' || (select paid_cents from public.site_pro_bookings where id = bk), 'applied/100000');
  perform tests.assert_eq('...paid in full', tests.f(ann, a_e, format($q$public.pro_booking_get(%L)$q$, bk), '{state}'), 'paid');
  perform tests.assert_eq('...nothing more to pay', tests.q(ann, a_e, format($q$public.pro_payment_begin(%L)$q$, bk)), 'ERROR: You have paid everything for this booking.');

  ---------------------------------------------------------------- the day and after
  perform tests.assert_eq('the professional cannot mark it done before the day', tests.q(dee, d_e, format($q$public.pro_booking_done(%L, %L)$q$, p_dj, bk)), 'ERROR: You can mark it done on the day of the job or after.');
  perform tests.assert_eq('the customer cannot confirm before it is done', tests.q(ann, a_e, format($q$public.pro_booking_confirm(%L)$q$, bk)), 'ERROR: This booking is not waiting for your confirmation.');
  perform tests.assert_eq('...nor dispute before the day', tests.q(ann, a_e, format($q$public.pro_dispute_open(%L, 'The DJ did not turn up at all')$q$, bk)), 'ERROR: You can open a dispute on the day of the job or after.');
  update public.site_pro_bookings set event_date = current_date where id = bk;
  perform tests.assert_eq('a customer cannot mark it done', tests.q(ann, a_e, format($q$public.pro_booking_done(%L, %L)$q$, p_dj, bk)), 'ERROR: You cannot act as this profile.');
  perform tests.assert_eq('the other profile of the professional cannot either', tests.q(dee, d_e, format($q$public.pro_booking_done(%L, %L)$q$, p_dj2, bk)), 'ERROR: This booking is not available.');
  perform tests.assert_eq('on the day the professional marks it done', tests.f(dee, d_e, format($q$public.pro_booking_done(%L, %L)$q$, p_dj, bk), '{state}'), 'done');
  perform tests.assert_eq('...once only', tests.q(dee, d_e, format($q$public.pro_booking_done(%L, %L)$q$, p_dj, bk)), 'ERROR: You already marked this done.');
  perform tests.assert_eq('a cancel on the day is a dispute', tests.q(ann, a_e, format($q$public.pro_booking_cancel(%L, 'changed my mind')$q$, bk)), 'ERROR: The date has come: if something went wrong, open a dispute instead.');
  perform tests.assert_eq('the customer confirms: completed', tests.f(ann, a_e, format($q$public.pro_booking_confirm(%L)$q$, bk), '{state}'), 'completed');
  perform tests.assert_eq('...the payout is releasable: 1000.00, 50.00 commission, 950.00 net', (select gross_cents || '/' || commission_cents || '/' || net_cents || '/' || status from public.site_pro_payouts where booking = bk), '100000/5000/95000/releasable');
  perform tests.assert_eq('...nothing is due back', (select count(*) from public.site_pro_payments where refund_due_cents > 0)::int, 0);
  perform tests.assert_eq('...confirming twice', tests.q(ann, a_e, format($q$public.pro_booking_confirm(%L)$q$, bk)), 'ERROR: This booking is not waiting for your confirmation.');
  perform tests.assert_eq('...a completed booking cannot be cancelled or disputed', tests.q(ann, a_e, format($q$public.pro_booking_cancel(%L, 'x')$q$, bk)), 'ERROR: This booking is already closed.');

  ---------------------------------------------------------------- BottlesUp pays the professional
  perform tests.login(dee, d_e);
  perform tests.assert_raises('the professional cannot read the ledger', $q$select public.cms_pro_payouts('all')$q$, 'Only a BottlesUp admin');
  perform tests.logout();
  perform tests.assert_eq('the admin''s list', tests.f(admin_u, adm, $q$public.cms_pro_payouts('releasable') -> 0$q$, '{net_cents}') || '/' || tests.f(admin_u, adm, $q$public.cms_pro_payouts('releasable') -> 0$q$, '{provider}'), '95000/DJ Dee');
  po := (select id from public.site_pro_payouts where booking = bk);
  perform tests.assert_eq('a transfer reference is required', tests.q(admin_u, adm, format($q$public.cms_pro_payout_paid(%L, '  ')$q$, po)), 'ERROR: Write the transfer reference (up to 120 characters).');
  perform tests.assert_eq('...not by anyone else', tests.q(dee, d_e, format($q$public.cms_pro_payout_paid(%L, 'ref-1')$q$, po)), 'ERROR: Only a BottlesUp admin can do this.');
  perform tests.assert_eq('marked paid', tests.f(admin_u, adm, format($q$public.cms_pro_payout_paid(%L, 'etransfer 7788')$q$, po), '{status}'), 'paid');
  perform tests.assert_eq('...once', tests.q(admin_u, adm, format($q$public.cms_pro_payout_paid(%L, 'again')$q$, po)), 'ERROR: This payout is not waiting to be paid.');
  perform tests.assert_eq('...and it is in the audit log', (select count(*) from public.audit_log where action = 'service.payout_paid' and entity_id = po::text)::int, 1);

  -- settings
  perform tests.assert_eq('the settings start at 5%, a week and three days', tests.f(admin_u, adm, 'public.cms_pro_settings()', '{commission_bps}') || '/' || tests.f(admin_u, adm, 'public.cms_pro_settings()', '{free_cancel_days}') || '/' || tests.f(admin_u, adm, 'public.cms_pro_settings()', '{confirm_days}'), '500/7/3');
  perform tests.assert_eq('...only for an admin', tests.q(dee, d_e, 'public.cms_pro_settings()'), 'ERROR: Only a BottlesUp admin can see this.');
  perform tests.assert_eq('...a commission over 50 percent', tests.q(admin_u, adm, 'public.cms_pro_settings_set(5001, 7, 3)'), 'ERROR: The commission must be between 0 and 50 percent.');
  perform tests.assert_eq('...free cancellation over 60 days', tests.q(admin_u, adm, 'public.cms_pro_settings_set(500, 61, 3)'), 'ERROR: Free cancellation must be between 0 and 60 days before the job.');
  perform tests.assert_eq('...confirmation under a day', tests.q(admin_u, adm, 'public.cms_pro_settings_set(500, 7, 0)'), 'ERROR: Automatic confirmation must be 1 to 30 days after the job is marked done.');
  perform tests.assert_eq('...only for an admin', tests.q(dee, d_e, 'public.cms_pro_settings_set(100, 7, 3)'), 'ERROR: Only a BottlesUp admin can change this.');
  perform tests.assert_eq('a new commission applies to quotes accepted from now on', tests.f(admin_u, adm, 'public.cms_pro_settings_set(800, 5, 2)', '{commission_bps}'), '800');
  perform tests.assert_eq('...the change is in the audit log', (select count(*) from public.audit_log where action = 'marketplace.settings')::int, 1);

  ---------------------------------------------------------------- a second job: the customer cancels early or late
  rq2 := (tests.f(bob, b_e, format($q$public.pro_request_create(%L, null, %L, null, null, 80, 'A corporate evening', null)$q$, p_dj, current_date + 60), '{id}'))::uuid;
  perform tests.q(dee, d_e, format($q$public.pro_quote_send(%L, %L, 200000, 60000, %L, 'Five hours of music and the sound system', 5)$q$, p_dj, rq2, current_date + 50));
  bk2 := (tests.f(bob, b_e, format($q$public.pro_quote_accept(%L)$q$, rq2), '{id}'))::uuid;
  perform tests.assert_eq('the commission of the day is kept on the booking', (select commission_bps || '/' || free_cancel_days from public.site_pro_bookings where id = bk2), '800/5');
  perform tests.assert_eq('the first job''s commission stays what it was', (select commission_bps from public.site_pro_bookings where id = bk), 500);
  perform tests.q(admin_u, adm, 'public.cms_pro_settings_set(500, 7, 3)');
  pay1 := (tests.f(bob, b_e, format($q$public.pro_payment_begin(%L)$q$, bk2), '{payment_id}'))::uuid;
  perform tests.svc(format($q$public.pro_payment_attach(%L, 'cs_dep2', now() + interval '31 minutes')$q$, pay1));
  perform tests.svc($q$public.pro_payment_paid('cs_dep2', 'pi_dep2', 60000)$q$);
  r := tests.f(bob, b_e, format($q$public.pro_booking_cancel(%L, 'plans changed')$q$, bk2), '{state}');
  perform tests.assert_eq('a customer cancels weeks ahead: everything paid is paid back, nothing is kept', r || '/' || (select refund_due_cents from public.site_pro_payments where id = pay1) || '/' || (select count(*) from public.site_pro_payouts where booking = bk2), 'cancelled/60000/0');
  perform tests.assert_eq('...the day is free again', tests.q(ann, a_e, format($q$public.pro_busy_days(%L, current_date + 55, 20)$q$, p_dj)), '[]');
  perform tests.assert_eq('...it cannot be cancelled twice', tests.q(bob, b_e, format($q$public.pro_booking_cancel(%L, 'x')$q$, bk2)), 'ERROR: This booking is already closed.');
  perform tests.assert_eq('...and the refund list shows it, to the website only', tests.svc($q$(select string_agg(r.cents::text || '@' || r.stripe_payment_intent_id, ',') from public.pro_refunds_due() r)$q$), '60000@pi_dep2');
  perform tests.assert_eq('a refund is recorded once per Stripe refund', tests.svcf(format($q$public.pro_payment_refunded(%L, 're_1', 60000)$q$, pay1), '{result}') || '/' || tests.svcf(format($q$public.pro_payment_refunded(%L, 're_1', 60000)$q$, pay1), '{result}'), 'refunded/already');
  perform tests.assert_eq('...and nothing more is due', tests.svcf(format($q$public.pro_payment_refunded(%L, 're_2', 100)$q$, pay1), '{result}'), 'nothing_due');
  perform tests.assert_eq('...a refund id and an amount are needed', tests.svc(format($q$public.pro_payment_refunded(%L, '', 100)$q$, pay1)), 'ERROR: a refund id and an amount are needed');

  rq3 := (tests.f(bob, b_e, format($q$public.pro_request_create(%L, null, current_date + 4, null, null, 80, 'A late booking', null)$q$, p_dj), '{id}'))::uuid;
  perform tests.q(dee, d_e, format($q$public.pro_quote_send(%L, %L, 100000, 20000, %L, 'Four hours of music and the sound system', 3)$q$, p_dj, rq3, current_date + 2));
  bk3 := (tests.f(bob, b_e, format($q$public.pro_quote_accept(%L)$q$, rq3), '{id}'))::uuid;
  pay1 := (tests.f(bob, b_e, format($q$public.pro_payment_begin(%L)$q$, bk3), '{payment_id}'))::uuid;
  perform tests.svc(format($q$public.pro_payment_attach(%L, 'cs_dep3', now() + interval '31 minutes')$q$, pay1));
  perform tests.svc($q$public.pro_payment_paid('cs_dep3', 'pi_dep3', 20000)$q$);
  pay2 := (tests.f(bob, b_e, format($q$public.pro_payment_begin(%L)$q$, bk3), '{payment_id}'))::uuid;
  perform tests.svc(format($q$public.pro_payment_attach(%L, 'cs_bal3', now() + interval '31 minutes')$q$, pay2));
  perform tests.svc($q$public.pro_payment_paid('cs_bal3', 'pi_bal3', 80000)$q$);
  perform tests.assert_eq('a customer cancels 4 days ahead (inside the week): the 30% minimum is kept for the professional, the rest is paid back', tests.f(bob, b_e, format($q$public.pro_booking_cancel(%L, 'too late')$q$, bk3), '{state}'), 'cancelled');
  perform tests.assert_eq('...70.00 of every 100.00 comes back, newest payment first', (select refund_due_cents from public.site_pro_payments where id = pay2) || '/' || (select refund_due_cents from public.site_pro_payments where id = pay1), '70000/0');
  perform tests.assert_eq('...and the 300.00 kept becomes a payout less the commission', (select gross_cents || '/' || commission_cents || '/' || net_cents from public.site_pro_payouts where booking = bk3), '30000/1500/28500');

  -- the professional cancels: everything is paid back whatever the date
  rq3 := (tests.f(ann, a_e, format($q$public.pro_request_create(%L, null, current_date + 3, null, null, 80, 'A very late booking', null)$q$, p_dj), '{id}'))::uuid;
  perform tests.q(dee, d_e, format($q$public.pro_quote_send(%L, %L, 50000, 50000, null, 'Two hours of music, paid in full', 3)$q$, p_dj, rq3));
  bk4 := (tests.f(ann, a_e, format($q$public.pro_quote_accept(%L)$q$, rq3), '{id}'))::uuid;
  perform tests.assert_eq('a quote whose deposit is everything is paid at once, all of it', tests.f(ann, a_e, format($q$public.pro_payment_begin(%L)$q$, bk4), '{kind}') || '/' || tests.f(ann, a_e, format($q$public.pro_payment_begin(%L)$q$, bk4), '{amount_cents}'), 'full/50000');
  pay1 := (tests.f(ann, a_e, format($q$public.pro_payment_begin(%L)$q$, bk4), '{payment_id}'))::uuid;
  perform tests.svc(format($q$public.pro_payment_attach(%L, 'cs_full4', now() + interval '31 minutes')$q$, pay1));
  perform tests.svc($q$public.pro_payment_paid('cs_full4', 'pi_full4', 50000)$q$);
  perform tests.assert_eq('the professional cancels three days ahead', tests.f(dee, d_e, format($q$public.pro_booking_cancel(%L, 'ill')$q$, bk4), '{state}'), 'cancelled');
  perform tests.assert_eq('...all of it is paid back and nothing is kept', (select refund_due_cents from public.site_pro_payments where id = pay1) || '/' || (select count(*) from public.site_pro_payouts where booking = bk4), '50000/0');
  perform tests.assert_eq('...who cancelled is on the booking', (select cancelled_by from public.site_pro_bookings where id = bk4), 'provider');

  ---------------------------------------------------------------- payments that cannot be used
  rq3 := (tests.f(ann, a_e, format($q$public.pro_request_create(%L, null, current_date + 90, null, null, 80, 'Another evening', null)$q$, p_dj), '{id}'))::uuid;
  perform tests.q(dee, d_e, format($q$public.pro_quote_send(%L, %L, 100000, 30000, %L, 'Four hours of music and the sound system', 3)$q$, p_dj, rq3, current_date + 80));
  bk5 := (tests.f(ann, a_e, format($q$public.pro_quote_accept(%L)$q$, rq3), '{id}'))::uuid;
  pay1 := (tests.f(ann, a_e, format($q$public.pro_payment_begin(%L)$q$, bk5), '{payment_id}'))::uuid;
  perform tests.svc(format($q$public.pro_payment_attach(%L, 'cs_odd5', now() + interval '31 minutes')$q$, pay1));
  r := tests.svc($q$public.pro_payment_paid('cs_odd5', 'pi_odd5', 25000)$q$);
  perform tests.assert_eq('an amount that is not the payment''s is paid back in full, none counted', (r::jsonb ->> 'result') || '/' || (r::jsonb ->> 'refund_cents') || '/' || (select paid_cents from public.site_pro_bookings where id = bk5) || '/' || (select status from public.site_pro_bookings where id = bk5), 'refund/25000/0/awaiting_deposit');
  update public.site_pro_bookings set pay_by = now() - interval '2 hours' where id = bk5;
  perform tests.assert_eq('after the 24 hours the deposit can no longer be paid', tests.q(ann, a_e, format($q$public.pro_payment_begin(%L)$q$, bk5)), 'ERROR: The time to pay for this booking has passed. Ask for a new quote.');
  perform tests.assert_eq('...and it reads as expired', tests.f(ann, a_e, format($q$public.pro_booking_get(%L)$q$, bk5), '{state}'), 'expired');
  perform tests.assert_eq('...the day is free again for others', tests.q(bob, b_e, format($q$public.pro_busy_days(%L, current_date + 85, 20)$q$, p_dj)), '[]');

  ---------------------------------------------------------------- housekeeping
  j := tests.svc('public.market_housekeeping()')::jsonb;
  perform tests.assert_eq('the unpaid acceptance is cancelled with nothing to pay back', (j ->> 'lapsed') || '/' || (select status from public.site_pro_bookings where id = bk5) || '/' || (select cancelled_by from public.site_pro_bookings where id = bk5), '1/cancelled/system');
  perform tests.assert_eq('running it again does nothing more', tests.svc('public.market_housekeeping()'), '{"lapsed": 0, "completed": 0, "accounts_gone": 0, "balance_unpaid": 0}');
  perform tests.login(ann, a_e);
  perform tests.assert_raises('it is not for people', $q$select public.market_housekeeping()$q$, 'permission denied');
  perform tests.logout();

  rq3 := (tests.f(ann, a_e, format($q$public.pro_request_create(%L, null, current_date + 40, null, null, 80, 'Balance never paid', null)$q$, p_dj), '{id}'))::uuid;
  perform tests.q(dee, d_e, format($q$public.pro_quote_send(%L, %L, 100000, 30000, %L, 'Four hours of music and the sound system', 3)$q$, p_dj, rq3, current_date + 30));
  bk5 := (tests.f(ann, a_e, format($q$public.pro_quote_accept(%L)$q$, rq3), '{id}'))::uuid;
  pay1 := (tests.f(ann, a_e, format($q$public.pro_payment_begin(%L)$q$, bk5), '{payment_id}'))::uuid;
  perform tests.svc(format($q$public.pro_payment_attach(%L, 'cs_dep6', now() + interval '31 minutes')$q$, pay1));
  perform tests.svc($q$public.pro_payment_paid('cs_dep6', 'pi_dep6', 30000)$q$);
  update public.site_pro_bookings set balance_due_by = current_date - 1 where id = bk5;
  j := tests.svc('public.market_housekeeping()')::jsonb;
  perform tests.assert_eq('a balance not paid in time cancels the booking and keeps the deposit, even weeks before the date', (j ->> 'balance_unpaid') || '/' || (select status from public.site_pro_bookings where id = bk5) || '/' || (select refund_due_cents from public.site_pro_payments where id = pay1), '1/cancelled/0');
  perform tests.assert_eq('...the deposit is a payout: 300.00 less 15.00', (select gross_cents || '/' || net_cents from public.site_pro_payouts where booking = bk5), '30000/28500');

  ---------------------------------------------------------------- a dispute
  rq3 := (tests.f(bob, b_e, format($q$public.pro_request_create(%L, null, current_date + 20, null, null, 80, 'A dispute to come', null)$q$, p_dj), '{id}'))::uuid;
  perform tests.q(dee, d_e, format($q$public.pro_quote_send(%L, %L, 100000, 100000, null, 'Four hours of music and the sound system', 3)$q$, p_dj, rq3));
  bk5 := (tests.f(bob, b_e, format($q$public.pro_quote_accept(%L)$q$, rq3), '{id}'))::uuid;
  pay1 := (tests.f(bob, b_e, format($q$public.pro_payment_begin(%L)$q$, bk5), '{payment_id}'))::uuid;
  perform tests.svc(format($q$public.pro_payment_attach(%L, 'cs_full7', now() + interval '31 minutes')$q$, pay1));
  perform tests.svc($q$public.pro_payment_paid('cs_full7', 'pi_full7', 100000)$q$);
  update public.site_pro_bookings set event_date = current_date - 2 where id = bk5;
  perform tests.assert_eq('a stranger cannot dispute', tests.q(ann, a_e, format($q$public.pro_dispute_open(%L, 'The DJ did not turn up at all')$q$, bk5)), 'ERROR: This booking is not available.');
  perform tests.assert_eq('...a reason of at least ten characters', tests.q(bob, b_e, format($q$public.pro_dispute_open(%L, 'bad')$q$, bk5)), 'ERROR: Say what went wrong in 10 to 1000 characters.');
  perform tests.assert_eq('...banned words', tests.q(bob, b_e, format($q$public.pro_dispute_open(%L, 'The DJ played forbiddenword music')$q$, bk5)), 'ERROR: That wording is not allowed here.');
  update public.site_pro_bookings set event_date = current_date - 8 where id = bk5;
  perform tests.assert_eq('after a week it is too late', tests.q(bob, b_e, format($q$public.pro_dispute_open(%L, 'The DJ did not turn up at all')$q$, bk5)), 'ERROR: The time to open a dispute has passed.');
  update public.site_pro_bookings set event_date = current_date - 2 where id = bk5;
  perform tests.assert_eq('the customer opens one', tests.f(bob, b_e, format($q$public.pro_dispute_open(%L, 'The DJ did not turn up at all')$q$, bk5), '{state}'), 'disputed');
  perform tests.assert_eq('...the payout is held: none exists, and the professional cannot mark it done or cancel', (select count(*) from public.site_pro_payouts where booking = bk5)::int || '/' || tests.q(dee, d_e, format($q$public.pro_booking_done(%L, %L)$q$, p_dj, bk5)) || '/' || tests.q(dee, d_e, format($q$public.pro_booking_cancel(%L, 'x')$q$, bk5)), '0/ERROR: This booking cannot be marked done now./ERROR: This booking is in dispute: BottlesUp will decide it.');
  perform tests.assert_eq('...only one dispute per booking', (select count(*) from public.site_pro_disputes where booking = bk5)::int, 1);
  dsp := (select id from public.site_pro_disputes where booking = bk5);
  perform tests.assert_eq('the admin sees it, with who and how much', tests.f(admin_u, adm, $q$public.cms_pro_disputes('open') -> 0$q$, '{booking,provider}') || '/' || tests.f(admin_u, adm, $q$public.cms_pro_disputes('open') -> 0$q$, '{booking,client,name}'), 'DJ Dee/Bob Ray');
  perform tests.assert_eq('...a customer cannot', tests.q(bob, b_e, $q$public.cms_pro_disputes('open')$q$), 'ERROR: Only a BottlesUp admin can see this.');
  perform tests.assert_eq('...a wrong status', tests.q(admin_u, adm, $q$public.cms_pro_disputes('x')$q$), 'ERROR: Choose open, resolved or all.');
  perform tests.assert_eq('a decision needs an outcome and a note', tests.q(admin_u, adm, format($q$public.cms_pro_dispute_resolve(%L, 'x', null, 'note')$q$, dsp)), 'ERROR: Choose release, refund in part or refund in full.');
  perform tests.assert_eq('...a note', tests.q(admin_u, adm, format($q$public.cms_pro_dispute_resolve(%L, 'release', null, '  ')$q$, dsp)), 'ERROR: Write a note: the customer and the professional can be shown it.');
  perform tests.assert_eq('...a part refund of more than nothing and less than everything', tests.q(admin_u, adm, format($q$public.cms_pro_dispute_resolve(%L, 'refund_part', 100000, 'half')$q$, dsp)), 'ERROR: A part refund must be more than nothing and less than everything paid (1,000.00).');
  perform tests.assert_eq('...and not for a customer', tests.q(bob, b_e, format($q$public.cms_pro_dispute_resolve(%L, 'release', null, 'ok')$q$, dsp)), 'ERROR: Only a BottlesUp admin can decide this.');
  perform tests.assert_eq('a part refund: 400.00 goes back, the rest is the professional''s', tests.f(admin_u, adm, format($q$public.cms_pro_dispute_resolve(%L, 'refund_part', 40000, 'He arrived two hours late')$q$, dsp), '{refund_cents}'), '40000');
  perform tests.assert_eq('...it is completed with a payout of 600.00 less 30.00', (select status from public.site_pro_bookings where id = bk5) || '/' || (select gross_cents || '/' || net_cents from public.site_pro_payouts where booking = bk5), 'completed/60000/57000');
  perform tests.assert_eq('...the customer is owed 400.00 back', (select refund_due_cents from public.site_pro_payments where id = pay1), 40000);
  perform tests.assert_eq('...decided once', tests.q(admin_u, adm, format($q$public.cms_pro_dispute_resolve(%L, 'release', null, 'again')$q$, dsp)), 'ERROR: This dispute is already decided.');
  perform tests.assert_eq('...and it moves to the decided list', tests.f(admin_u, adm, $q$public.cms_pro_disputes('resolved') -> 0$q$, '{outcome}'), 'refund_part');

  -- a dispute decided for the customer, and one decided for the professional
  rq3 := (tests.f(ann, a_e, format($q$public.pro_request_create(%L, null, current_date + 22, null, null, 80, 'Another dispute to come', null)$q$, p_dj), '{id}'))::uuid;
  perform tests.q(dee, d_e, format($q$public.pro_quote_send(%L, %L, 100000, 100000, null, 'Four hours of music and the sound system', 3)$q$, p_dj, rq3));
  bk5 := (tests.f(ann, a_e, format($q$public.pro_quote_accept(%L)$q$, rq3), '{id}'))::uuid;
  pay1 := (tests.f(ann, a_e, format($q$public.pro_payment_begin(%L)$q$, bk5), '{payment_id}'))::uuid;
  perform tests.svc(format($q$public.pro_payment_attach(%L, 'cs_full8', now() + interval '31 minutes')$q$, pay1));
  perform tests.svc($q$public.pro_payment_paid('cs_full8', 'pi_full8', 100000)$q$);
  update public.site_pro_bookings set event_date = current_date - 1 where id = bk5;
  perform tests.q(ann, a_e, format($q$public.pro_dispute_open(%L, 'Nobody came to the party at all')$q$, bk5));
  dsp := (select id from public.site_pro_disputes where booking = bk5);
  r := tests.f(admin_u, adm, format($q$public.cms_pro_dispute_resolve(%L, 'refund_full', null, 'No one came')$q$, dsp), '{refund_cents}');
  perform tests.assert_eq('decided for the customer: everything is paid back, the booking is cancelled, no payout', r || '/' || (select status from public.site_pro_bookings where id = bk5) || '/' || (select refund_due_cents from public.site_pro_payments where id = pay1) || '/' || (select count(*) from public.site_pro_payouts where booking = bk5), '100000/cancelled/100000/0');

  ---------------------------------------------------------------- the website pays customers back
  perform tests.assert_eq('everything due is listed for the website, and what has been paid back is not', tests.svc($q$(select string_agg(r.cents::text, ',' order by r.cents) from public.pro_refunds_due() r)$q$), '25000,40000,50000,70000,100000');

  ---------------------------------------------------------------- how many requests a day
  update public.site_pro_requests set created_at = created_at - interval '2 days' where client in (ann, bob);
  for n in 1..5 loop
    perform tests.q(bob, b_e, format($q$public.pro_request_create(%L, null, current_date + 200 + %s, null, null, 50, 'Request number %s', null)$q$, p_dj, n, n));
  end loop;
  perform tests.assert_eq('five requests in a day is the limit', tests.q(bob, b_e, format($q$public.pro_request_create(%L, null, current_date + 210, null, null, 50, 'One too many', null)$q$, p_dj)), 'ERROR: You have sent a lot of requests today. Try again tomorrow.');
  perform tests.assert_eq('...an older request does not count against today', (select count(*) from public.site_pro_requests where client = bob and created_at > now() - interval '1 day')::int, 5);

  ---------------------------------------------------------------- accounts that go
  rq3 := (tests.f(ann, a_e, format($q$public.pro_request_create(%L, null, current_date + 120, null, null, 80, 'Before an account closes', null)$q$, p_dj), '{id}'))::uuid;
  perform tests.q(dee, d_e, format($q$public.pro_quote_send(%L, %L, 100000, 30000, %L, 'Four hours of music and the sound system', 3)$q$, p_dj, rq3, current_date + 100));
  bk5 := (tests.f(ann, a_e, format($q$public.pro_quote_accept(%L)$q$, rq3), '{id}'))::uuid;
  pay1 := (tests.f(ann, a_e, format($q$public.pro_payment_begin(%L)$q$, bk5), '{payment_id}'))::uuid;
  perform tests.svc(format($q$public.pro_payment_attach(%L, 'cs_gone9', now() + interval '31 minutes')$q$, pay1));
  perform tests.svc($q$public.pro_payment_paid('cs_gone9', 'pi_gone9', 30000)$q$);
  delete from auth.users where id = dee;
  perform tests.assert_eq('the professional''s account closes: the booking stays, with nobody on it', (select provider is null from public.site_pro_bookings where id = bk5), true);
  j := tests.svc('public.market_housekeeping()')::jsonb;
  perform tests.assert_eq('...and is cancelled with everything paid back', (j ->> 'accounts_gone') || '/' || (select status || '/' || cancelled_by from public.site_pro_bookings where id = bk5) || '/' || (select refund_due_cents from public.site_pro_payments where id = pay1), '1/cancelled/provider/30000');
  perform tests.assert_eq('the requests and the quotes of a closed professional stay as a record, without them', (select count(*) from public.site_pro_requests where provider is null)::int > 0, true);
  delete from auth.users where id = ann;
  perform tests.assert_eq('a customer''s account closes: what they asked stays without their name', (select count(*) from public.site_pro_requests where client is null)::int > 0, true);

  ---------------------------------------------------------------- the tables are closed
  perform tests.login(bob, b_e);
  perform tests.assert_raises('a person cannot read the bookings', $q$select * from public.site_pro_bookings$q$, 'permission denied');
  perform tests.assert_raises('...or the payments', $q$select * from public.site_pro_payments$q$, 'permission denied');
  perform tests.assert_raises('...or the payouts', $q$select * from public.site_pro_payouts$q$, 'permission denied');
  perform tests.assert_raises('...or write to the settings', $q$update public.site_pro_settings set commission_bps = 0$q$, 'permission denied');
  perform tests.logout();
  perform tests.login_anon();
  perform tests.assert_raises('a visitor cannot read the requests', $q$select * from public.site_pro_requests$q$, 'permission denied');
  perform tests.logout();
end $$;

rollback;
