import { beforeEach, describe, expect, it, vi } from 'vitest';
import {
  applySubscription,
  fulfillSubscriptionCheckout,
  fulfillTip,
  parseCents,
  parseNote,
  parsePlan,
  parseUuid,
  subscriptionName,
  subscriptionSessionParams,
  TIP_SESSION_MINUTES,
  tipName,
  tipSessionParams,
  type DbLike,
  type SubBegin,
  type TipBegin,
} from '../../supabase/functions/_shared/billing.ts';

const ID = '3f2b8c1e-5a4d-4e7a-9b1c-0d6e8f7a2b3c';
const sub: SubBegin = { subscription_id: ID, plan: 'monthly', currency: 'cad', amount_cents: 2999, price: null, customer: null, profile_name: 'DJ Dee' };
const tip: TipBegin = { tip_id: ID, amount_cents: 500, currency: 'cad', creator_name: 'DJ Dee' };

beforeEach(() => {
  vi.spyOn(console, 'error').mockImplementation(() => {});
});

describe('reading what the app sent', () => {
  it('an id is read in either case, with the sentence given', () => {
    expect(parseUuid({ profile_id: ID.toUpperCase() }, 'profile_id', 'Choose a profile.')).toEqual({ ok: true, id: ID });
    expect(parseUuid({}, 'profile_id', 'Choose a profile.')).toEqual({ ok: false, error: 'Choose a profile.' });
    expect(parseUuid({ profile_id: 'x' }, 'profile_id', 'Choose a profile.')).toEqual({ ok: false, error: 'Choose a profile.' });
    expect(parseUuid({ other: ID }, 'profile_id', 'Choose a profile.')).toEqual({ ok: false, error: 'Choose a profile.' });
    expect(parseUuid(null, 'profile_id', 'Choose a profile.')).toEqual({ ok: false, error: 'Choose a profile.' });
    expect(parseUuid('x', 'profile_id', 'Choose a profile.')).toEqual({ ok: false, error: 'Choose a profile.' });
  });

  it('a plan is monthly or yearly', () => {
    expect(parsePlan({ plan: 'monthly' })).toBe('monthly');
    expect(parsePlan({ plan: 'yearly' })).toBe('yearly');
    expect(parsePlan({ plan: 'weekly' })).toBeNull();
    expect(parsePlan({})).toBeNull();
    expect(parsePlan(null)).toBeNull();
  });

  it('an amount is a whole number of cents', () => {
    expect(parseCents({ amount_cents: 500 }, 'amount_cents')).toBe(500);
    expect(parseCents({ amount_cents: 1 }, 'amount_cents')).toBe(1);
    expect(parseCents({ amount_cents: 100000000 }, 'amount_cents')).toBe(100000000);
    for (const bad of [0, -5, 5.5, 100000001, '500', null, undefined, NaN]) expect(parseCents({ amount_cents: bad }, 'amount_cents')).toBeNull();
    expect(parseCents(null, 'amount_cents')).toBeNull();
  });

  it('a note is trimmed and cut at 200 characters, and nothing is nothing', () => {
    expect(parseNote({ message: '  Great set  ' })).toBe('Great set');
    expect(parseNote({ message: 'x'.repeat(300) })).toBe('x'.repeat(200));
    expect(parseNote({ message: '   ' })).toBeNull();
    expect(parseNote({ message: 5 })).toBeNull();
    expect(parseNote({})).toBeNull();
    expect(parseNote(null)).toBeNull();
  });
});

