-- Subscriptions, referrals, tips and the earnings overview. What matters most: only the owner of a professional's own profile subscribes it; what Stripe says is written as it is (hearing it
-- twice changes nothing, an old message does not undo a new one) and gives the subscribed commission only while it is paid for; a referral is claimed once, never for your own code, and
-- credits the referrer once for the referred person's first paid purchase inside the window, without ever being able to stop that purchase; a tip is applied once and its net is what the
-- creator can be paid; the overview keeps collected, held, earned, withdrawable and paid apart; every table is closed.
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
-- Runs an internal helper as a person (the claims only, no role change).
create function tests.i(p_user uuid, p_email text, p_expr text) returns text language plpgsql as $$
declare r text;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated', 'email', p_email)::text, true);
  execute 'select (' || p_expr || ')::text' into r;
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
  dee constant uuid := '00000000-0000-0000-0000-0000000007b1';    -- the DJ, owner of a professional profile
  ann constant uuid := '00000000-0000-0000-0000-0000000007b2';    -- refers people, and is a finance assistant
  bob constant uuid := '00000000-0000-0000-0000-0000000007b3';    -- referred by ann
  cy constant uuid := '00000000-0000-0000-0000-0000000007b4';     -- referred by ann, later; tips
  zed constant uuid := '00000000-0000-0000-0000-0000000007b5';    -- a stranger
  eve constant uuid := '00000000-0000-0000-0000-0000000007b6';    -- blocked the DJ
  olly constant uuid := '00000000-0000-0000-0000-0000000007b7';   -- runs a club
  fay constant uuid := '00000000-0000-0000-0000-0000000007b8';    -- referred, while credits are worth nothing
  hal constant uuid := '00000000-0000-0000-0000-0000000007b9';    -- referred, books a table
  gus constant uuid := '00000000-0000-0000-0000-0000000007ba';    -- referred, when the credit table is away
  d_e constant text := 'dee@bill.example'; a_e constant text := 'ann@bill.example'; b_e constant text := 'bob@bill.example'; c_e constant text := 'cy@bill.example';
  z_e constant text := 'zed@bill.example'; e_e constant text := 'eve@bill.example'; o_e constant text := 'olly@bill.example'; f_e constant text := 'fay@bill.example'; h_e constant text := 'hal@bill.example'; g_e constant text := 'gus@bill.example';
  p_dee uuid; p_ann uuid; p_bob uuid; p_cy uuid; p_zed uuid; p_eve uuid; p_dj uuid; p_dj2 uuid; p_ann_biz uuid; p_club uuid;
  org uuid; va uuid;
  sub1 uuid; sub2 uuid; sub3 uuid; t_fin uuid;
  ev uuid; tier uuid; od1 uuid; od2 uuid; od3 uuid; tb uuid; tt uuid; ts uuid; tip1 uuid; tip2 uuid; tip3 uuid; cr1 uuid;
  bk1 uuid; bk2 uuid; bk3 uuid; bk4 uuid; rq uuid; q1 uuid; code_ann text; code_dee text; code_biz text; sub4 uuid; sub5 uuid; sub6 uuid; od4 uuid;
  r text; n int; j jsonb;
