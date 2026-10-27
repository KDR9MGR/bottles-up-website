# Mutants for 20261109100000_billing_referrals_earnings.sql:
#   python3 tests/db/tools/mutate_migrations.py tests/db/tools/mutants_billing_referrals_earnings.py --jobs 3
# Run from the repository root.
import os

TARGET = '20261109100000'
TESTS = ['580_billing_referrals_earnings.sql']
SLOW = []
FILE = '20261109100000_billing_referrals_earnings.sql'
_SRC = open(os.path.join(os.getcwd(), 'supabase', 'migrations', FILE)).read()


def M(mid, fn, old, new):
    """A change inside one function, widened to the left line by line until it occurs once in the file."""
    start = _SRC.index('create function public.%s(' % fn)
    end = _SRC.find('\ncreate function', start + 10)
    body = _SRC[start:end if end != -1 else len(_SRC)]
    assert body.count(old) == 1, (mid, fn, old, body.count(old))
    at = start + body.index(old)
    lo = at
    while _SRC.count(_SRC[lo:at + len(old)]) > 1:
        lo = _SRC.rfind('\n', 0, lo - 1) + 1
    ctx = _SRC[lo:at]
    return (mid, FILE, ctx + old, ctx + new)


MUTANTS = [
    # the switches
    M('req-flag', 'billing_require', "if not public.feature_enabled(p_feature) then", "if false then"),
    M('req-sub-msg', 'billing_require', "when 'subscriptions' then 'Subscriptions are not open yet.'", "when 'subscriptions' then 'Tips are not open yet.'"),
    M('req-ref-msg', 'billing_require', "when 'referrals' then 'Referrals are not open yet.'", "when 'referrals' then 'Tips are not open yet.'"),
    M('own-kind', 'billing_owned_profile', "s.kind = 'business' and s.user_id = auth.uid()", "s.user_id = auth.uid()"),
    M('own-user', 'billing_owned_profile', "s.user_id = auth.uid() and s.org_id is null", "s.org_id is null"),
    M('own-active', 'billing_owned_profile', "and s.status = 'active')", ")"),
    # plans and status
    M('plans-std', 'sub_plans', "(select p.commission_bps from public.site_pro_settings p where p.id = 1)", "0"),
    M('plans-sub', 'sub_plans', "'subscribed_commission_bps', s.subscribed_commission_bps", "'subscribed_commission_bps', 0"),
    M('status-own', 'sub_status', "if not public.billing_owned_profile(p_profile) then raise exception 'Only the owner of a professional''s own profile can manage its subscription.'; end if;", ""),
    M('status-incomplete', 'sub_status', "x.profile = p_profile and x.status <> 'incomplete'", "x.profile = p_profile"),
    M('status-live-first', 'sub_status', "order by (x.status in ('active', 'past_due')) desc, x.updated_at desc limit 1", "order by x.updated_at desc limit 1"),
    # starting
    M('begin-plan', 'sub_begin', "if p_plan is null or p_plan not in ('monthly', 'yearly') then raise exception 'Choose monthly or yearly.'; end if;", ""),
    M('begin-plan-null', 'sub_begin', "if p_plan is null or p_plan not in ('monthly', 'yearly') then", "if p_plan not in ('monthly', 'yearly') then"),
    M('begin-own', 'sub_begin', "if not public.billing_owned_profile(p_profile) then raise exception 'Only the owner of a professional''s own profile can subscribe it.'; end if;", ""),
    M('begin-live', 'sub_begin', "if exists (select 1 from public.site_subscriptions x where x.profile = p_profile and x.status in ('active', 'past_due')) then raise exception 'This profile already has a subscription.'; end if;", ""),
    M('begin-live-pastdue', 'sub_begin', "x.profile = p_profile and x.status in ('active', 'past_due')) then", "x.profile = p_profile and x.status in ('active')) then"),
    M('begin-reuse', 'sub_begin', "where x.profile = p_profile and x.status = 'incomplete' and x.plan = p_plan and x.stripe_session is null and x.created_at > now() - interval '1 day'", "where false"),
    M('begin-reuse-plan', 'sub_begin', "x.status = 'incomplete' and x.plan = p_plan and", "x.status = 'incomplete' and"),
    M('begin-reuse-session', 'sub_begin', "x.plan = p_plan and x.stripe_session is null and", "x.plan = p_plan and"),
    M('begin-amount', 'sub_begin', "'amount_cents', case p_plan when 'monthly' then s.sub_monthly_cents else s.sub_yearly_cents end,", "'amount_cents', s.sub_monthly_cents,"),
    M('begin-price', 'sub_begin', "'price', case p_plan when 'monthly' then s.stripe_price_monthly else s.stripe_price_yearly end,", "'price', s.stripe_price_monthly,"),
    M('begin-customer', 'sub_begin', "where x.payer = auth.uid() and x.stripe_customer is not null order by x.updated_at desc limit 1)", "where x.stripe_customer is not null order by x.updated_at desc limit 1)"),
    M('begin-payer', 'sub_begin', "insert into public.site_subscriptions (profile, payer, plan) values (p_profile, auth.uid(), p_plan) returning id into v_id;", "insert into public.site_subscriptions (profile, payer, plan) values (p_profile, null, p_plan) returning id into v_id;"),
    M('attach-regex', 'sub_attach', "if p_session is null or p_session !~ '^cs_[A-Za-z0-9_]+$' then raise exception 'a Stripe session is needed'; end if;", ""),
    M('attach-once', 'sub_attach', "where id = p_sub and status = 'incomplete' and stripe_session is null;", "where id = p_sub;"),
    M('attach-status', 'sub_attach', "where id = p_sub and status = 'incomplete' and stripe_session is null;", "where id = p_sub and stripe_session is null;"),
    M('cust-own', 'sub_customer', "if not public.billing_owned_profile(p_profile) then raise exception 'Only the owner of a professional''s own profile can manage its subscription.'; end if;", ""),
    M('cust-none', 'sub_customer', "if v is null then raise exception 'This profile has no subscription to manage.'; end if;", ""),
    # what Stripe says
    M('apply-regex', 'sub_apply', "if p_stripe_subscription is null or p_stripe_subscription !~ '^sub_[A-Za-z0-9]+$' then raise exception 'a Stripe subscription is needed'; end if;", ""),
    M('apply-trialing', 'sub_apply', "when p_status in ('active', 'trialing') then 'active'", "when p_status in ('active') then 'active'"),
    M('apply-unpaid', 'sub_apply', "when p_status in ('past_due', 'unpaid') then 'past_due'", "when p_status in ('past_due') then 'past_due'"),
    M('apply-expired', 'sub_apply', "when p_status in ('canceled', 'incomplete_expired') then 'cancelled'", "when p_status in ('canceled') then 'cancelled'"),
    M('apply-ignored', 'sub_apply', "if v_status is null then return jsonb_build_object('result', 'ignored'); end if;", ""),
    M('apply-link', 'sub_apply', "where id = p_sub and stripe_subscription is null for update;", "where id = p_sub for update;"),
    M('apply-link-skip', 'sub_apply', "if not found and p_sub is not null then", "if false then"),
    M('apply-unknown', 'sub_apply', "if not found then return jsonb_build_object('result', 'unknown'); end if;", ""),
    M('apply-stale', 'sub_apply', "p_period_end < x.current_period_end then", "p_period_end <= x.current_period_end then"),
    M('apply-stale-all', 'sub_apply', "if x.current_period_end is not null and p_period_end is not null and p_period_end < x.current_period_end then return jsonb_build_object('result', 'stale', 'profile', x.profile, 'status', x.status); end if;", ""),
    M('apply-customer', 'sub_apply', "stripe_customer = coalesce(p_customer, stripe_customer)", "stripe_customer = p_customer"),
    M('apply-end', 'sub_apply', "current_period_end = coalesce(p_period_end, current_period_end)", "current_period_end = p_period_end"),
    M('apply-cancel-flag', 'sub_apply', "cancel_at_period_end = coalesce(p_cancel_at_end, false)", "cancel_at_period_end = false"),
    M('apply-override', 'sub_apply', "if v_status = 'active' and coalesce(p_period_end, x.current_period_end) is not null then", "if false then"),
    M('apply-override-bps', 'sub_apply', "values (x.profile, s.subscribed_commission_bps, coalesce(p_period_end, x.current_period_end), 'subscription')", "values (x.profile, 0, coalesce(p_period_end, x.current_period_end), 'subscription')"),
    M('apply-override-until', 'sub_apply', "values (x.profile, s.subscribed_commission_bps, coalesce(p_period_end, x.current_period_end), 'subscription')", "values (x.profile, s.subscribed_commission_bps, now() + interval '3650 days', 'subscription')"),
    M('apply-override-staff', 'sub_apply', "where public.site_commission_overrides.source = 'subscription';", ";"),
    M('apply-override-update', 'sub_apply', "on conflict (profile) do update set commission_bps = excluded.commission_bps, until = excluded.until, source = excluded.source, updated_at = clock_timestamp()\n      where public.site_commission_overrides.source = 'subscription';", "on conflict (profile) do nothing;"),
    M('apply-cancel-delete', 'sub_apply', "delete from public.site_commission_overrides where profile = x.profile and source = 'subscription';", ""),
    M('apply-cancel-staff', 'sub_apply', "where profile = x.profile and source = 'subscription';", "where profile = x.profile;"),
    M('apply-audit', 'sub_apply', "'subscription.' || v_status", "'subscription.changed'"),
    # referrals
    M('code-flag', 'referral_code', "perform public.billing_require('referrals');", ""),
    M('code-actor', 'referral_code', "perform public.profile_require_actor(p_profile);", ""),
    M('claim-once', 'referral_claim', "if exists (select 1 from public.site_referrals r where r.referred = auth.uid()) then raise exception 'You have already used a code.'; end if;", ""),
    M('claim-active', 'referral_claim', "where c.code = v_code and s.status = 'active';", "where c.code = v_code;"),
    M('claim-unknown', 'referral_claim', "if v_profile is null then raise exception 'That code is not right.'; end if;", ""),
    M('claim-own', 'referral_claim', "if public.profile_is_mine(v_profile) then raise exception 'You cannot use your own code.'; end if;", ""),
    M('claim-block', 'referral_claim', "if public.profile_blocked_between((select p.id from public.site_profiles p where p.user_id = auth.uid() and p.kind = 'personal'), v_profile) then raise exception 'That code is not right.'; end if;", ""),
    M('claim-upper', 'referral_claim', "v_code text := upper(btrim(coalesce(p_code, '')));", "v_code text := btrim(coalesce(p_code, ''));"),
    M('mine-flag', 'referral_mine', "perform public.billing_require('referrals');", ""),
    M('stats-perm', 'referral_stats', "perform public.profile_require_permission(p_profile, 'finance');", "perform public.profile_require_actor(p_profile);"),
    M('stats-flag', 'referral_stats', "perform public.billing_require('referrals');", ""),
    M('stats-payable', 'referral_stats', "where c.referrer = p_profile and c.status = 'payable'", "where c.referrer = p_profile"),
    M('stats-paid', 'referral_stats', "where c.referrer = p_profile and c.status = 'paid'", "where c.referrer = p_profile"),
    M('credit-flag', 'referral_credit_for', "if not public.feature_enabled('referrals') then return; end if;", ""),
    M('credit-email', 'referral_credit_for', "where lower(u.email) = lower(btrim(p_email)) limit 1;", "where u.email = p_email limit 1;"),
    M('credit-noref', 'referral_credit_for', "if not found or r.referrer is null then return; end if;", "if not found then return; end if;"),
    M('credit-window', 'referral_credit_for', "r.claimed_at < now() - make_interval(days => s.referral_days) then return; end if;", "false then return; end if;"),
    M('credit-first', 'referral_credit_for', "if exists (select 1 from public.site_referral_credits c where c.referred = v_user) then return; end if;", ""),
    M('credit-cap', 'referral_credit_for', "c.created_at > now() - interval '30 days') >= s.referral_monthly_cap then return; end if;", "c.created_at > now() - interval '30 days') > s.referral_monthly_cap then return; end if;"),
    M('credit-cap-window', 'referral_credit_for', "c.created_at > now() - interval '30 days') >= s.referral_monthly_cap", "true) >= s.referral_monthly_cap"),
    M('credit-amount', 'referral_credit_for', "values (r.referrer, v_user, p_source, p_source_id, s.referral_credit_cents)", "values (r.referrer, v_user, p_source, p_source_id, 1)"),
    M('trig-swallow', 'referral_trigger', "exception when others then\n    null;", "exception when no_data_found then\n    null;"),
    M('trig-source', 'referral_trigger', "case tg_table_name when 'site_orders' then 'ticket_order' else 'table_booking' end", "'ticket_order'"),
    ('trig-order-when', FILE, "create trigger site_orders_referral_credit after insert on public.site_orders for each row when (new.status = 'paid')", "create trigger site_orders_referral_credit after insert on public.site_orders for each row when (true)"),
    ('trig-order-update', FILE, "create trigger site_orders_referral_credit_paid after update of status on public.site_orders for each row when (new.status = 'paid' and old.status is distinct from 'paid')", "create trigger site_orders_referral_credit_paid after update of status on public.site_orders for each row when (new.status = 'pending')"),
    ('trig-table-insert', FILE, "create trigger site_table_bookings_referral_credit after insert on public.site_table_bookings for each row when (new.status = 'paid')", "create trigger site_table_bookings_referral_credit after insert on public.site_table_bookings for each row when (false)"),
    ('trig-table-update', FILE, "create trigger site_table_bookings_referral_credit_paid after update of status on public.site_table_bookings for each row when (new.status = 'paid' and old.status is distinct from 'paid')", "create trigger site_table_bookings_referral_credit_paid after update of status on public.site_table_bookings for each row when (false)"),
    # tips
    M('tip-flag', 'tip_begin', "perform public.billing_require('creator_earnings');", ""),
    M('tip-rules', 'tip_begin', "perform public.social_require_rules();", ""),
    M('tip-creator', 'tip_begin', "c.status = 'active' and c.privacy = 'public' and c.kind = 'business'", "c.status = 'active' and c.privacy = 'public'"),
    M('tip-active', 'tip_begin', "c.status = 'active' and c.privacy = 'public'", "c.privacy = 'public'"),
    M('tip-own', 'tip_begin', "if public.profile_is_mine(p_creator) then raise exception 'You cannot tip your own profile.'; end if;", ""),
    M('tip-block', 'tip_begin', "if v_me is not null and public.profile_blocked_between(v_me, p_creator) then raise exception 'This profile cannot be tipped.'; end if;", ""),
    M('tip-min', 'tip_begin', "p_amount_cents < s.tip_min_cents or", "p_amount_cents < s.tip_min_cents - 1 or"),
    M('tip-max', 'tip_begin', "p_amount_cents > s.tip_max_cents then", "p_amount_cents > s.tip_max_cents + 1 then"),
    M('tip-amount-null', 'tip_begin', "if p_amount_cents is null or p_amount_cents < s.tip_min_cents", "if p_amount_cents < s.tip_min_cents"),
    M('tip-msg', 'tip_begin', "if v_msg is not null and char_length(v_msg) > 200 then", "if v_msg is not null and char_length(v_msg) > 201 then"),
    M('tip-words', 'tip_begin', "if not public.social_text_ok(v_msg) then raise exception 'That wording is not allowed here.'; end if;", ""),
    M('tip-daily', 'tip_begin', "t.created_at > now() - interval '1 day') >= 10 then", "t.created_at > now() - interval '1 day') >= 11 then"),
    M('tip-commission', 'tip_begin', "values (p_creator, auth.uid(), p_amount_cents, s.tip_commission_bps, v_msg)", "values (p_creator, auth.uid(), p_amount_cents, 0, v_msg)"),
    M('tip-attach-regex', 'tip_attach', "if p_session is null or p_session !~ '^cs_[A-Za-z0-9_]+$' then raise exception 'a Stripe session is needed'; end if;", ""),
    M('tip-attach-once', 'tip_attach', "where id = p_tip and status = 'created' and stripe_session is null;", "where id = p_tip;"),
    M('tip-unknown', 'tip_paid', "if not found then return jsonb_build_object('result', 'unknown'); end if;", ""),
    M('tip-already', 'tip_paid', "if t.status = 'paid' then return jsonb_build_object('result', 'already'); end if;", ""),
    M('tip-mismatch', 'tip_paid', "if p_amount is distinct from t.amount_cents then", "if false then"),
    M('tip-mismatch-audit', 'tip_paid', "'tip.amount_mismatch'", "'tip.mismatch'"),
    M('tip-set', 'tip_paid', "update public.site_tips set status = 'paid', paid_at = clock_timestamp(), stripe_payment_intent = p_payment_intent where id = t.id;", "update public.site_tips set status = 'paid', stripe_payment_intent = p_payment_intent where id = t.id;"),
    M('tip-net', 'tip_paid', "'net_cents', t.amount_cents - (t.amount_cents::bigint * t.commission_bps / 10000)::int", "'net_cents', t.amount_cents"),
    # the overview
    M('ov-perm', 'earnings_overview', "perform public.profile_require_permission(p_profile, 'finance');", "perform public.profile_require_actor(p_profile);"),
    M('ov-collected', 'earnings_overview', "b.provider = p_profile and b.status in ('active', 'disputed', 'completed')), 0),", "b.provider = p_profile and b.status in ('active', 'completed')), 0),"),
    M('ov-collected-all', 'earnings_overview', "b.provider = p_profile and b.status in ('active', 'disputed', 'completed')), 0),", "b.provider = p_profile), 0),"),
    M('ov-held', 'earnings_overview', "b.provider = p_profile and b.status in ('active', 'disputed')), 0),", "b.provider = p_profile and b.status in ('active')), 0),"),
    M('ov-held-done', 'earnings_overview', "b.provider = p_profile and b.status in ('active', 'disputed')), 0),", "b.provider = p_profile and b.status in ('active', 'disputed', 'completed')), 0),"),
    M('ov-earned', 'earnings_overview', "from public.site_pro_payouts o where o.provider = p_profile and o.status in ('releasable', 'paid')), 0),\n      'withdrawable_cents'", "from public.site_pro_payouts o where o.provider = p_profile), 0),\n      'withdrawable_cents'"),
    M('ov-withdrawable', 'earnings_overview', "o.provider = p_profile and o.status = 'releasable'), 0),", "o.provider = p_profile and o.status in ('releasable', 'paid')), 0),"),
    M('ov-paid', 'earnings_overview', "o.provider = p_profile and o.status = 'paid'), 0),", "o.provider = p_profile and o.status in ('releasable', 'paid')), 0),"),
    M('ov-commission', 'earnings_overview', "sum(o.commission_cents) from public.site_pro_payouts o where o.provider = p_profile and o.status in ('releasable', 'paid')", "sum(o.commission_cents) from public.site_pro_payouts o where o.provider = p_profile"),
    M('ov-tip-collected', 'earnings_overview', "sum(t.amount_cents) from public.site_tips t where t.creator = p_profile and t.status = 'paid'", "sum(t.amount_cents) from public.site_tips t where t.creator = p_profile"),
    M('ov-tip-earned', 'earnings_overview', "'earned_cents', coalesce((select sum(t.amount_cents - (t.amount_cents::bigint * t.commission_bps / 10000)::int) from public.site_tips t where t.creator = p_profile and t.status = 'paid'), 0),", "'earned_cents', coalesce((select sum(t.amount_cents) from public.site_tips t where t.creator = p_profile and t.status = 'paid'), 0),"),
    M('ov-tip-withdrawable', 'earnings_overview', "and t.status = 'paid' and t.paid_out_at is null), 0),", "and t.status = 'paid'), 0),"),
    M('ov-tip-paid', 'earnings_overview', "and t.status = 'paid' and t.paid_out_at is not null), 0),", "and t.status = 'paid'), 0),"),
    M('ov-tip-count', 'earnings_overview', "'count', (select count(*) from public.site_tips t where t.creator = p_profile and t.status = 'paid')", "'count', (select count(*) from public.site_tips t where t.creator = p_profile)"),
    M('ov-ref-earned', 'earnings_overview', "'earned_cents', coalesce((select sum(c.amount_cents) from public.site_referral_credits c where c.referrer = p_profile), 0),", "'earned_cents', 0,"),
    M('ov-ref-withdrawable', 'earnings_overview', "c.referrer = p_profile and c.status = 'payable'), 0),", "c.referrer = p_profile), 0),"),
    M('ov-ref-paid', 'earnings_overview', "c.referrer = p_profile and c.status = 'paid'), 0)),", "c.referrer = p_profile), 0)),"),
    M('ov-sub', 'earnings_overview', "from public.site_subscriptions x where x.profile = p_profile and x.status in ('active', 'past_due') limit 1)", "from public.site_subscriptions x where x.profile = p_profile limit 1)"),
    # the CMS
    M('set-admin', 'cms_billing_settings', "if auth.uid() is null or not public.is_cms_admin() then raise exception 'Only a BottlesUp admin can see this.'; end if;", ""),
    M('set-set-admin', 'cms_billing_settings_set', "if auth.uid() is null or not public.is_cms_admin() then raise exception 'Only a BottlesUp admin can change this.'; end if;", ""),
    M('set-monthly', 'cms_billing_settings_set', "if p_monthly_cents is null or p_monthly_cents < 100 or p_monthly_cents > 1000000 then", "if p_monthly_cents is null or p_monthly_cents < 99 or p_monthly_cents > 1000000 then"),
    M('set-monthly-max', 'cms_billing_settings_set', "p_monthly_cents > 1000000 then", "p_monthly_cents > 1000001 then"),
    M('set-yearly', 'cms_billing_settings_set', "if p_yearly_cents is null or p_yearly_cents < 100 or p_yearly_cents > 10000000 then", "if p_yearly_cents is null or p_yearly_cents < 100 or p_yearly_cents > 10000001 then"),
    M('set-price-m', 'cms_billing_settings_set', "if v_pm is not null and v_pm !~ '^price_[A-Za-z0-9]+$' then raise exception 'The monthly Stripe price id looks like price_123.'; end if;", ""),
    M('set-price-y', 'cms_billing_settings_set', "if v_py is not null and v_py !~ '^price_[A-Za-z0-9]+$' then raise exception 'The yearly Stripe price id looks like price_123.'; end if;", ""),
    M('set-sub-bps', 'cms_billing_settings_set', "p_subscribed_commission_bps > 5000 then", "p_subscribed_commission_bps > 5001 then"),
    M('set-credit', 'cms_billing_settings_set', "p_referral_credit_cents > 100000 then", "p_referral_credit_cents > 100001 then"),
    M('set-days', 'cms_billing_settings_set', "if p_referral_days is null or p_referral_days < 1 or p_referral_days > 730 then", "if p_referral_days is null or p_referral_days < 0 or p_referral_days > 730 then"),
    M('set-cap', 'cms_billing_settings_set', "if p_referral_monthly_cap is null or p_referral_monthly_cap < 1 or p_referral_monthly_cap > 10000 then", "if p_referral_monthly_cap is null or p_referral_monthly_cap < 0 or p_referral_monthly_cap > 10000 then"),
    M('set-tip-bps', 'cms_billing_settings_set', "p_tip_commission_bps > 5000 then", "p_tip_commission_bps > 5001 then"),
    M('set-tip-min', 'cms_billing_settings_set', "if p_tip_min_cents is null or p_tip_min_cents < 100 or p_tip_min_cents > 100000 then", "if p_tip_min_cents is null or p_tip_min_cents < 99 or p_tip_min_cents > 100000 then"),
    M('set-tip-max', 'cms_billing_settings_set', "p_tip_max_cents < p_tip_min_cents or", "p_tip_max_cents < p_tip_min_cents - 1 or"),
    M('set-tip-max-top', 'cms_billing_settings_set', "p_tip_max_cents > 1000000 then", "p_tip_max_cents > 1000001 then"),
    M('set-audit', 'cms_billing_settings_set', "'billing.settings'", "'billing.changed'"),
    M('set-save', 'cms_billing_settings_set', "sub_monthly_cents = p_monthly_cents, sub_yearly_cents = p_yearly_cents,", "sub_monthly_cents = p_monthly_cents,"),
    M('subs-admin', 'cms_subscriptions', "if auth.uid() is null or not public.is_cms_admin() then raise exception 'Only a BottlesUp admin can see this.'; end if;", ""),
    M('subs-status', 'cms_subscriptions', "if p_status is null or p_status not in ('active', 'past_due', 'cancelled', 'all') then raise exception 'Choose active, past due, cancelled or all.'; end if;", ""),
    M('subs-incomplete', 'cms_subscriptions', "where x.status <> 'incomplete' and", "where"),
    M('cred-admin', 'cms_referral_credits', "if auth.uid() is null or not public.is_cms_admin() then raise exception 'Only a BottlesUp admin can see this.'; end if;", ""),
    M('cred-status', 'cms_referral_credits', "if p_status is null or p_status not in ('payable', 'paid', 'all') then raise exception 'Choose payable, paid or all.'; end if;", ""),
    M('cred-filter', 'cms_referral_credits', "where p_status = 'all' or c.status = p_status", "where true"),
    M('paid-admin', 'cms_referral_credit_paid', "if auth.uid() is null or not public.is_cms_admin() then raise exception 'Only a BottlesUp admin can do this.'; end if;", ""),
    M('paid-ref', 'cms_referral_credit_paid', "if v_ref is null or char_length(v_ref) > 120 then raise exception 'Write the transfer reference (up to 120 characters).'; end if;", ""),
    M('paid-exists', 'cms_referral_credit_paid', "if not found then raise exception 'There is no such credit.'; end if;", ""),
    M('paid-status', 'cms_referral_credit_paid', "if c.status <> 'payable' then raise exception 'This credit is not waiting to be paid.'; end if;", ""),
    M('paid-set', 'cms_referral_credit_paid', "set status = 'paid', reference = v_ref, paid_at = clock_timestamp(), paid_by = auth.uid()", "set status = 'paid', reference = v_ref, paid_at = clock_timestamp()"),
    M('paid-audit', 'cms_referral_credit_paid', "'referral.credit_paid'", "'referral.paid'"),
    M('cp-admin', 'cms_creator_payouts', "if auth.uid() is null or not public.is_cms_admin() then raise exception 'Only a BottlesUp admin can see this.'; end if;", ""),
    M('cp-status', 'cms_creator_payouts', "x.status = 'paid' and x.paid_out_at is null and x.creator is not null", "x.status = 'paid' and x.creator is not null"),
    M('cp-net', 'cms_creator_payouts', "sum(x.amount_cents - (x.amount_cents::bigint * x.commission_bps / 10000)::int)::int as net", "sum(x.amount_cents)::int as net"),
    M('cpp-admin', 'cms_creator_payout_paid', "if auth.uid() is null or not public.is_cms_admin() then raise exception 'Only a BottlesUp admin can do this.'; end if;", ""),
    M('cpp-ref', 'cms_creator_payout_paid', "if v_ref is null or char_length(v_ref) > 120 then raise exception 'Write the transfer reference (up to 120 characters).'; end if;", ""),
    M('cpp-none', 'cms_creator_payout_paid', "if v_n = 0 then raise exception 'There is nothing to pay this creator.'; end if;", ""),
    M('cpp-set', 'cms_creator_payout_paid', "update public.site_tips set paid_out_at = clock_timestamp(), payout_reference = v_ref where creator = p_creator and status = 'paid' and paid_out_at is null;", "update public.site_tips set paid_out_at = clock_timestamp(), payout_reference = v_ref where creator = p_creator;"),
    M('cpp-audit', 'cms_creator_payout_paid', "'creator.payout_paid'", "'creator.paid'"),
    # who may call what
    ('grant-tables', FILE, "revoke all on table public.site_billing_settings, public.site_subscriptions,", "revoke all on table public.site_subscriptions,"),
    ('grant-tips', FILE, "public.site_referral_credits, public.site_tips from public, anon, authenticated;", "public.site_referral_credits from public, anon, authenticated;"),
    ('grant-apply', FILE, "public.sub_attach(uuid, text), public.sub_apply(text, text, text, timestamptz, boolean, uuid), public.tip_attach(uuid, text), public.tip_paid(text, text, int)\nto service_role;", "public.sub_attach(uuid, text), public.sub_apply(text, text, text, timestamptz, boolean, uuid), public.tip_attach(uuid, text), public.tip_paid(text, text, int)\nto service_role, authenticated;"),
    M('tipst-flag', 'tip_status', "perform public.billing_require('creator_earnings');", ""),
    M('tipst-own', 'tip_status', "where t.id = p_tip and t.tipper = auth.uid());", "where t.id = p_tip);"),
    M('tipst-status', 'tip_status', "'status', t.status,", "'status', 'paid',"),
    M('tipst-amount', 'tip_status', "'amount_cents', t.amount_cents,", "'amount_cents', 0,"),
    M('tipst-currency', 'tip_status', "(select b.currency from public.site_billing_settings b where b.id = 1)", "'usd'"),
    M('tipst-creator', 'tip_status', "public.profile_mini(t.creator)", "null"),
    ('grant-tipst', FILE, "public.tip_begin(uuid, int, text), public.tip_status(uuid), public.earnings_overview(uuid), public.cms_billing_settings(),", "public.tip_begin(uuid, int, text), public.earnings_overview(uuid), public.cms_billing_settings(),"),
    ('grant-tipst-visitor', FILE, "public.tip_begin(uuid, int, text), public.tip_attach(uuid, text), public.tip_status(uuid), public.tip_paid(text, text, int), public.earnings_overview(uuid),", "public.tip_begin(uuid, int, text), public.tip_attach(uuid, text), public.tip_paid(text, text, int), public.earnings_overview(uuid),"),
    ('grant-helper', FILE, "revoke all on function\n  public.billing_require(text), public.billing_owned_profile(uuid),", "revoke all on function\n  public.billing_owned_profile(uuid),"),
    ('grant-credit', FILE, "  public.referral_credit_for(text, text, uuid), public.referral_trigger(),", "  public.referral_trigger(),"),
    ('grant-visitor', FILE, "public.cms_referral_credit_paid(uuid, text), public.cms_creator_payouts(), public.cms_creator_payout_paid(uuid, text)\nto authenticated;", "public.cms_referral_credit_paid(uuid, text), public.cms_creator_payouts(), public.cms_creator_payout_paid(uuid, text)\nto authenticated, anon;"),
]

# Known equivalent changes, kept out on purpose (each guard is also made by something else, so removing it alone changes nothing a caller can see):
#   * the shape check on a referral code in referral_claim: a code that is not 8 capitals and digits is not in the table, so the lookup turns it away with the same sentence;
#   * reading the existing code before the loop in referral_code: the insert then fails on the profile's key and the handler reads the same code;
#   * the missing-user return in referral_credit_for: no referral is found for a null user, so the next line returns;
#   * the zero test in referral_credit_for: a credit of nothing is refused by the table's own check and the trigger swallows it;
#   * the order of a payer's Stripe customers in sub_customer: one payer has one Stripe customer;
#   * the sign-in test in billing_require: only a signed-in role is granted these functions.