describe('what Stripe is asked for: a subscription', () => {
  it('is named for the plan and the profile', () => {
    expect(subscriptionName(sub)).toBe('BottlesUp monthly subscription for DJ Dee');
    expect(subscriptionName({ ...sub, plan: 'yearly' })).toBe('BottlesUp yearly subscription for DJ Dee');
    expect(subscriptionName({ ...sub, profile_name: null })).toBe('BottlesUp monthly subscription for your profile');
    expect(subscriptionName({ ...sub, profile_name: '  DJ\n\tDee\u0007 ' })).toBe('BottlesUp monthly subscription for DJ Dee');
  });

  it('is one recurring line at the amount the database named, with the subscription\'s id on the session and on the subscription', () => {
    const p = subscriptionSessionParams(sub, 'dee@x.example', 'https://www.bottlesupapp.com') as any;
    expect(p.mode).toBe('subscription');
    expect(p.customer_email).toBe('dee@x.example');
    expect(p.customer).toBeUndefined();
    expect(p.line_items).toEqual([{ price_data: { currency: 'cad', product_data: { name: subscriptionName(sub) }, unit_amount: 2999, recurring: { interval: 'month' } }, quantity: 1 }]);
    expect(p.metadata).toEqual({ kind: 'subscription', subscription_id: ID });
    expect(p.subscription_data.metadata).toEqual({ kind: 'subscription', subscription_id: ID });
    expect(p.success_url).toBe('https://www.bottlesupapp.com/pay/subscription-thanks?session_id={CHECKOUT_SESSION_ID}');
    expect(p.cancel_url).toBe('https://www.bottlesupapp.com/pay/subscription-thanks?cancelled=1');
  });

  it('a yearly plan renews every year', () => {
    const p = subscriptionSessionParams({ ...sub, plan: 'yearly', amount_cents: 29900 }, 'dee@x.example', 'https://s.test') as any;
    expect(p.line_items[0].price_data.recurring).toEqual({ interval: 'year' });
    expect(p.line_items[0].price_data.unit_amount).toBe(29900);
  });

  it('a Stripe price from the CMS is used as it is, and a customer Stripe already knows is reused instead of an e-mail', () => {
    const p = subscriptionSessionParams({ ...sub, price: 'price_123', customer: 'cus_9' }, 'dee@x.example', 'https://s.test') as any;
    expect(p.line_items).toEqual([{ price: 'price_123', quantity: 1 }]);
    expect(p.customer).toBe('cus_9');
    expect(p.customer_email).toBeUndefined();
  });
});

describe('what Stripe is asked for: a tip', () => {
  it('is named for the creator', () => {
    expect(tipName(tip)).toBe('Tip for DJ Dee');
    expect(tipName({ creator_name: null })).toBe('Tip for a creator');
  });

  it('is one line for exactly the amount, with the tip in the metadata and a page that lapses in 31 minutes', () => {
    const now = 1_800_000_000_000;
    const p = tipSessionParams(tip, 'cy@x.example', 'https://s.test', now) as any;
    expect(p.mode).toBe('payment');
    expect(p.customer_email).toBe('cy@x.example');
    expect(p.line_items).toEqual([{ price_data: { currency: 'cad', product_data: { name: 'Tip for DJ Dee' }, unit_amount: 500 }, quantity: 1 }]);
    expect(p.adaptive_pricing).toEqual({ enabled: false });
    expect(p.metadata).toEqual({ kind: 'tip', tip_id: ID });
    expect(p.payment_intent_data.metadata).toEqual({ kind: 'tip', tip_id: ID });
    expect(p.expires_at).toBe(Math.floor(now / 1000) + TIP_SESSION_MINUTES * 60);
    expect(TIP_SESSION_MINUTES).toBe(31);
    expect(p.success_url).toBe('https://s.test/pay/tip-thanks?session_id={CHECKOUT_SESSION_ID}');
    expect(p.cancel_url).toBe('https://s.test/pay/tip-thanks?cancelled=1');
  });
});

function db(answers: Record<string, { data?: unknown; error?: { message: string; code?: string } | null }>) {
  const calls: [string, Record<string, unknown>][] = [];
  const client: DbLike = {
    rpc: (name, args) => {
      calls.push([name, args ?? {}]);
      const a = answers[name] ?? { data: null, error: null };
      return Promise.resolve({ data: a.data ?? null, error: a.error ?? null });
    },
  };
  return { client, calls };
}

