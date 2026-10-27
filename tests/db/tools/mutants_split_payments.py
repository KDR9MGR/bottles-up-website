# Mutants for 20261106100000_split_payments.sql:
#   python3 tests/db/tools/mutate_migrations.py tests/db/tools/mutants_split_payments.py --jobs 3
# Run from the repository root.
import os

TARGET = '20261106100000'
TESTS = ['550_split_payments.sql']
SLOW = []
FILE = '20261106100000_split_payments.sql'
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


# Known equivalent changes, kept out on purpose (each guard is also made by something else, so removing it alone changes nothing a caller can see):
#   * split_require_on's sign-in check (a signed-in call always has a user; a visitor has no execute right at all);
#   * an empty e-mail in split_is_host (an empty e-mail never equals a booking's);
#   * split_create's "no arrival time" check (a booking cannot be made without a time slot);
#   * 'sp.status = cancelled' in split_share_state and 'sp.status <> open' / "s.status in (declined, void)" in split_share_paid: cancelling a split also voids every share nobody paid,
#     and a declined share can never have a payment page attached, so each half is covered by the other (the pair together is tested: paid-cancelled-and-void);
#   * the cap `s.applied_cents - s.reversed_cents` in split_share_refunded (refunds are taken surplus first, so what comes off the booking can never exceed what went on);
#   * the `status = paid` half of split_refunds_due's marking (money is only ever recorded on a paid share);
#   * the ordering of split_for_booking (the open split is always also the newest).
MUTANTS = [
    # switch and identity
    M('on-flag', 'split_require_on', "if not public.feature_enabled('split_payments') then raise exception 'Splitting the bill is not open yet.'; end if;", ""),
    M('host-case', 'split_is_host', "lower(btrim(b.customer_email)) = lower(btrim(auth.email()))", "b.customer_email = auth.email()"),
    M('host-anyone', 'split_is_host', "where b.id = p_booking and lower(btrim(b.customer_email)) = lower(btrim(auth.email()))", "where b.id = p_booking"),
    # what a friend is told
    M('state-expired', 'split_share_state', "when now() > sp.deadline then 'expired'", "when false then 'expired'"),
    M('state-pending-lapses', 'split_share_state', "when s.status = 'pending' and s.pending_until > now() then 'pending'", "when s.status = 'pending' then 'pending'"),
    M('state-booking-gone', 'split_share_state', "or sp.status = 'cancelled' or b.status <> 'paid' then 'cancelled'", "or sp.status = 'cancelled' then 'cancelled'"),
    M('state-split-cancelled', 'split_share_state', "when s.status = 'void' or sp.status = 'cancelled' or b.status <> 'paid' then 'cancelled'", "when s.status = 'void' or b.status <> 'paid' then 'cancelled'"),
    M('state-refunded', 'split_share_state', "when s.status = 'paid' and s.refund_due_cents > 0 and s.refunded_cents >= s.refund_due_cents then 'refunded'", "when false then 'refunded'"),
    M('state-refunding', 'split_share_state', "when s.status = 'paid' and s.refund_due_cents > s.refunded_cents then 'refunding'", "when false then 'refunding'"),
    M('state-declined', 'split_share_state', "when s.status = 'declined' then 'declined'", "when false then 'declined'"),
    M('first-name', 'split_first_name', "coalesce(nullif(split_part(btrim(coalesce(pr.name, '')), ' ', 1), ''), nullif(pr.username, ''), 'A friend')", "coalesce(nullif(btrim(coalesce(pr.name, '')), ''), nullif(pr.username, ''), 'A friend')"),
    # the host's card
    M('card-collected', 'split_card', "select coalesce(sum(s.applied_cents - s.reversed_cents), 0)::int into v_collected from public.site_split_shares s where s.split_id = p_split and s.status = 'paid';", "select coalesce(sum(s.applied_cents), 0)::int into v_collected from public.site_split_shares s where s.split_id = p_split and s.status = 'paid';"),
    M('card-outstanding', 'split_card', "public.split_share_state(s.id) in ('unpaid', 'pending');", "public.split_share_state(s.id) in ('unpaid', 'pending', 'expired');"),
    M('card-complete', 'split_card', "when coalesce(v_all_paid, false) then 'complete'", "when false then 'complete'"),
    M('card-expired', 'split_card', "when now() > sp.deadline then 'expired'", "when false then 'expired'"),
    M('card-cancelled', 'split_card', "when sp.status = 'cancelled' then 'cancelled'", "when false then 'cancelled'"),
    # starting a split
    M('create-host', 'split_create', "if not found or not public.split_is_host(p_booking) then raise exception 'This booking is not yours.'; end if;", "if not found then raise exception 'This booking is not yours.'; end if;"),
    M('create-status', 'split_create', "if b.status <> 'paid' then raise exception 'Only a confirmed booking can be split.'; end if;", ""),
    M('create-balance', 'split_create', "if v_balance <= 0 then", "if v_balance < 0 then"),
    M('create-no-time', 'split_create', "if v_hours is null then raise exception 'This booking has no arrival time.'; end if;", ""),
    M('create-over', 'split_create', "if v_hours <= -12 then raise exception 'This booking is over.'; end if;", "if v_hours <= -100 then raise exception 'This booking is over.'; end if;"),
    M('create-over-short', 'split_create', "if v_hours <= -12 then raise exception 'This booking is over.'; end if;", "if v_hours <= -1 then raise exception 'This booking is over.'; end if;"),
    M('create-refund-open', 'split_create', "r.status in ('requested', 'approved', 'processing')) then", "r.status in ('requested', 'approved')) then"),
    M('create-refund-all', 'split_create', "if exists (select 1 from public.site_refund_requests r where r.booking_id = p_booking and r.status in ('requested', 'approved', 'processing')) then", "if false then"),
    M('create-one-open', 'split_create', "if exists (select 1 from public.site_splits s where s.booking_id = p_booking and s.status = 'open') then", "if false then"),
    M('create-rate-late', 'split_create', "s.created_at > now() - interval '1 day') >= 5 then", "s.created_at > now() - interval '1 day') >= 6 then"),
    M('create-rate-early', 'split_create', "s.created_at > now() - interval '1 day') >= 5 then", "s.created_at > now() - interval '1 day') >= 4 then"),
    M('create-rate-window', 'split_create', "s.created_at > now() - interval '1 day') >= 5 then", "s.created_at > now() - interval '1 second') >= 5 then"),
    M('create-rate-host', 'split_create', "where s.host = auth.uid() and s.created_at", "where s.created_at"),
    M('deadline-min', 'split_create', "p_deadline < now() + interval '1 hour' then", "p_deadline < now() + interval '30 minutes' then"),
    M('deadline-min-long', 'split_create', "p_deadline < now() + interval '1 hour' then", "p_deadline < now() + interval '2 hours' then"),
    M('deadline-null', 'split_create', "if p_deadline is null or p_deadline < now()", "if p_deadline < now()"),
    M('deadline-max', 'split_create', "if p_deadline > now() + interval '14 days' then", "if p_deadline > now() + interval '15 days' then"),
    M('deadline-max-short', 'split_create', "if p_deadline > now() + interval '14 days' then", "if p_deadline > now() + interval '13 days' then"),
    M('deadline-night', 'split_create', "(v_hours + 12) * 3600", "(v_hours + 13) * 3600"),
    M('deadline-night-short', 'split_create', "(v_hours + 12) * 3600", "(v_hours + 11) * 3600"),
    M('deadline-night-off', 'split_create', "if p_deadline > now() + make_interval(secs => (v_hours + 12) * 3600) then raise exception 'The deadline cannot be after the booking is over.'; end if;", ""),
    M('shares-none', 'split_create', "or jsonb_array_length(p_shares) < 1 then", "then"),
    M('shares-not-list', 'split_create', "if p_shares is null or jsonb_typeof(p_shares) <> 'array' or", "if p_shares is null or"),
    M('shares-max', 'split_create', "if jsonb_array_length(p_shares) > 20 then", "if jsonb_array_length(p_shares) > 21 then"),
    M('shares-max-short', 'split_create', "if jsonb_array_length(p_shares) > 20 then", "if jsonb_array_length(p_shares) > 19 then"),
    M('share-shape', 'split_create', "if jsonb_typeof(v_item) <> 'object' or jsonb_typeof(v_item -> 'payer') is distinct from 'string' or jsonb_typeof(v_item -> 'amount_cents') is distinct from 'number' then", "if false then"),
    M('share-amount-text', 'split_create', "or jsonb_typeof(v_item -> 'amount_cents') is distinct from 'number' then", "then"),
    M('share-whole', 'split_create', "if (v_item ->> 'amount_cents') !~ '^[0-9]+$' then", "if false then"),
    M('share-min', 'split_create', "if v_amount < 500 then", "if v_amount < 499 then"),
    M('share-min-long', 'split_create', "if v_amount < 500 then", "if v_amount < 501 then"),
    M('share-max', 'split_create', "if v_amount > 500000 then", "if v_amount > 500001 then"),
    M('share-max-short', 'split_create', "if v_amount > 500000 then", "if v_amount > 499999 then"),
    M('share-once', 'split_create', "if v_payer = any (v_seen) then raise exception 'Each friend can be asked once.'; end if;", ""),
    M('share-personal', 'split_create', "where p.id = v_payer and p.kind = 'personal' and p.status = 'active';", "where p.id = v_payer and p.status = 'active';"),
    M('share-active', 'split_create', "where p.id = v_payer and p.kind = 'personal' and p.status = 'active';", "where p.id = v_payer and p.kind = 'personal';"),
    M('share-not-me', 'split_create', "if v_payer_user = auth.uid() then raise exception", "if false then raise exception"),
    M('share-block-by-friend', 'split_create', "(k.blocker_key = v_payer_user and k.blocked_key = auth.uid()) or (k.blocker_key = auth.uid() and k.blocked_key = v_payer_user)", "(k.blocker_key = auth.uid() and k.blocked_key = v_payer_user)"),
    M('share-block-by-host', 'split_create', "(k.blocker_key = v_payer_user and k.blocked_key = auth.uid()) or (k.blocker_key = auth.uid() and k.blocked_key = v_payer_user)", "(k.blocker_key = v_payer_user and k.blocked_key = auth.uid())"),
    M('share-total', 'split_create', "if v_total > v_balance then", "if v_total >= v_balance then"),
    M('share-total-off', 'split_create', "if v_total > v_balance then", "if false then"),
    M('share-total-loose', 'split_create', "if v_total > v_balance then", "if v_total > v_balance + 1 then"),
    M('create-deadline-saved', 'split_create', "insert into public.site_splits (booking_id, host, deadline) values (p_booking, auth.uid(), p_deadline)", "insert into public.site_splits (booking_id, host, deadline) values (p_booking, auth.uid(), now() + interval '1 day')"),
    # looking at it
    M('for-host', 'split_for_booking', "if not public.split_is_host(p_booking) then raise exception 'This booking is not yours.'; end if;", ""),
    # cancelling
    M('cancel-host', 'split_cancel', "if not public.split_is_host(sp.booking_id) then raise exception 'This split is not available.'; end if;", ""),
    M('cancel-twice', 'split_cancel', "if sp.status = 'cancelled' then raise exception 'This split is already cancelled.'; end if;", ""),
    M('cancel-over', 'split_cancel', "if coalesce(public.booking_hours_to_arrival(sp.booking_id), 0) <= -12 then", "if coalesce(public.booking_hours_to_arrival(sp.booking_id), 0) <= -100 then"),
    M('cancel-over-off', 'split_cancel', "if coalesce(public.booking_hours_to_arrival(sp.booking_id), 0) <= -12 then raise exception 'This booking is over, so the split can no longer be cancelled here. Ask the venue.'; end if;", ""),
    M('cancel-void', 'split_cancel', "update public.site_split_shares set status = 'void' where split_id = p_split and status in ('unpaid', 'pending');", ""),
    M('cancel-void-pending', 'split_cancel', "set status = 'void' where split_id = p_split and status in ('unpaid', 'pending');", "set status = 'void' where split_id = p_split and status in ('unpaid');"),
    M('cancel-refund', 'split_cancel', "update public.site_split_shares set refund_due_cents = paid_cents where split_id = p_split and status = 'paid' and refund_due_cents < paid_cents;", ""),
    # a friend
    M('mine-block', 'split_my_shares', "where not exists (select 1 from public.site_blocks k where (k.blocker_key = auth.uid() and k.blocked_key = sp.host) or (k.blocker_key = sp.host and k.blocked_key = auth.uid()))\n           and s.created_at", "where s.created_at"),
    M('mine-block-one-way', 'split_my_shares', "(k.blocker_key = auth.uid() and k.blocked_key = sp.host) or (k.blocker_key = sp.host and k.blocked_key = auth.uid())", "(k.blocker_key = auth.uid() and k.blocked_key = sp.host)"),
    M('mine-block-other-way', 'split_my_shares', "(k.blocker_key = auth.uid() and k.blocked_key = sp.host) or (k.blocker_key = sp.host and k.blocked_key = auth.uid())", "(k.blocker_key = sp.host and k.blocked_key = auth.uid())"),
    M('mine-age', 'split_my_shares', "and s.created_at > now() - interval '60 days'", ""),
    M('mine-age-short', 'split_my_shares', "and s.created_at > now() - interval '60 days'", "and s.created_at > now() - interval '30 days'"),
    M('mine-only', 'split_my_shares', "join public.site_profiles me on me.id = s.payer and me.user_id = auth.uid() and me.kind = 'personal'", "join public.site_profiles me on me.id = s.payer and me.kind = 'personal'"),
    M('status-only', 'split_share_status', "join public.site_profiles me on me.id = x.payer and me.user_id = auth.uid()", "join public.site_profiles me on me.id = x.payer"),
    M('decline-only', 'split_share_decline', "join public.site_profiles me on me.id = x.payer and me.user_id = auth.uid()", "join public.site_profiles me on me.id = x.payer"),
    M('decline-state', 'split_share_decline', "if public.split_share_state(p_share) not in ('unpaid', 'expired') then", "if false then"),
    M('decline-expired', 'split_share_decline', "not in ('unpaid', 'expired')", "not in ('unpaid')"),
    M('decline-set', 'split_share_decline', "update public.site_split_shares set status = 'declined' where id = p_share;", ""),
    M('begin-only', 'split_share_begin', "join public.site_profiles me on me.id = x.payer and me.user_id = auth.uid()", "join public.site_profiles me on me.id = x.payer"),
    M('begin-block', 'split_share_begin', "if exists (select 1 from public.site_blocks k where (k.blocker_key = auth.uid() and k.blocked_key = sp.host) or (k.blocker_key = sp.host and k.blocked_key = auth.uid())) then\n    raise exception 'This request is not available.';\n  end if;", ""),
    M('begin-paid', 'split_share_begin', "if v_state = 'paid' or v_state = 'refunding' or v_state = 'refunded' then raise exception 'You already paid this.'; end if;", ""),
    M('begin-refunding', 'split_share_begin', "if v_state = 'paid' or v_state = 'refunding' or v_state = 'refunded' then", "if v_state = 'paid' then"),
    M('begin-declined', 'split_share_begin', "if v_state = 'declined' then raise exception 'You turned this request down.'; end if;", ""),
    M('begin-cancelled', 'split_share_begin', "if v_state = 'cancelled' then raise exception 'This request was cancelled.'; end if;", ""),
    M('begin-expired', 'split_share_begin', "if v_state = 'expired' then raise exception", "if false then raise exception"),
    M('begin-balance', 'split_share_begin', "if greatest(b.amount_total_cents - b.amount_paid_cents, 0) < s.amount_cents then", "if greatest(b.amount_total_cents - b.amount_paid_cents, 0) <= s.amount_cents then"),
    M('begin-balance-off', 'split_share_begin', "if greatest(b.amount_total_cents - b.amount_paid_cents, 0) < s.amount_cents then", "if false then"),
    M('begin-session', 'split_share_begin', "'pending_session', case when v_state = 'pending' then s.stripe_session_id else null end", "'pending_session', null"),
    M('begin-amount', 'split_share_begin', "'amount_cents', s.amount_cents,\n    'currency', b.currency,", "'amount_cents', b.amount_total_cents,\n    'currency', b.currency,"),
    # the website's payment functions
    M('attach-state', 'split_share_attach', "where id = p_share and status in ('unpaid', 'pending');", "where id = p_share;"),
    M('attach-found', 'split_share_attach', "if not found then raise exception 'this share cannot be paid now'; end if;", ""),
    M('attach-blank', 'split_share_attach', "if p_session is null or btrim(p_session) = '' then raise exception 'a Stripe session is needed'; end if;", ""),
    M('attach-pending', 'split_share_attach', "set status = 'pending', stripe_session_id = p_session, pending_until = p_until", "set stripe_session_id = p_session, pending_until = p_until"),
    M('paid-unknown', 'split_share_paid', "if not found then return jsonb_build_object('result', 'unknown'); end if;", "if not found then return jsonb_build_object('result', 'already'); end if;"),
    M('paid-again', 'split_share_paid', "if s.status = 'paid' then return jsonb_build_object('result', 'already', 'applied_cents', s.applied_cents, 'refund_cents', s.refund_due_cents - s.refunded_cents); end if;", ""),
    M('paid-amount-needed', 'split_share_paid', "if p_amount is null or p_amount <= 0 then raise exception 'an amount is needed'; end if;", ""),
    M('paid-split-cancelled', 'split_share_paid', "if sp.status <> 'open' or sp.host is null or b.status <> 'paid' or s.status in ('declined', 'void') or p_amount <> s.amount_cents then", "if sp.host is null or b.status <> 'paid' or s.status in ('declined', 'void') or p_amount <> s.amount_cents then"),
    M('paid-host-gone', 'split_share_paid', "if sp.status <> 'open' or sp.host is null or b.status <> 'paid' or s.status in ('declined', 'void') or p_amount <> s.amount_cents then", "if sp.status <> 'open' or b.status <> 'paid' or s.status in ('declined', 'void') or p_amount <> s.amount_cents then"),
    M('paid-booking-gone', 'split_share_paid', "if sp.status <> 'open' or sp.host is null or b.status <> 'paid' or s.status in ('declined', 'void') or p_amount <> s.amount_cents then", "if sp.status <> 'open' or sp.host is null or s.status in ('declined', 'void') or p_amount <> s.amount_cents then"),
    M('paid-void', 'split_share_paid', "or s.status in ('declined', 'void') or p_amount <> s.amount_cents then", "or p_amount <> s.amount_cents then"),
    M('paid-cancelled-and-void', 'split_share_paid', "if sp.status <> 'open' or sp.host is null or b.status <> 'paid' or s.status in ('declined', 'void') or p_amount <> s.amount_cents then", "if sp.host is null or b.status <> 'paid' or p_amount <> s.amount_cents then"),
    M('paid-amount-differs', 'split_share_paid', "or s.status in ('declined', 'void') or p_amount <> s.amount_cents then", "or s.status in ('declined', 'void') then"),
    M('paid-refund-all', 'split_share_paid', "paid_cents = p_amount, applied_cents = 0, refund_due_cents = p_amount\n     where id = s.id;", "paid_cents = p_amount, applied_cents = 0, refund_due_cents = 0\n     where id = s.id;"),
    M('paid-cap', 'split_share_paid', "v_apply := least(p_amount, greatest(b.amount_total_cents - b.amount_paid_cents, 0));", "v_apply := p_amount;"),
    M('paid-cap-floor', 'split_share_paid', "v_apply := least(p_amount, greatest(b.amount_total_cents - b.amount_paid_cents, 0));", "v_apply := least(p_amount, b.amount_total_cents - b.amount_paid_cents);"),
    M('paid-apply', 'split_share_paid', "update public.site_table_bookings set amount_paid_cents = amount_paid_cents + v_apply where id = b.id;", ""),
    M('paid-surplus', 'split_share_paid', "applied_cents = v_apply, refund_due_cents = p_amount - v_apply", "applied_cents = v_apply, refund_due_cents = 0"),
    M('paid-answer', 'split_share_paid', "return jsonb_build_object('result', 'applied', 'applied_cents', v_apply, 'refund_cents', p_amount - v_apply);", "return jsonb_build_object('result', 'applied', 'applied_cents', p_amount, 'refund_cents', 0);"),
    # paying back
    M('due-host-gone', 'split_refunds_due', "and (sp.host is null or b.status in ('cancelled', 'refunded'));", "and (b.status in ('cancelled', 'refunded'));"),
    M('due-cancelled', 'split_refunds_due', "b.status in ('cancelled', 'refunded'));", "b.status in ('refunded'));"),
    M('due-refunded', 'split_refunds_due', "b.status in ('cancelled', 'refunded'));", "b.status in ('cancelled'));"),
    M('due-only-fresh', 'split_refunds_due', "and s.status = 'paid' and s.paid_cents > 0 and s.refund_due_cents < s.paid_cents", "and s.status = 'paid' and s.paid_cents > 0 and s.refund_due_cents = 0"),
    M('due-left', 'split_refunds_due', "(s.refund_due_cents - s.refunded_cents)::int", "s.refund_due_cents::int"),
    M('due-listed', 'split_refunds_due', "where s.refund_due_cents > s.refunded_cents and s.stripe_payment_intent_id is not null", "where s.refund_due_cents >= s.refunded_cents and s.stripe_payment_intent_id is not null"),
    M('refunded-blank', 'split_share_refunded', "if p_refund_id is null or btrim(p_refund_id) = '' or p_cents is null or p_cents <= 0 then", "if p_refund_id is null or p_cents is null or p_cents <= 0 then"),
    M('refunded-twice', 'split_share_refunded', "if s.refund_id is not distinct from p_refund_id and s.refunded_cents > 0 then return jsonb_build_object('result', 'already', 'refunded_cents', s.refunded_cents); end if;", ""),
    M('refunded-only-due', 'split_share_refunded', "v_take := least(p_cents, s.refund_due_cents - s.refunded_cents);", "v_take := p_cents;"),
    M('refunded-nothing', 'split_share_refunded', "if v_take <= 0 then return jsonb_build_object('result', 'nothing_due', 'refunded_cents', s.refunded_cents); end if;", ""),
    M('refunded-booking-on', 'split_share_refunded', "if b.status = 'paid' then\n    -- Money paid back", "if true then\n    -- Money paid back"),
    M('refunded-surplus-first', 'split_share_refunded', "v_reverse := least(greatest(v_take - greatest((s.paid_cents - s.applied_cents) - s.refunded_cents, 0), 0), s.applied_cents - s.reversed_cents);", "v_reverse := least(v_take, s.applied_cents - s.reversed_cents);"),
    M('refunded-reverse-cap', 'split_share_refunded', "v_reverse := least(greatest(v_take - greatest((s.paid_cents - s.applied_cents) - s.refunded_cents, 0), 0), s.applied_cents - s.reversed_cents);", "v_reverse := greatest(v_take - greatest((s.paid_cents - s.applied_cents) - s.refunded_cents, 0), 0);"),
    M('refunded-take-off', 'split_share_refunded', "update public.site_table_bookings set amount_paid_cents = greatest(amount_paid_cents - v_reverse, 0) where id = b.id;", ""),
    M('refunded-record', 'split_share_refunded', "set refunded_cents = refunded_cents + v_take, reversed_cents = reversed_cents + v_reverse, refund_id = p_refund_id, refunded_at = clock_timestamp()", "set refunded_cents = refunded_cents + v_take, refund_id = p_refund_id, refunded_at = clock_timestamp()"),
    # who may call what
    ('grant-paid-open', FILE, "public.split_share_attach(uuid, text, timestamptz), public.split_share_paid(text, text, int), public.split_refunds_due(), public.split_share_refunded(uuid, text, int)\nto service_role;", "public.split_share_attach(uuid, text, timestamptz), public.split_share_paid(text, text, int), public.split_refunds_due(), public.split_share_refunded(uuid, text, int)\nto service_role, authenticated;"),
    ('grant-tables-open', FILE, "revoke all on table public.site_splits, public.site_split_shares from public, anon, authenticated;", "revoke all on table public.site_splits from public, anon, authenticated;"),
    ('grant-visitor', FILE, "public.split_share_decline(uuid), public.split_share_begin(uuid)\nto authenticated;", "public.split_share_decline(uuid), public.split_share_begin(uuid)\nto authenticated, anon;"),
]