begin
  insert into auth.users (id, email) values (dee, d_e), (ann, a_e), (bob, b_e), (cy, c_e), (zed, z_e), (eve, e_e), (olly, o_e), (fay, f_e), (hal, h_e), (gus, g_e);
  insert into public.profiles (id, name, email) values (dee, 'Dee Dee', d_e), (ann, 'Ann Lee', a_e), (bob, 'Bob Ray', b_e), (cy, 'Cy Rus', c_e), (zed, 'Zed Zed', z_e), (eve, 'Eve Ng', e_e), (olly, 'Olly Owner', o_e), (fay, 'Fay Fox', f_e), (hal, 'Hal Hill', h_e), (gus, 'Gus Gee', g_e);
  perform tests.login(admin_u, adm); perform public.cms_set_feature('social', true); perform public.cms_publish_rules('Be kind to people. No spam. No hate. Respect each other.'); perform tests.logout();
  perform tests.login(dee, d_e); perform public.save_my_profile('Dee Dee', 'deebill', 'Toronto'); perform public.profile_save_personal('public'); perform public.rules_accept(2);
  perform public.profile_create_business('dj', 'DJ Dee', 'djdeebill'); perform public.profile_create_business('photographer', 'Dee Photos', 'deephotosbill');
  perform tests.login(ann, a_e); perform public.save_my_profile('Ann Lee', 'annbill', 'Toronto'); perform public.profile_save_personal('public'); perform public.rules_accept(2);
  perform public.profile_create_business('mc', 'MC Ann', 'mcannbill');
  perform tests.login(bob, b_e); perform public.save_my_profile('Bob Ray', 'bobbill', 'Toronto'); perform public.profile_save_personal('public'); perform public.rules_accept(2);
  perform tests.login(cy, c_e); perform public.save_my_profile('Cy Rus', 'cybill', 'Toronto'); perform public.profile_save_personal('public'); perform public.rules_accept(2);
  perform tests.login(zed, z_e); perform public.save_my_profile('Zed Zed', 'zedbill', 'Toronto'); perform public.profile_save_personal('public'); perform public.rules_accept(2);
  perform tests.login(eve, e_e); perform public.save_my_profile('Eve Ng', 'evebill', 'Toronto'); perform public.profile_save_personal('public'); perform public.rules_accept(2);
  perform tests.login(fay, f_e); perform public.save_my_profile('Fay Fox', 'faybill', 'Toronto'); perform public.profile_save_personal('public'); perform public.rules_accept(2);
  perform tests.login(hal, h_e); perform public.save_my_profile('Hal Hill', 'halbill', 'Toronto'); perform public.profile_save_personal('public'); perform public.rules_accept(2);
  perform tests.login(gus, g_e); perform public.save_my_profile('Gus Gee', 'gusbill', 'Toronto'); perform public.profile_save_personal('public'); perform public.rules_accept(2);
  perform tests.login(olly, o_e); perform public.save_my_profile('Olly Owner', 'ollybill', 'Toronto'); perform public.profile_save_personal('public'); perform public.rules_accept(2);
  org := public.create_organization('Bill Club Co', 'venue_owner'); va := public.create_org_venue(org, 'Bill Club');
  perform public.profile_create_business('venue', 'Bill Club', 'billclub', null, null, null, va);
  perform tests.logout();
  update public.site_venues set status = 'published' where id = va;
  select id into p_dee from public.site_profiles where user_id = dee and kind = 'personal'; select id into p_ann from public.site_profiles where user_id = ann and kind = 'personal';
  select id into p_bob from public.site_profiles where user_id = bob and kind = 'personal'; select id into p_cy from public.site_profiles where user_id = cy and kind = 'personal';
  select id into p_zed from public.site_profiles where user_id = zed and kind = 'personal'; select id into p_eve from public.site_profiles where user_id = eve and kind = 'personal';
  select id into p_dj from public.site_profiles where handle = 'djdeebill'; select id into p_dj2 from public.site_profiles where handle = 'deephotosbill';
  select id into p_ann_biz from public.site_profiles where handle = 'mcannbill'; select id into p_club from public.site_profiles where handle = 'billclub';
  perform tests.login(eve, e_e); perform public.block_set(p_eve, p_dj, true); perform tests.logout();

  ---------------------------------------------------------------- the switches
  perform tests.assert_eq('subscriptions are off at first', tests.q(dee, d_e, $q$public.sub_plans()$q$), 'ERROR: Subscriptions are not open yet.');
  perform tests.assert_eq('...and so are referrals', tests.q(ann, a_e, format($q$public.referral_code(%L)$q$, p_ann)), 'ERROR: Referrals are not open yet.');
  perform tests.assert_eq('...and tips', tests.q(cy, c_e, format($q$public.tip_begin(%L, 500, null)$q$, p_dj)), 'ERROR: Tips are not open yet.');
  perform tests.login(admin_u, adm); perform public.cms_set_feature('subscriptions', true); perform public.cms_set_feature('referrals', true); perform public.cms_set_feature('creator_earnings', true); perform public.cms_set_feature('marketplace', true); perform tests.logout();
  perform tests.login_anon();
  perform tests.assert_raises('a visitor cannot subscribe', format($q$select public.sub_begin(%L, 'monthly')$q$, p_dj), 'permission denied');
  perform tests.logout();

  ---------------------------------------------------------------- the plans
  perform tests.assert_eq('the prices start at CAD 29.99 a month and 299 a year', tests.q(dee, d_e, $q$(public.sub_plans() ->> 'monthly_cents') || '/' || (public.sub_plans() ->> 'yearly_cents') || '/' || (public.sub_plans() ->> 'currency')$q$), '2999/29900/cad');
  perform tests.assert_eq('...a subscribed profile pays 0% and others 5%', tests.q(dee, d_e, $q$(public.sub_plans() ->> 'subscribed_commission_bps') || '/' || (public.sub_plans() ->> 'standard_commission_bps')$q$), '0/500');

  ---------------------------------------------------------------- starting a subscription
  perform tests.assert_eq('a plan must be monthly or yearly', tests.q(dee, d_e, format($q$public.sub_begin(%L, 'weekly')$q$, p_dj)), 'ERROR: Choose monthly or yearly.');
  perform tests.assert_eq('...and one must be chosen', tests.q(dee, d_e, format($q$public.sub_begin(%L, null)$q$, p_dj)), 'ERROR: Choose monthly or yearly.');
  perform tests.assert_eq('only the owner subscribes: not a stranger', tests.q(ann, a_e, format($q$public.sub_begin(%L, 'monthly')$q$, p_dj)), 'ERROR: Only the owner of a professional''s own profile can subscribe it.');
  perform tests.assert_eq('...not a personal profile', tests.q(dee, d_e, format($q$public.sub_begin(%L, 'monthly')$q$, p_dee)), 'ERROR: Only the owner of a professional''s own profile can subscribe it.');
  perform tests.assert_eq('...nor a venue', tests.q(olly, o_e, format($q$public.sub_begin(%L, 'monthly')$q$, p_club)), 'ERROR: Only the owner of a professional''s own profile can subscribe it.');
  perform tests.assert_eq('...nor a team member, even a manager', tests.f(dee, d_e, format($q$public.team_invite(%L, 'annbill', 'manager')$q$, p_dj), '{status}'), 'invited');
  t_fin := (select id from public.site_profile_team where profile = p_dj and member = ann);
  perform tests.q(ann, a_e, format($q$public.team_answer(%L, true)$q$, t_fin));
  perform tests.assert_eq('...so a manager cannot', tests.q(ann, a_e, format($q$public.sub_begin(%L, 'monthly')$q$, p_dj)), 'ERROR: Only the owner of a professional''s own profile can subscribe it.');
  j := tests.q(dee, d_e, format($q$public.sub_begin(%L, 'monthly')$q$, p_dj))::jsonb;
  sub1 := (j ->> 'subscription_id')::uuid;
  perform tests.assert_true('the owner starts one', sub1 is not null);
  perform tests.assert_eq('...it says what to charge', (j ->> 'amount_cents') || '/' || (j ->> 'currency') || '/' || (j ->> 'plan') || '/' || (j ->> 'profile_name'), '2999/cad/monthly/DJ Dee');
  perform tests.assert_eq('...with the owner as the payer', (select payer from public.site_subscriptions where id = sub1), dee);
  perform tests.assert_true('...with no Stripe price set, it names none', j -> 'price' = 'null'::jsonb);
  perform tests.assert_eq('asking again reuses the one not started yet', (tests.q(dee, d_e, format($q$public.sub_begin(%L, 'monthly')$q$, p_dj))::jsonb ->> 'subscription_id'), sub1::text);
  sub2 := (tests.q(dee, d_e, format($q$public.sub_begin(%L, 'yearly')$q$, p_dj))::jsonb ->> 'subscription_id')::uuid;
  perform tests.assert_eq('...the other plan is another one, with the yearly price', (select plan || '/' || status from public.site_subscriptions where id = sub2), 'yearly/incomplete');
  update public.site_profiles set status = 'suspended' where id = p_dj;
  perform tests.assert_eq('a suspended profile cannot be subscribed', tests.q(dee, d_e, format($q$public.sub_begin(%L, 'monthly')$q$, p_dj)), 'ERROR: Only the owner of a professional''s own profile can subscribe it.');
  update public.site_profiles set status = 'active' where id = p_dj;
  perform tests.assert_eq('nothing is live yet: no status', tests.q(dee, d_e, format($q$public.sub_status(%L)$q$, p_dj)), '(null)');
  perform tests.assert_eq('only the owner reads the status', tests.q(ann, a_e, format($q$public.sub_status(%L)$q$, p_dj)), 'ERROR: Only the owner of a professional''s own profile can manage its subscription.');
  perform tests.assert_eq('the website remembers which Stripe page it opened', tests.svc(format($q$public.sub_attach(%L, 'cs_test_sub1')$q$, sub1)), '');
  perform tests.assert_eq('...once', (select stripe_session from public.site_subscriptions where id = sub1), 'cs_test_sub1');
  perform tests.svc(format($q$public.sub_attach(%L, 'cs_test_other')$q$, sub1));
  perform tests.assert_eq('...it does not change', (select stripe_session from public.site_subscriptions where id = sub1), 'cs_test_sub1');
  perform tests.assert_eq('a session must look like one', tests.svc(format($q$public.sub_attach(%L, 'nonsense')$q$, sub2)), 'ERROR: a Stripe session is needed');
  perform tests.login(dee, d_e);
  perform tests.assert_raises('a person cannot attach', format($q$select public.sub_attach(%L, 'cs_test_x')$q$, sub2), 'permission denied');
  perform tests.logout();

  ---------------------------------------------------------------- what Stripe says
  perform tests.assert_eq('a subscription nobody started is unknown', tests.svcf($q$public.sub_apply('sub_unknown1', 'cus_1', 'active', now() + interval '30 days', false)$q$, '{result}'), 'unknown');
  perform tests.assert_eq('a message about a bad id is refused', tests.svc($q$public.sub_apply('nonsense', 'cus_1', 'active', now() + interval '30 days', false)$q$), 'ERROR: a Stripe subscription is needed');
  perform tests.assert_eq('a status we do not use is ignored', tests.svcf(format($q$public.sub_apply('sub_a1', 'cus_a1', 'incomplete', now() + interval '30 days', false, %L)$q$, sub1), '{result}'), 'ignored');
  perform tests.assert_eq('a person cannot say what Stripe says', tests.q(dee, d_e, format($q$public.sub_apply('sub_a1', 'cus_a1', 'active', now() + interval '30 days', false, %L)$q$, sub1)), 'ERROR: permission denied for function sub_apply');
  perform tests.assert_eq('the first message links Stripe''s subscription to ours and makes it live', tests.svcf(format($q$public.sub_apply('sub_a1', 'cus_a1', 'active', now() + interval '30 days', false, %L)$q$, sub1), '{status}'), 'active');
  perform tests.assert_eq('...the status is read by the owner', tests.f(dee, d_e, format($q$public.sub_status(%L)$q$, p_dj), '{plan}') || '/' || tests.f(dee, d_e, format($q$public.sub_status(%L)$q$, p_dj), '{status}'), 'monthly/active');
  perform tests.assert_eq('...and the profile pays the subscribed commission', public.market_commission_bps(p_dj), 0);
  perform tests.assert_eq('...only until the end of what was paid for', (select (until between now() + interval '29 days' and now() + interval '31 days') from public.site_commission_overrides where profile = p_dj), true);
  perform tests.assert_eq('...the other profile of the same owner still pays the standard one', public.market_commission_bps(p_dj2), 500);
  perform tests.assert_eq('a Stripe subscription cannot be linked to one of ours that is linked to another already', tests.svcf(format($q$public.sub_apply('sub_z9', 'cus_z9', 'active', now() + interval '30 days', false, %L)$q$, sub1), '{result}'), 'unknown');
  perform tests.assert_eq('hearing it twice changes nothing', tests.svcf($q$public.sub_apply('sub_a1', 'cus_a1', 'active', now() + interval '30 days', false)$q$, '{result}'), 'applied');
  perform tests.assert_eq('...still one subscription for the profile', (select count(*) from public.site_subscriptions where profile = p_dj and status = 'active')::int, 1);
  perform tests.assert_eq('a subscription already live blocks another', tests.q(dee, d_e, format($q$public.sub_begin(%L, 'yearly')$q$, p_dj)), 'ERROR: This profile already has a subscription.');
  perform tests.assert_eq('a message without a customer or a period keeps what is known', tests.svcf($q$public.sub_apply('sub_a1', null, 'active', null, false)$q$, '{status}'), 'active');
  perform tests.assert_eq('...the customer', (select stripe_customer from public.site_subscriptions where stripe_subscription = 'sub_a1'), 'cus_a1');
  perform tests.assert_eq('...and the end of the period', (select current_period_end > now() + interval '29 days' from public.site_subscriptions where stripe_subscription = 'sub_a1'), true);
  perform tests.assert_eq('a renewal moves the end of the period', tests.svcf($q$public.sub_apply('sub_a1', 'cus_a1', 'active', now() + interval '60 days', false)$q$, '{status}'), 'active');
  perform tests.assert_eq('...and the override with it', (select until > now() + interval '59 days' from public.site_commission_overrides where profile = p_dj), true);
  perform tests.assert_eq('an older message arriving late does not undo it', tests.svcf($q$public.sub_apply('sub_a1', 'cus_a1', 'canceled', now() + interval '30 days', false)$q$, '{result}'), 'stale');
  perform tests.assert_eq('...it is still live', (select status from public.site_subscriptions where stripe_subscription = 'sub_a1'), 'active');
  perform tests.assert_eq('cancelling at the end of the period is remembered', tests.svc($q$public.sub_apply('sub_a1', 'cus_a1', 'trialing', now() + interval '60 days', true)$q$) like '%applied%', true);
  perform tests.assert_eq('...and the subscription knows it', (select cancel_at_period_end from public.site_subscriptions where stripe_subscription = 'sub_a1'), true);
  perform tests.assert_eq('a payment never made ("unpaid") is the same', tests.svcf($q$public.sub_apply('sub_a1', 'cus_a1', 'unpaid', now() + interval '60 days', false)$q$, '{status}'), 'past_due');
  perform tests.svc($q$public.sub_apply('sub_a1', 'cus_a1', 'active', now() + interval '60 days', false)$q$);
  perform tests.assert_eq('a payment that failed keeps the profile subscribed until the period ends', tests.svcf($q$public.sub_apply('sub_a1', 'cus_a1', 'past_due', now() + interval '60 days', false)$q$, '{status}'), 'past_due');
  perform tests.assert_eq('...the override stays', public.market_commission_bps(p_dj), 0);
  perform tests.assert_eq('...and it still counts as live', tests.q(dee, d_e, format($q$public.sub_begin(%L, 'yearly')$q$, p_dj)), 'ERROR: This profile already has a subscription.');
  perform tests.assert_eq('the portal needs the customer, for the owner only', tests.q(dee, d_e, format($q$public.sub_customer(%L)$q$, p_dj)), 'cus_a1');
  perform tests.assert_eq('...not a manager', tests.q(ann, a_e, format($q$public.sub_customer(%L)$q$, p_dj)), 'ERROR: Only the owner of a professional''s own profile can manage its subscription.');
  perform tests.assert_eq('...and a profile that never subscribed has none', tests.q(dee, d_e, format($q$public.sub_customer(%L)$q$, p_dj2)), 'ERROR: This profile has no subscription to manage.');
  perform tests.assert_eq('a subscription that ends takes the commission away', tests.svcf($q$public.sub_apply('sub_a1', 'cus_a1', 'canceled', now() + interval '60 days', false)$q$, '{status}'), 'cancelled');
  perform tests.assert_eq('...the profile pays the standard one again', public.market_commission_bps(p_dj), 500);
  perform tests.assert_eq('...and the status says so', tests.f(dee, d_e, format($q$public.sub_status(%L)$q$, p_dj), '{status}'), 'cancelled');
  perform tests.assert_eq('the audit log names what Stripe said', (select string_agg(distinct action, ',' order by action) from public.audit_log where action like 'subscription.%'), 'subscription.active,subscription.cancelled,subscription.past_due');
  sub4 := (tests.q(dee, d_e, format($q$public.sub_begin(%L, 'yearly')$q$, p_dj))::jsonb ->> 'subscription_id')::uuid;
  perform tests.svc(format($q$public.sub_apply('sub_y1', 'cus_a1', 'active', now() + interval '300 days', false, %L)$q$, sub4));
  update public.site_subscriptions set updated_at = now() + interval '1 hour' where stripe_subscription = 'sub_a1';
  perform tests.assert_eq('the live subscription is the one shown, not merely the latest', tests.f(dee, d_e, format($q$public.sub_status(%L)$q$, p_dj), '{status}'), 'active');
  perform tests.svc($q$public.sub_apply('sub_y1', 'cus_a1', 'canceled', now() + interval '300 days', false)$q$);
  perform tests.assert_eq('...and it can subscribe again', (tests.q(dee, d_e, format($q$public.sub_begin(%L, 'yearly')$q$, p_dj))::jsonb ->> 'subscription_id') is not null, true);
  perform tests.assert_eq('...with the customer Stripe already knows', tests.q(dee, d_e, format($q$public.sub_begin(%L, 'yearly') ->> 'customer'$q$, p_dj)), 'cus_a1');
  insert into public.site_commission_overrides (profile, commission_bps, until, source) values (p_dj2, 100, now() + interval '10 days', 'staff');
  sub3 := (tests.q(dee, d_e, format($q$public.sub_begin(%L, 'monthly')$q$, p_dj2))::jsonb ->> 'subscription_id')::uuid;
  perform tests.svc(format($q$public.sub_apply('sub_b2', 'cus_b2', 'active', now() + interval '30 days', false, %L)$q$, sub3));
  perform tests.svc(format($q$public.sub_attach(%L, 'cs_test_late')$q$, sub3));
  perform tests.assert_true('a live subscription is not given a new Stripe page', (select stripe_session is null from public.site_subscriptions where id = sub3));
  perform tests.assert_eq('a figure staff set is not replaced by a subscription', public.market_commission_bps(p_dj2), 100);
  perform tests.svc($q$public.sub_apply('sub_b2', 'cus_b2', 'canceled', now() + interval '30 days', false)$q$);
  perform tests.assert_eq('...nor removed by one ending', public.market_commission_bps(p_dj2), 100);
  delete from public.site_commission_overrides;
  sub5 := (tests.q(ann, a_e, format($q$public.sub_begin(%L, 'monthly')$q$, p_ann_biz))::jsonb ->> 'subscription_id')::uuid;
  perform tests.assert_true('another owner does not get the first owner''s Stripe customer', tests.q(ann, a_e, format($q$public.sub_begin(%L, 'monthly') ->> 'customer'$q$, p_ann_biz)) = '(null)');
  perform tests.svc(format($q$public.sub_attach(%L, 'cs_test_ann1')$q$, sub5));
  sub6 := (tests.q(ann, a_e, format($q$public.sub_begin(%L, 'monthly')$q$, p_ann_biz))::jsonb ->> 'subscription_id')::uuid;
  perform tests.assert_true('a subscription whose Stripe page was opened is not reused', sub6 <> sub5);
  perform tests.assert_eq('a start that was never completed can lapse in Stripe', tests.svcf(format($q$public.sub_apply('sub_e5', 'cus_e5', 'incomplete_expired', now(), false, %L)$q$, sub5), '{status}'), 'cancelled');

  ---------------------------------------------------------------- referral codes and claims
  perform tests.assert_eq('a code is made for a profile you act as', length(tests.f(ann, a_e, format($q$public.referral_code(%L)$q$, p_ann), '{code}')), 8);
  code_ann := tests.f(ann, a_e, format($q$public.referral_code(%L)$q$, p_ann), '{code}');
  perform tests.assert_eq('...and is the same next time', tests.f(ann, a_e, format($q$public.referral_code(%L)$q$, p_ann), '{code}'), code_ann);
  perform tests.assert_true('...in capitals and digits', code_ann ~ '^[A-Z0-9]{8}$');
  perform tests.assert_eq('not for a profile you do not run', tests.q(zed, z_e, format($q$public.referral_code(%L)$q$, p_ann)), 'ERROR: You cannot act as this profile.');
  perform tests.assert_true('a business profile has its own', tests.f(ann, a_e, format($q$public.referral_code(%L)$q$, p_ann_biz), '{code}') <> code_ann);
  code_dee := tests.f(dee, d_e, format($q$public.referral_code(%L)$q$, p_dj), '{code}');
  perform tests.assert_eq('a code that is not the right shape', tests.q(bob, b_e, $q$public.referral_claim('abc')$q$), 'ERROR: That code is not right.');
  perform tests.assert_eq('...or empty', tests.q(bob, b_e, $q$public.referral_claim(null)$q$), 'ERROR: That code is not right.');
  perform tests.assert_eq('...or unknown', tests.q(bob, b_e, $q$public.referral_claim('ZZZZZZZZ')$q$), 'ERROR: That code is not right.');
  perform tests.assert_eq('your own code', tests.q(ann, a_e, format($q$public.referral_claim(%L)$q$, code_ann)), 'ERROR: You cannot use your own code.');
  perform tests.assert_eq('...or one of your own other profiles', tests.q(ann, a_e, format($q$public.referral_claim(%L)$q$, tests.f(ann, a_e, format($q$public.referral_code(%L)$q$, p_ann_biz), '{code}'))), 'ERROR: You cannot use your own code.');
  perform tests.assert_eq('...of someone who blocked you', tests.q(eve, e_e, format($q$public.referral_claim(%L)$q$, code_dee)), 'ERROR: That code is not right.');
  perform tests.assert_eq('a code is claimed in lower case too', tests.f(bob, b_e, format($q$public.referral_claim(%L)$q$, lower(' ' || code_ann || ' ')), '{claimed}'), 'true');
  perform tests.assert_eq('...and names who sent the person', tests.f(bob, b_e, $q$public.referral_mine()$q$, '{referrer,display_name}'), 'Ann Lee');
  perform tests.assert_eq('only one code per person', tests.q(bob, b_e, format($q$public.referral_claim(%L)$q$, code_dee)), 'ERROR: You have already used a code.');
  perform tests.assert_eq('someone who used none has no referrer', tests.q(zed, z_e, $q$public.referral_mine()$q$), '(null)');
  select code into code_biz from public.site_referral_codes where profile = p_ann_biz;
  update public.site_profiles set status = 'suspended' where id = p_ann_biz;
  perform tests.assert_eq('a suspended profile''s code does not work', tests.q(zed, z_e, format($q$public.referral_claim(%L)$q$, code_biz)), 'ERROR: That code is not right.');
  update public.site_profiles set status = 'active' where id = p_ann_biz;
  perform tests.login(admin_u, adm); perform public.cms_set_feature('referrals', false); perform tests.logout();
  perform tests.assert_eq('with referrals off nobody sees whom they were sent by', tests.q(bob, b_e, $q$public.referral_mine()$q$), 'ERROR: Referrals are not open yet.');
  perform tests.assert_eq('...or how a code is doing', tests.q(ann, a_e, format($q$public.referral_stats(%L)$q$, p_ann)), 'ERROR: Referrals are not open yet.');
  perform tests.login(admin_u, adm); perform public.cms_set_feature('referrals', true); perform tests.logout();

  ---------------------------------------------------------------- the settings
  perform tests.assert_eq('only an admin reads the money settings', tests.q(dee, d_e, $q$public.cms_billing_settings()$q$), 'ERROR: Only a BottlesUp admin can see this.');
  perform tests.assert_eq('...or changes them', tests.q(dee, d_e, $q$public.cms_billing_settings_set(2999, 29900, null, null, 0, 500, 90, 50, 500, 200, 50000)$q$), 'ERROR: Only a BottlesUp admin can change this.');
  perform tests.assert_eq('the settings start where the plan says', tests.q(admin_u, adm, $q$(public.cms_billing_settings() ->> 'referral_credit_cents') || '/' || (public.cms_billing_settings() ->> 'tip_commission_bps') || '/' || (public.cms_billing_settings() ->> 'referral_days')$q$), '500/500/90');
  perform tests.assert_eq('a monthly price out of range', tests.q(admin_u, adm, $q$public.cms_billing_settings_set(99, 29900, null, null, 0, 500, 90, 50, 500, 200, 50000)$q$), 'ERROR: The monthly price must be between 1.00 and 10,000.00.');
  perform tests.assert_eq('...a monthly price above 10,000', tests.q(admin_u, adm, $q$public.cms_billing_settings_set(1000001, 29900, null, null, 0, 500, 90, 50, 500, 200, 50000)$q$), 'ERROR: The monthly price must be between 1.00 and 10,000.00.');
  perform tests.assert_eq('...a yearly price out of range', tests.q(admin_u, adm, $q$public.cms_billing_settings_set(2999, 10000001, null, null, 0, 500, 90, 50, 500, 200, 50000)$q$), 'ERROR: The yearly price must be between 1.00 and 100,000.00.');
  perform tests.assert_eq('...a Stripe price id that is not one', tests.q(admin_u, adm, $q$public.cms_billing_settings_set(2999, 29900, 'monthly', null, 0, 500, 90, 50, 500, 200, 50000)$q$), 'ERROR: The monthly Stripe price id looks like price_123.');
  perform tests.assert_eq('...in the yearly one too', tests.q(admin_u, adm, $q$public.cms_billing_settings_set(2999, 29900, null, 'yearly', 0, 500, 90, 50, 500, 200, 50000)$q$), 'ERROR: The yearly Stripe price id looks like price_123.');
  perform tests.assert_eq('...a commission above half', tests.q(admin_u, adm, $q$public.cms_billing_settings_set(2999, 29900, null, null, 5001, 500, 90, 50, 500, 200, 50000)$q$), 'ERROR: The subscribed commission must be between 0 and 50 percent.');
  perform tests.assert_eq('...a referral credit above 1,000', tests.q(admin_u, adm, $q$public.cms_billing_settings_set(2999, 29900, null, null, 0, 100001, 90, 50, 500, 200, 50000)$q$), 'ERROR: A referral credit must be between 0 and 1,000.00.');
  perform tests.assert_eq('...referral days out of range', tests.q(admin_u, adm, $q$public.cms_billing_settings_set(2999, 29900, null, null, 0, 500, 0, 50, 500, 200, 50000)$q$), 'ERROR: A referral counts for 1 to 730 days.');
  perform tests.assert_eq('...a cap of none', tests.q(admin_u, adm, $q$public.cms_billing_settings_set(2999, 29900, null, null, 0, 500, 90, 0, 500, 200, 50000)$q$), 'ERROR: The monthly cap must be 1 to 10,000 credits.');
  perform tests.assert_eq('...a tip commission above half', tests.q(admin_u, adm, $q$public.cms_billing_settings_set(2999, 29900, null, null, 0, 500, 90, 50, 5001, 200, 50000)$q$), 'ERROR: The tip commission must be between 0 and 50 percent.');
  perform tests.assert_eq('...the smallest tip below 1.00', tests.q(admin_u, adm, $q$public.cms_billing_settings_set(2999, 29900, null, null, 0, 500, 90, 50, 500, 99, 50000)$q$), 'ERROR: The smallest tip must be between 1.00 and 1,000.00.');
  perform tests.assert_eq('...the biggest tip under the smallest', tests.q(admin_u, adm, $q$public.cms_billing_settings_set(2999, 29900, null, null, 0, 500, 90, 50, 500, 500, 499)$q$), 'ERROR: The biggest tip must be at least the smallest, and at most 10,000.00.');
  perform tests.assert_eq('...the biggest tip over 10,000', tests.q(admin_u, adm, $q$public.cms_billing_settings_set(2999, 29900, null, null, 0, 500, 90, 50, 500, 200, 1000001)$q$), 'ERROR: The biggest tip must be at least the smallest, and at most 10,000.00.');
  perform tests.assert_eq('prices and a Stripe price id can be set', tests.q(admin_u, adm, $q$public.cms_billing_settings_set(1999, 19900, ' price_M123 ', 'price_Y456', 250, 500, 90, 50, 500, 200, 50000) ->> 'sub_monthly_cents'$q$), '1999');
  perform tests.assert_eq('...and the app is told them', tests.q(dee, d_e, $q$(public.sub_plans() ->> 'monthly_cents') || '/' || (public.sub_plans() ->> 'subscribed_commission_bps')$q$), '1999/250');
  perform tests.assert_eq('...the Stripe price id goes to the checkout', tests.q(dee, d_e, format($q$public.sub_begin(%L, 'monthly') ->> 'price'$q$, p_dj2)), 'price_M123');
  perform tests.assert_eq('...and the amount to charge', tests.q(dee, d_e, format($q$public.sub_begin(%L, 'yearly') ->> 'amount_cents'$q$, p_dj2)), '19900');
  perform tests.assert_eq('...the yearly price id for the yearly plan', tests.q(dee, d_e, format($q$public.sub_begin(%L, 'yearly') ->> 'price'$q$, p_dj2)), 'price_Y456');
  perform tests.assert_eq('...and a subscribed profile gets the new commission', tests.svcf(format($q$public.sub_apply('sub_c3', 'cus_c3', 'active', now() + interval '30 days', false, %L)$q$, (select id from public.site_subscriptions where profile = p_dj2 and plan = 'monthly' and status = 'incomplete' limit 1)), '{status}'), 'active');
  perform tests.assert_eq('...at 2.5%', public.market_commission_bps(p_dj2), 250);
  perform tests.svc($q$public.sub_apply('sub_c3', 'cus_c3', 'canceled', now() + interval '30 days', false)$q$);
  perform tests.login(admin_u, adm); perform public.cms_billing_settings_set(2999, 29900, null, null, 0, 500, 90, 50, 500, 200, 50000); perform tests.logout();
  perform tests.assert_eq('the audit log has the change', (select count(*) from public.audit_log where action = 'billing.settings')::int >= 2, true);
  perform tests.assert_eq('only an admin lists the subscriptions', tests.q(dee, d_e, $q$public.cms_subscriptions('all')$q$), 'ERROR: Only a BottlesUp admin can see this.');
  perform tests.assert_eq('...with a status it knows', tests.q(admin_u, adm, $q$public.cms_subscriptions('weird')$q$), 'ERROR: Choose active, past due, cancelled or all.');
  perform tests.assert_eq('...the cancelled ones are listed, and those never started are not', tests.q(admin_u, adm, $q$jsonb_array_length(public.cms_subscriptions('all'))$q$), '5');
  perform tests.assert_eq('...none is active now', tests.q(admin_u, adm, $q$jsonb_array_length(public.cms_subscriptions('active'))$q$), '0');

  ---------------------------------------------------------------- credits for the people sent
  insert into public.site_events (title, description, venue_name, start_date, status) values ('Bill night', 'A night', 'Bill Club', now() + interval '10 days', 'published') returning id into ev;
  insert into public.site_ticket_tiers (event_id, name, price_cents, capacity) values (ev, 'General', 3000, 100) returning id into tier;
  insert into public.site_orders (event_id, tier_id, customer_name, customer_email, quantity, amount_total_cents, status) values (ev, tier, 'Bob', ' ' || upper(b_e) || ' ', 1, 3000, 'pending') returning id into od1;
  perform tests.assert_eq('an order not paid yet credits nobody', (select count(*) from public.site_referral_credits)::int, 0);
  update public.site_orders set status = 'paid' where id = od1;
  perform tests.assert_eq('the first paid order of a referred person credits the referrer, whatever the e-mail''s case', (select count(*) from public.site_referral_credits where referrer = p_ann and source = 'ticket_order' and source_id = od1 and amount_cents = 500 and status = 'payable')::int, 1);
  insert into public.site_orders (event_id, tier_id, customer_name, customer_email, quantity, amount_total_cents, status) values (ev, tier, 'Bob', b_e, 1, 3000, 'paid');
  perform tests.assert_eq('...only the first', (select count(*) from public.site_referral_credits where referred = bob)::int, 1);
  update public.site_orders set status = 'pending' where id = od1;
  update public.site_orders set status = 'paid' where id = od1;
  perform tests.assert_eq('...and a payment heard twice is one credit', (select count(*) from public.site_referral_credits)::int, 1);
  perform tests.login(cy, c_e); perform public.referral_claim(code_ann); perform tests.logout();
  insert into public.site_orders (event_id, tier_id, customer_name, customer_email, quantity, amount_total_cents, status) values (ev, tier, 'Cy', c_e, 2, 6000, 'paid');
  perform tests.assert_eq('an order made paid at once counts too', (select count(*) from public.site_referral_credits where referred = cy)::int, 1);
  insert into public.site_orders (event_id, tier_id, customer_name, customer_email, quantity, amount_total_cents, status) values (ev, tier, 'Zed', z_e, 1, 3000, 'paid');
  perform tests.assert_eq('someone nobody sent credits nobody', (select count(*) from public.site_referral_credits where referred = zed)::int, 0);
  insert into public.site_orders (event_id, tier_id, customer_name, customer_email, quantity, amount_total_cents, status) values (ev, tier, 'Nobody', 'nobody@bill.example', 1, 3000, 'paid');
  perform tests.assert_eq('...nor does an e-mail that belongs to nobody', (select count(*) from public.site_referral_credits)::int, 2);
  perform tests.login(eve, e_e); perform public.referral_claim(code_ann); perform tests.logout();
  update public.site_referrals set claimed_at = now() - interval '100 days' where referred = eve;
  insert into public.site_orders (event_id, tier_id, customer_name, customer_email, quantity, amount_total_cents, status) values (ev, tier, 'Eve', e_e, 1, 3000, 'paid');
  perform tests.assert_eq('a purchase after the window credits nobody', (select count(*) from public.site_referral_credits where referred = eve)::int, 0);
  -- the monthly cap: two credits this month and a cap of two: the next is not made; once those two are older than a month, it is
  update public.site_billing_settings set referral_monthly_cap = 2;
  perform tests.login(zed, z_e); perform public.referral_claim(code_ann); perform tests.logout();
  insert into public.site_orders (event_id, tier_id, customer_name, customer_email, quantity, amount_total_cents, status) values (ev, tier, 'Zed', z_e, 1, 3000, 'paid');
  perform tests.assert_eq('a referrer at the monthly cap earns no more', (select count(*) from public.site_referral_credits where referred = zed)::int, 0);
  update public.site_referral_credits set created_at = now() - interval '40 days';
  insert into public.site_orders (event_id, tier_id, customer_name, customer_email, quantity, amount_total_cents, status) values (ev, tier, 'Zed', z_e, 1, 3000, 'paid');
  perform tests.assert_eq('...credits older than a month do not count towards it', (select count(*) from public.site_referral_credits where referred = zed)::int, 1);
  update public.site_billing_settings set referral_monthly_cap = 50;
  perform tests.login(fay, f_e); perform public.referral_claim(code_ann); perform tests.logout();
  update public.site_billing_settings set referral_credit_cents = 0;
  insert into public.site_orders (event_id, tier_id, customer_name, customer_email, quantity, amount_total_cents, status) values (ev, tier, 'Fay', f_e, 1, 3000, 'paid');
  perform tests.assert_eq('a credit worth nothing is not made', (select count(*) from public.site_referral_credits where referred = fay)::int, 0);
  update public.site_billing_settings set referral_credit_cents = 500;
  perform tests.login(olly, o_e); perform public.referral_claim(code_ann); perform tests.logout();
  perform tests.login(admin_u, adm); perform public.cms_set_feature('referrals', false); perform tests.logout();
  insert into public.site_orders (event_id, tier_id, customer_name, customer_email, quantity, amount_total_cents, status) values (ev, tier, 'Olly', o_e, 1, 3000, 'paid');
  perform tests.assert_eq('with referrals switched off nothing is credited', (select count(*) from public.site_referral_credits where referred = olly)::int, 0);
  perform tests.login(admin_u, adm); perform public.cms_set_feature('referrals', true); perform tests.logout();
  insert into public.site_table_types (venue_id, name, max_guests, min_spend_cents, deposit_cents, inventory_count) values (va, 'Booth', 6, 0, 10000, 5) returning id into tt;
  insert into public.site_venue_time_slots (venue_id, day_of_week, start_time) values (va, 5, '22:00') returning id into ts;
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, status, confirmation_code) values (va, tt, ts, current_date + 3, 'Olly', o_e, 2, 10000, 'paid', 'BILL-1') returning id into tb;
  perform tests.assert_eq('a paid table booking credits the referrer too', (select count(*) from public.site_referral_credits where referred = olly and source = 'table_booking' and source_id = tb)::int, 1);
  perform tests.login(hal, h_e); perform public.referral_claim(code_ann); perform tests.logout();
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, status, confirmation_code) values (va, tt, ts, current_date + 4, 'Hal', h_e, 2, 10000, 'pending', 'BILL-2') returning id into tb;
  perform tests.assert_eq('a table booking not paid yet credits nobody', (select count(*) from public.site_referral_credits where referred = hal)::int, 0);
  update public.site_table_bookings set status = 'paid' where id = tb;
  perform tests.assert_eq('...and one that becomes paid does', (select count(*) from public.site_referral_credits where referred = hal and source_id = tb)::int, 1);
  perform tests.login(gus, g_e); perform public.referral_claim(code_ann); perform tests.logout();
  update public.site_referrals set referrer = null where referred = gus;
  insert into public.site_orders (event_id, tier_id, customer_name, customer_email, quantity, amount_total_cents, status) values (ev, tier, 'Gus', g_e, 1, 3000, 'paid');
  perform tests.assert_eq('a referral whose referrer has gone credits nobody', (select count(*) from public.site_referral_credits where referred = gus)::int, 0);
  update public.site_referrals set referrer = p_ann where referred = gus;
  alter table public.site_referral_credits rename to site_referral_credits_away;
  insert into public.site_orders (event_id, tier_id, customer_name, customer_email, quantity, amount_total_cents, status) values (ev, tier, 'Gus', g_e, 1, 3000, 'paid') returning id into od2;
  alter table public.site_referral_credits_away rename to site_referral_credits;
  perform tests.assert_eq('a purchase is never stopped by the credit going wrong', (select status from public.site_orders where id = od2), 'paid');
  perform tests.assert_eq('...and no credit was made', (select count(*) from public.site_referral_credits where referred = gus)::int, 0);
  insert into public.site_orders (event_id, tier_id, customer_name, customer_email, quantity, amount_total_cents, status) values (ev, tier, 'Gus', g_e, 1, 3000, 'paid');
  perform tests.assert_eq('...the next one is credited', (select count(*) from public.site_referral_credits where referred = gus)::int, 1);
  perform tests.assert_eq('ann sees who used her code, and what it earned', tests.q(ann, a_e, format($q$(public.referral_stats(%L) ->> 'referred') || '/' || (public.referral_stats(%L) ->> 'credited') || '/' || (public.referral_stats(%L) ->> 'payable_cents') || '/' || (public.referral_stats(%L) ->> 'paid_cents') || '/' || (public.referral_stats(%L) ->> 'credit_cents')$q$, p_ann, p_ann, p_ann, p_ann, p_ann)), '8/6/3000/0/500');
  perform tests.assert_eq('the stats are for those who may see the earnings', tests.q(zed, z_e, format($q$public.referral_stats(%L)$q$, p_ann)), 'ERROR: You cannot act as this profile.');
  perform tests.assert_eq('only an admin lists the credits', tests.q(ann, a_e, $q$public.cms_referral_credits('payable')$q$), 'ERROR: Only a BottlesUp admin can see this.');
  perform tests.assert_eq('...with a status it knows', tests.q(admin_u, adm, $q$public.cms_referral_credits('x')$q$), 'ERROR: Choose payable, paid or all.');
  perform tests.assert_eq('...the payable ones are six', tests.q(admin_u, adm, $q$jsonb_array_length(public.cms_referral_credits('payable'))$q$), '6');
  perform tests.assert_eq('...none is paid yet', tests.q(admin_u, adm, $q$jsonb_array_length(public.cms_referral_credits('paid'))$q$), '0');
  perform tests.assert_eq('...with the referrer''s name', tests.q(admin_u, adm, $q$public.cms_referral_credits('payable') -> 0 #>> '{referrer,display_name}'$q$), 'Ann Lee');
  select id into cr1 from public.site_referral_credits order by created_at, id limit 1;
  perform tests.assert_eq('only an admin pays a credit', tests.q(ann, a_e, format($q$public.cms_referral_credit_paid(%L, 'etransfer 1')$q$, cr1)), 'ERROR: Only a BottlesUp admin can do this.');
  perform tests.assert_eq('...with a reference', tests.q(admin_u, adm, format($q$public.cms_referral_credit_paid(%L, '  ')$q$, cr1)), 'ERROR: Write the transfer reference (up to 120 characters).');
  perform tests.assert_eq('...that exists', tests.q(admin_u, adm, $q$public.cms_referral_credit_paid(gen_random_uuid(), 'etransfer 1')$q$), 'ERROR: There is no such credit.');
  perform tests.assert_eq('...and is marked paid', tests.q(admin_u, adm, format($q$public.cms_referral_credit_paid(%L, ' etransfer 1 ') ->> 'status'$q$, cr1)), 'paid');
  perform tests.assert_eq('...with the reference, the time and who paid kept', (select reference || '/' || status || '/' || (paid_at is not null) || '/' || (paid_by = admin_u) from public.site_referral_credits where id = cr1), 'etransfer 1/paid/true/true');
  perform tests.assert_eq('...only once', tests.q(admin_u, adm, format($q$public.cms_referral_credit_paid(%L, 'etransfer 2')$q$, cr1)), 'ERROR: This credit is not waiting to be paid.');
  perform tests.assert_eq('the lists follow the status', tests.q(admin_u, adm, $q$(jsonb_array_length(public.cms_referral_credits('payable'))::text) || '/' || (jsonb_array_length(public.cms_referral_credits('paid'))::text) || '/' || (jsonb_array_length(public.cms_referral_credits('all'))::text)$q$), '5/1/6');
  perform tests.assert_eq('the audit log has the payment', (select count(*) from public.audit_log where action = 'referral.credit_paid')::int, 1);
  perform tests.assert_eq('the stats move it from payable to paid', tests.q(ann, a_e, format($q$(public.referral_stats(%L) ->> 'payable_cents') || '/' || (public.referral_stats(%L) ->> 'paid_cents')$q$, p_ann, p_ann)), '2500/500');

  ---------------------------------------------------------------- tips
  perform tests.assert_eq('a tip below the smallest', tests.q(cy, c_e, format($q$public.tip_begin(%L, 199, null)$q$, p_dj)), 'ERROR: A tip is from 2.00 to 500.00.');
  perform tests.assert_eq('...above the biggest', tests.q(cy, c_e, format($q$public.tip_begin(%L, 50001, null)$q$, p_dj)), 'ERROR: A tip is from 2.00 to 500.00.');
  perform tests.assert_eq('...no amount', tests.q(cy, c_e, format($q$public.tip_begin(%L, null, null)$q$, p_dj)), 'ERROR: A tip is from 2.00 to 500.00.');
  perform tests.assert_eq('a profile of a person cannot be tipped', tests.q(cy, c_e, format($q$public.tip_begin(%L, 500, null)$q$, p_bob)), 'ERROR: This profile cannot be tipped.');
  perform tests.assert_eq('...nor one that does not exist', tests.q(cy, c_e, $q$public.tip_begin(gen_random_uuid(), 500, null)$q$), 'ERROR: This profile cannot be tipped.');
  perform tests.assert_eq('...nor your own', tests.q(dee, d_e, format($q$public.tip_begin(%L, 500, null)$q$, p_dj)), 'ERROR: You cannot tip your own profile.');
  perform tests.assert_eq('...nor one that blocked you', tests.q(eve, e_e, format($q$public.tip_begin(%L, 500, null)$q$, p_dj)), 'ERROR: This profile cannot be tipped.');
  delete from public.site_rules_acceptance where user_id = fay;
  perform tests.assert_eq('tipping needs the community rules accepted', tests.q(fay, f_e, format($q$public.tip_begin(%L, 500, null)$q$, p_dj)), 'ERROR: Read and accept the community rules first.');
  perform tests.login(fay, f_e); perform public.rules_accept(2); perform tests.logout();
  perform tests.assert_eq('...a message that is too long', tests.q(cy, c_e, format($q$public.tip_begin(%L, 500, %L)$q$, p_dj, repeat('x', 201))), 'ERROR: Keep the message to 200 characters.');
  perform tests.login(admin_u, adm); perform public.cms_set_banned_term('forbiddenword', true); perform tests.logout();
  perform tests.assert_eq('...a banned word', tests.q(cy, c_e, format($q$public.tip_begin(%L, 500, 'a forbiddenword tip')$q$, p_dj)), 'ERROR: That wording is not allowed here.');
  update public.site_profiles set status = 'suspended' where id = p_dj;
  perform tests.assert_eq('...a suspended profile', tests.q(cy, c_e, format($q$public.tip_begin(%L, 500, null)$q$, p_dj)), 'ERROR: This profile cannot be tipped.');
  update public.site_profiles set status = 'active' where id = p_dj;
  j := tests.q(cy, c_e, format($q$public.tip_begin(%L, 500, ' Great set ')$q$, p_dj))::jsonb;
  tip1 := (j ->> 'tip_id')::uuid;
  perform tests.assert_eq('a tip is started', (j ->> 'amount_cents') || '/' || (j ->> 'currency') || '/' || (j ->> 'creator_name'), '500/cad/DJ Dee');
  perform tests.assert_eq('...with the commission fixed now and the message trimmed', (select commission_bps || '/' || message || '/' || status from public.site_tips where id = tip1), '500/Great set/created');
  perform tests.assert_eq('the website remembers the Stripe page', tests.svc(format($q$public.tip_attach(%L, 'cs_test_tip1')$q$, tip1)), '');
  perform tests.assert_eq('a session must look like one', tests.svc(format($q$public.tip_attach(%L, 'x')$q$, tip1)), 'ERROR: a Stripe session is needed');
  perform tests.login(cy, c_e);
  perform tests.assert_raises('a person cannot say a tip was paid', $q$select public.tip_paid('cs_test_tip1', 'pi_1', 500)$q$, 'permission denied');
  perform tests.logout();
  perform tests.assert_eq('a payment for no tip is unknown', tests.svcf($q$public.tip_paid('cs_test_nothing', 'pi_1', 500)$q$, '{result}'), 'unknown');
  perform tests.svc(format($q$public.tip_attach(%L, 'cs_test_tip1_other')$q$, tip1));
  perform tests.assert_eq('a tip keeps the first Stripe page it was given', (select stripe_session from public.site_tips where id = tip1), 'cs_test_tip1');
  perform tests.assert_eq('a different amount is not applied', tests.svcf($q$public.tip_paid('cs_test_tip1', 'pi_1', 400)$q$, '{result}'), 'mismatch');
  perform tests.assert_eq('...the tip stays unpaid', (select status from public.site_tips where id = tip1), 'created');
  perform tests.assert_eq('...and it is in the audit log', (select count(*) from public.audit_log where action = 'tip.amount_mismatch')::int, 1);
  perform tests.assert_eq('the right amount is applied, with the creator''s share', tests.svcf($q$public.tip_paid('cs_test_tip1', 'pi_1', 500)$q$, '{net_cents}'), '475');
  perform tests.assert_eq('...once', tests.svcf($q$public.tip_paid('cs_test_tip1', 'pi_1', 500)$q$, '{result}'), 'already');
  perform tests.assert_eq('...paid at a moment', (select paid_at is not null from public.site_tips where id = tip1), true);
  j := tests.q(cy, c_e, format($q$public.tip_begin(%L, 333, null)$q$, p_dj))::jsonb;
  tip2 := (j ->> 'tip_id')::uuid;
  perform tests.svc(format($q$public.tip_attach(%L, 'cs_test_tip2')$q$, tip2));
  perform tests.assert_eq('a tip that does not divide has its commission rounded down for the creator', tests.svcf($q$public.tip_paid('cs_test_tip2', 'pi_2', 333)$q$, '{net_cents}'), '317');
  perform tests.assert_eq('a tip started but not paid is nothing yet', (select count(*) from public.site_tips where status = 'created')::int, 0);
  for n in 1..8 loop
    perform tests.q(cy, c_e, format($q$public.tip_begin(%L, 200, null)$q$, p_dj));
  end loop;
  perform tests.assert_eq('ten tips a day is the limit', tests.q(cy, c_e, format($q$public.tip_begin(%L, 200, null)$q$, p_dj)), 'ERROR: You have sent a lot of tips today. Try again tomorrow.');
  delete from public.site_tips where status = 'created';

  ---------------------------------------------------------------- the earnings overview
  perform tests.assert_eq('a stranger has no overview', tests.q(zed, z_e, format($q$public.earnings_overview(%L)$q$, p_dj)), 'ERROR: You cannot act as this profile.');
  perform tests.assert_eq('the tips alone show first: collected, earned and withdrawable', tests.q(dee, d_e, format($q$(public.earnings_overview(%L) #>> '{tips,collected_cents}') || '/' || (public.earnings_overview(%L) #>> '{tips,earned_cents}') || '/' || (public.earnings_overview(%L) #>> '{tips,withdrawable_cents}') || '/' || (public.earnings_overview(%L) #>> '{tips,paid_cents}') || '/' || (public.earnings_overview(%L) #>> '{tips,count}')$q$, p_dj, p_dj, p_dj, p_dj, p_dj)), '833/792/792/0/2');
  perform tests.assert_eq('...hiring is empty', tests.q(dee, d_e, format($q$(public.earnings_overview(%L) #>> '{hiring,collected_cents}') || '/' || (public.earnings_overview(%L) #>> '{hiring,earned_cents}')$q$, p_dj, p_dj)), '0/0');
  insert into public.site_pro_requests (client, provider, event_date, message) select zed, p_dj, current_date + 20 + g, 'A job ' || g from generate_series(1, 5) g;
  insert into public.site_pro_quotes (request, total_cents, deposit_cents, balance_due_by, scope, valid_until) select r.id, 100000, 30000, current_date + 10, 'Four hours of music', now() + interval '3 days' from public.site_pro_requests r where r.message like 'A job %';
  insert into public.site_pro_bookings (quote, request, client, provider, title, event_date, total_cents, deposit_cents, balance_due_by, commission_bps, free_cancel_days, pay_by, status, paid_cents, completed_at, cancelled_at, cancelled_by)
    select q.id, q.request, zed, p_dj, 'Job ' || r.message, r.event_date, 100000, 30000, current_date + 10, 500, 7, now() + interval '1 day',
           case right(r.message, 1) when '1' then 'active' when '2' then 'completed' when '3' then 'completed' when '5' then 'disputed' else 'cancelled' end,
           case right(r.message, 1) when '1' then 30000 when '2' then 100000 when '3' then 50000 when '5' then 20000 else 7000 end,
           case when right(r.message, 1) in ('2', '3') then now() end,
           case when right(r.message, 1) = '4' then now() end,
           case when right(r.message, 1) = '4' then 'client' end
      from public.site_pro_quotes q join public.site_pro_requests r on r.id = q.request where r.message like 'A job %';
  select id into bk1 from public.site_pro_bookings where title = 'Job A job 2'; select id into bk2 from public.site_pro_bookings where title = 'Job A job 3';
  insert into public.site_pro_payouts (booking, provider, gross_cents, commission_cents, net_cents, status) values (bk1, p_dj, 100000, 5000, 95000, 'releasable');
  insert into public.site_pro_payouts (booking, provider, gross_cents, commission_cents, net_cents, status, reference, paid_at, paid_by) values (bk2, p_dj, 50000, 2500, 47500, 'paid', 'etransfer 9', now(), admin_u);
  insert into public.site_pro_payouts (booking, provider, gross_cents, commission_cents, net_cents, status) select b.id, p_dj, 20000, 1000, 19000, 'held' from public.site_pro_bookings b where b.title = 'Job A job 5';
  insert into public.site_tips (creator, tipper, amount_cents, commission_bps, status) values (p_dj, cy, 700, 500, 'created'), (p_dj, cy, 900, 500, 'void');
  perform tests.assert_eq('hiring keeps collected, held, earned, withdrawable, paid and commission apart', tests.q(dee, d_e, format($q$(public.earnings_overview(%L) #>> '{hiring,collected_cents}') || '/' || (public.earnings_overview(%L) #>> '{hiring,held_cents}') || '/' || (public.earnings_overview(%L) #>> '{hiring,earned_cents}') || '/' || (public.earnings_overview(%L) #>> '{hiring,withdrawable_cents}') || '/' || (public.earnings_overview(%L) #>> '{hiring,paid_cents}') || '/' || (public.earnings_overview(%L) #>> '{hiring,commission_cents}')$q$, p_dj, p_dj, p_dj, p_dj, p_dj, p_dj)), '200000/50000/142500/95000/47500/7500');
  update public.site_pro_payouts set status = 'held' where booking = bk1;
  perform tests.assert_eq('...a held payout is neither earned nor withdrawable', tests.q(dee, d_e, format($q$(public.earnings_overview(%L) #>> '{hiring,earned_cents}') || '/' || (public.earnings_overview(%L) #>> '{hiring,withdrawable_cents}')$q$, p_dj, p_dj)), '47500/0');
  update public.site_pro_payouts set status = 'releasable' where booking = bk1;
  perform tests.assert_eq('tips started or voided are not collected', tests.q(dee, d_e, format($q$(public.earnings_overview(%L) #>> '{tips,collected_cents}') || '/' || (public.earnings_overview(%L) #>> '{tips,count}')$q$, p_dj, p_dj)), '833/2');
  perform tests.assert_eq('referral credits are shown for the profile that earned them', tests.q(ann, a_e, format($q$(public.earnings_overview(%L) #>> '{referrals,earned_cents}') || '/' || (public.earnings_overview(%L) #>> '{referrals,withdrawable_cents}') || '/' || (public.earnings_overview(%L) #>> '{referrals,paid_cents}')$q$, p_ann, p_ann, p_ann)), '3000/2500/500');
  perform tests.assert_eq('a subscription shows when there is a live one', tests.q(dee, d_e, format($q$public.earnings_overview(%L) -> 'subscription'$q$, p_dj)), 'null');
  perform tests.assert_eq('the role decides who sees the earnings: a manager has finance', tests.q(ann, a_e, format($q$public.earnings_overview(%L) #>> '{tips,count}'$q$, p_dj)), '2');
  perform tests.assert_eq('referral figures need the same role', tests.f(dee, d_e, format($q$public.team_invite(%L, 'zedbill', 'booking_agent')$q$, p_dj), '{status}'), 'invited');
  perform tests.q(zed, z_e, format($q$public.team_answer(%L, true)$q$, (select id from public.site_profile_team where profile = p_dj and member = zed)));
  perform tests.assert_eq('...a booking agent is told so', tests.q(zed, z_e, format($q$public.referral_stats(%L)$q$, p_dj)), 'ERROR: Your role on this profile does not allow this.');
  perform tests.assert_eq('...and so is the overview', tests.q(zed, z_e, format($q$public.earnings_overview(%L)$q$, p_dj)), 'ERROR: Your role on this profile does not allow this.');

  ---------------------------------------------------------------- paying creators
  perform tests.assert_eq('only an admin sees what creators can be paid', tests.q(dee, d_e, $q$public.cms_creator_payouts()$q$), 'ERROR: Only a BottlesUp admin can see this.');
  perform tests.assert_eq('the creator and what they can withdraw', tests.q(admin_u, adm, $q$(public.cms_creator_payouts() -> 0 ->> 'name') || '/' || (public.cms_creator_payouts() -> 0 ->> 'tips') || '/' || (public.cms_creator_payouts() -> 0 ->> 'withdrawable_cents') || '/' || (public.cms_creator_payouts() -> 0 #>> '{person,name}')$q$), 'DJ Dee/2/792/Dee Dee');
  perform tests.assert_eq('only an admin records a payment', tests.q(dee, d_e, format($q$public.cms_creator_payout_paid(%L, 'etransfer 5')$q$, p_dj)), 'ERROR: Only a BottlesUp admin can do this.');
  perform tests.assert_eq('...with a reference', tests.q(admin_u, adm, format($q$public.cms_creator_payout_paid(%L, null)$q$, p_dj)), 'ERROR: Write the transfer reference (up to 120 characters).');
  perform tests.assert_eq('...for someone with something to be paid', tests.q(admin_u, adm, format($q$public.cms_creator_payout_paid(%L, 'etransfer 5')$q$, p_dj2)), 'ERROR: There is nothing to pay this creator.');
  perform tests.assert_eq('the payment is recorded for all their tips', tests.q(admin_u, adm, format($q$(public.cms_creator_payout_paid(%L, ' etransfer 5 ') ->> 'tips') || '/' || (public.cms_creator_payout_paid(%L, 'x') ->> 'tips')$q$, p_dj, p_dj)), 'ERROR: There is nothing to pay this creator.');
  perform tests.assert_eq('...in one step: it says the tips and what they come to', tests.q(admin_u, adm, format($q$(public.cms_creator_payout_paid(%L, ' etransfer 5 ') ->> 'tips') || '/' || (public.cms_creator_payout_paid(%L, 'x') ->> 'net_cents')$q$, p_dj, p_dj)), 'ERROR: There is nothing to pay this creator.');
  perform tests.q(admin_u, adm, format($q$public.cms_creator_payout_paid(%L, ' etransfer 5 ')$q$, p_dj));
  perform tests.assert_eq('paying again finds nothing', tests.q(admin_u, adm, format($q$public.cms_creator_payout_paid(%L, 'etransfer 6')$q$, p_dj)), 'ERROR: There is nothing to pay this creator.');
  perform tests.assert_eq('...the tips carry the reference', (select count(*) from public.site_tips where creator = p_dj and paid_out_at is not null and payout_reference = 'etransfer 5')::int, 2);
  perform tests.assert_eq('...tips that were never paid are not marked paid out', (select count(*) from public.site_tips where creator = p_dj and status in ('created', 'void') and paid_out_at is not null)::int, 0);
  perform tests.assert_eq('...and the audit log has the payment', (select count(*) from public.audit_log where action = 'creator.payout_paid')::int, 1);
  perform tests.assert_eq('...and the overview moves it to paid', tests.q(dee, d_e, format($q$(public.earnings_overview(%L) #>> '{tips,withdrawable_cents}') || '/' || (public.earnings_overview(%L) #>> '{tips,paid_cents}')$q$, p_dj, p_dj)), '0/792');
  perform tests.assert_eq('...and nothing is left to list', tests.q(admin_u, adm, $q$jsonb_array_length(public.cms_creator_payouts())$q$), '0');

  ---------------------------------------------------------------- every table is closed
  perform tests.login(dee, d_e);
  perform tests.assert_raises('no table can be read', 'select * from public.site_subscriptions', 'permission denied');
  perform tests.assert_raises('...or the settings', 'select * from public.site_billing_settings', 'permission denied');
  perform tests.assert_raises('...or the codes', 'select * from public.site_referral_codes', 'permission denied');
  perform tests.assert_raises('...or the referrals', 'select * from public.site_referrals', 'permission denied');
  perform tests.assert_raises('...or the credits', 'select * from public.site_referral_credits', 'permission denied');
  perform tests.assert_raises('...or the tips', 'select * from public.site_tips', 'permission denied');
  perform tests.assert_raises('...or the overrides', 'select * from public.site_commission_overrides', 'permission denied');
  perform tests.assert_raises('...or be written to', 'update public.site_billing_settings set sub_monthly_cents = 100', 'permission denied');
  perform tests.assert_raises('the helpers are not callable', 'select public.billing_require(''subscriptions'')', 'permission denied');
  perform tests.assert_raises('...nor the credit itself', 'select public.referral_credit_for(''x@y.example'', ''ticket_order'', gen_random_uuid())', 'permission denied');
  perform tests.logout();
  perform tests.login_anon();
  perform tests.assert_raises('a visitor cannot claim a code', 'select public.referral_claim(''AAAAAAAA'')', 'permission denied');
  perform tests.assert_raises('...or tip', format($q$select public.tip_begin(%L, 500, null)$q$, p_dj), 'permission denied');
  perform tests.logout();
end $$;

rollback;