describe('writing what Stripe says about a subscription', () => {
  const stripeSub = { id: 'sub_1', status: 'active', customer: 'cus_1', current_period_end: 1_800_000_000, cancel_at_period_end: false, metadata: { subscription_id: ID } };

  it('passes the id, the customer, the status, the end of the period, the cancel flag and our id', async () => {
    const d = db({ sub_apply: { data: { result: 'applied' } } });
    expect(await applySubscription(d.client, stripeSub)).toEqual({ result: 'applied' });
    expect(d.calls).toEqual([['sub_apply', { p_stripe_subscription: 'sub_1', p_customer: 'cus_1', p_status: 'active', p_period_end: new Date(1_800_000_000 * 1000).toISOString(), p_cancel_at_end: false, p_sub: ID }]]);
  });

  it('reads a customer that is an object, no end of period as nothing, a cancel at the end as true, and falls back to the id it was given', async () => {
    const d = db({ sub_apply: { data: { result: 'applied' } } });
    await applySubscription(d.client, { id: 'sub_2', status: 'past_due', customer: { id: 'cus_obj' }, cancel_at_period_end: true, metadata: null }, 'fallback-id');
    const args = d.calls[0][1];
    expect([args.p_customer, args.p_period_end, args.p_cancel_at_end, args.p_sub]).toEqual(['cus_obj', null, true, 'fallback-id']);
    await applySubscription(d.client, { id: 'sub_3', status: 'active' });
    const bare = d.calls[1][1];
    expect([bare.p_customer, bare.p_cancel_at_end, bare.p_sub]).toEqual([null, false, null]);
  });

  it('the id on the subscription wins over the fallback', async () => {
    const d = db({ sub_apply: { data: { result: 'applied' } } });
    await applySubscription(d.client, stripeSub, 'fallback-id');
    expect(d.calls[0][1].p_sub).toBe(ID);
  });

  it('says error when the database refuses, and says what it answered otherwise', async () => {
    expect(await applySubscription(db({ sub_apply: { error: { message: 'boom' } } }).client, stripeSub)).toEqual({ result: 'error' });
    expect(await applySubscription(db({ sub_apply: { data: { result: 'unknown' } } }).client, stripeSub)).toEqual({ result: 'unknown' });
    expect(await applySubscription(db({ sub_apply: { data: {} } }).client, stripeSub)).toEqual({ result: 'error' });
    expect(console.error).toHaveBeenCalled();
  });

  it('a completed page asks Stripe for the subscription it made and writes it, with our id from the session', async () => {
    const d = db({ sub_apply: { data: { result: 'applied' } } });
    const retrieve = vi.fn(async () => ({ ...stripeSub, metadata: null }));
    expect(await fulfillSubscriptionCheckout(d.client, { subscriptions: { retrieve } }, { id: 'cs_1', subscription: 'sub_1', metadata: { subscription_id: ID } })).toEqual({ result: 'applied' });
    expect(retrieve).toHaveBeenCalledWith('sub_1');
    expect(d.calls[0][1].p_sub).toBe(ID);
  });

  it('reads a subscription that is an object, and stops when the page has none or Stripe will not give it', async () => {
    const d = db({ sub_apply: { data: { result: 'applied' } } });
    const retrieve = vi.fn(async () => stripeSub);
    await fulfillSubscriptionCheckout(d.client, { subscriptions: { retrieve } }, { id: 'cs_1', subscription: { id: 'sub_obj' } });
    expect(retrieve).toHaveBeenCalledWith('sub_obj');
    expect(await fulfillSubscriptionCheckout(d.client, { subscriptions: { retrieve } }, { id: 'cs_2', subscription: null })).toEqual({ result: 'error' });
    const failing = vi.fn(async () => { throw Object.assign(new Error('no'), { code: 'resource_missing' }); });
    expect(await fulfillSubscriptionCheckout(d.client, { subscriptions: { retrieve: failing } }, { id: 'cs_3', subscription: 'sub_x' })).toEqual({ result: 'error' });
    expect(d.calls.length).toBe(1);
  });
});

describe('writing a tip that was paid', () => {
  it('passes the session, the payment and the amount, and says what the database answered', async () => {
    const d = db({ tip_paid: { data: { result: 'applied' } } });
    expect(await fulfillTip(d.client, 'cs_tip', 'pi_tip', 500)).toEqual({ result: 'applied' });
    expect(d.calls).toEqual([['tip_paid', { p_session: 'cs_tip', p_payment_intent: 'pi_tip', p_amount: 500 }]]);
    expect((await fulfillTip(db({ tip_paid: { data: { result: 'already' } } }).client, 'cs', null, 500)).result).toBe('already');
  });

  it('says error when the database refuses or answers nothing, and logs a tip it does not know', async () => {
    expect(await fulfillTip(db({ tip_paid: { error: { message: 'boom' } } }).client, 'cs', null, 500)).toEqual({ result: 'error' });
    expect(await fulfillTip(db({ tip_paid: { data: {} } }).client, 'cs', null, 500)).toEqual({ result: 'error' });
    expect((await fulfillTip(db({ tip_paid: { data: { result: 'unknown' } } }).client, 'cs', null, 500)).result).toBe('unknown');
    expect(console.error).toHaveBeenCalledTimes(2);
  });
});
