import { beforeEach, describe, expect, it, vi } from 'vitest';
import {
  PRO_SESSION_MINUTES,
  fulfillProPayment,
  proProductName,
  proSessionParams,
  refundDuePayments,
  type DbLike,
  type ProBegin,
  type StripeLike,
} from '../../supabase/functions/_shared/proPayments.ts';
import { parseId } from '../../supabase/functions/_shared/splitPayments.ts';

const ID = '3f2b8c1e-5a4d-4e7a-9b1c-0d6e8f7a2b3c';
const begin: ProBegin = { payment_id: ID, kind: 'deposit', amount_cents: 30000, currency: 'cad', title: 'Wedding DJ set', event_date: '2026-12-05', provider: 'DJ Dee', pending_session: null };

beforeEach(() => {
  vi.spyOn(console, 'error').mockImplementation(() => {});
});

describe('naming a booking', () => {
  it('a booking id is read like the others, with its own sentence', () => {
    expect(parseId({ booking_id: ID.toUpperCase() }, 'booking_id')).toEqual({ ok: true, id: ID });
    expect(parseId({}, 'booking_id')).toEqual({ ok: false, error: 'Choose a booking.' });
    expect(parseId({ booking_id: 'x' }, 'booking_id')).toEqual({ ok: false, error: 'Choose a booking.' });
    expect(parseId({ share_id: ID }, 'booking_id')).toEqual({ ok: false, error: 'Choose a booking.' });
  });
});

describe('what Stripe is asked for', () => {
  it('names the charge for what it is', () => {
    expect(proProductName(begin)).toBe('Deposit for Wedding DJ set (2026-12-05)');
    expect(proProductName({ ...begin, kind: 'balance' })).toBe('Balance for Wedding DJ set (2026-12-05)');
    expect(proProductName({ ...begin, kind: 'full' })).toBe('Payment for Wedding DJ set (2026-12-05)');
    expect(proProductName({ ...begin, event_date: null })).toBe('Deposit for Wedding DJ set');
    expect(proProductName({ ...begin, title: null })).toBe('Deposit for DJ Dee (2026-12-05)');
    expect(proProductName({ ...begin, title: null, provider: null })).toBe('Deposit for a booking (2026-12-05)');
    expect(proProductName({ ...begin, title: '  Wedding\n\tDJ\u0007  set ' })).toBe('Deposit for Wedding DJ set (2026-12-05)');
    expect(proProductName({ ...begin, title: 'x'.repeat(200) }).length).toBeLessThan(110);
  });

  it('is one line for exactly the amount the database asked for, with the payment in the metadata and a page that lapses in 31 minutes', () => {
    const now = 1_800_000_000_000;
    const p = proSessionParams(begin, 'ann@x.example', 'https://www.bottlesupapp.com', now) as any;
    expect(p.mode).toBe('payment');
    expect(p.customer_email).toBe('ann@x.example');
    expect(p.line_items).toEqual([{ price_data: { currency: 'cad', product_data: { name: proProductName(begin) }, unit_amount: 30000 }, quantity: 1 }]);
    expect(p.metadata).toEqual({ kind: 'pro_payment', payment_id: ID });
    expect(p.payment_intent_data.metadata).toEqual({ kind: 'pro_payment', payment_id: ID });
    expect(p.adaptive_pricing).toEqual({ enabled: false });
    expect(PRO_SESSION_MINUTES).toBe(31);
    expect(p.expires_at).toBe(1_800_000_000 + 31 * 60);
    expect(p.success_url).toBe('https://www.bottlesupapp.com/pay/booking-thanks?session_id={CHECKOUT_SESSION_ID}');
    expect(p.cancel_url).toBe('https://www.bottlesupapp.com/pay/booking-thanks?cancelled=1');
  });

  it('never carries a booking or an order in its metadata, so the webhook cannot mistake it for one', () => {
    const p = proSessionParams(begin, 'ann@x.example', 'https://x.test', 0) as any;
    expect(Object.keys(p.metadata).sort()).toEqual(['kind', 'payment_id']);
  });
});

type Call = [string, Record<string, unknown> | undefined];
function fakeDb(answers: Record<string, { data?: unknown; error?: { message: string; code?: string } | null }>) {
  const calls: Call[] = [];
  const db: DbLike = {
    rpc: async (name, args) => {
      calls.push([name, args]);
      const a = answers[name];
      return { data: a?.data ?? null, error: a?.error ?? null };
    },
  };
  return { db, calls };
}
function fakeStripe(behaviour: (params: any) => { id: string }) {
  const created: { params: any; options: any }[] = [];
  const stripe: StripeLike = {
    checkout: { sessions: { create: async () => ({ id: 'x', url: null }), retrieve: async () => ({ id: 'x' }) } },
    refunds: { create: async (params, options) => { created.push({ params, options }); return behaviour(params); } },
  };
  return { stripe, created };
}

describe('recording a payment', () => {
  it('tells the database the session, the payment and the amount', async () => {
    const { db, calls } = fakeDb({ pro_payment_paid: { data: { result: 'applied', applied_cents: 30000, refund_cents: 0 } } });
    const { stripe, created } = fakeStripe(() => ({ id: 're_1' }));
    expect(await fulfillProPayment(db, stripe, 'cs_1', 'pi_1', 30000)).toEqual({ result: 'applied', refundCents: 0 });
    expect(calls).toEqual([['pro_payment_paid', { p_session: 'cs_1', p_payment_intent: 'pi_1', p_amount: 30000 }]]);
    expect(created).toHaveLength(0);
  });

  it('pays back at once what could not be used', async () => {
    const { db, calls } = fakeDb({
      pro_payment_paid: { data: { result: 'refund', applied_cents: 0, refund_cents: 30000 } },
      pro_refunds_due: { data: [{ payment_id: 'p1', booking_id: 'b1', stripe_payment_intent_id: 'pi_1', cents: 30000 }] },
      pro_payment_refunded: { data: { result: 'refunded' } },
    });
    const { stripe, created } = fakeStripe(() => ({ id: 're_1' }));
    expect(await fulfillProPayment(db, stripe, 'cs_1', 'pi_1', 30000)).toEqual({ result: 'refund', refundCents: 30000 });
    expect(calls.map((c) => c[0])).toEqual(['pro_payment_paid', 'pro_refunds_due', 'pro_payment_refunded']);
    expect(created).toHaveLength(1);
  });

  it('without a Stripe client the refund waits for the next run', async () => {
    const { db, calls } = fakeDb({ pro_payment_paid: { data: { result: 'refund', refund_cents: 100 } } });
    expect(await fulfillProPayment(db, null, 'cs_1', null, 100)).toEqual({ result: 'refund', refundCents: 100 });
    expect(calls.map((c) => c[0])).toEqual(['pro_payment_paid']);
  });

  it('a payment seen twice is neither paid back nor recorded twice', async () => {
    const { db, calls } = fakeDb({ pro_payment_paid: { data: { result: 'already', applied_cents: 30000, refund_cents: 0 } } });
    const { stripe } = fakeStripe(() => ({ id: 're_1' }));
    expect(await fulfillProPayment(db, stripe, 'cs_1', 'pi_1', 30000)).toEqual({ result: 'already', refundCents: 0 });
    expect(calls).toHaveLength(1);
  });

  it('a session no payment has is reported, a database error is an error result, and an empty answer too', async () => {
    const { stripe } = fakeStripe(() => ({ id: 're_1' }));
    expect(await fulfillProPayment(fakeDb({ pro_payment_paid: { data: { result: 'unknown' } } }).db, stripe, 'cs_x', null, 100)).toEqual({ result: 'unknown', refundCents: 0 });
    expect(console.error).toHaveBeenCalled();
    expect(await fulfillProPayment(fakeDb({ pro_payment_paid: { error: { message: 'secret internals' } } }).db, stripe, 'cs_1', null, 100)).toEqual({ result: 'error', refundCents: 0 });
    expect(await fulfillProPayment(fakeDb({ pro_payment_paid: { data: null } }).db, null, 'cs_1', null, 100)).toEqual({ result: 'error', refundCents: 0 });
  });
});

describe('paying back', () => {
  const rows = [
    { payment_id: 'p1', booking_id: 'b1', stripe_payment_intent_id: 'pi_1', cents: 70000 },
    { payment_id: 'p2', booking_id: 'b2', stripe_payment_intent_id: 'pi_2', cents: 2000 },
    { payment_id: 'p3', booking_id: 'b1', stripe_payment_intent_id: 'pi_3', cents: 30000 },
  ];

  it('refunds each payment once, with a key that makes a repeat the same refund, and records Stripe\'s refund id', async () => {
    const { db, calls } = fakeDb({ pro_refunds_due: { data: rows }, pro_payment_refunded: { data: { result: 'refunded' } } });
    let n = 0;
    const { stripe, created } = fakeStripe(() => ({ id: `re_${++n}` }));
    expect(await refundDuePayments(db, stripe, {})).toEqual({ refunded: 3, failed: 0 });
    expect(created.map((c) => [c.params.payment_intent, c.params.amount, c.options.idempotencyKey])).toEqual([
      ['pi_1', 70000, 'pro-payment-p1-70000'],
      ['pi_2', 2000, 'pro-payment-p2-2000'],
      ['pi_3', 30000, 'pro-payment-p3-30000'],
    ]);
    expect(created[0].params.metadata).toEqual({ kind: 'pro_payment', payment_id: 'p1' });
    expect(calls.filter((c) => c[0] === 'pro_payment_refunded').map((c) => c[1])).toEqual([
      { p_payment: 'p1', p_refund_id: 're_1', p_cents: 70000 },
      { p_payment: 'p2', p_refund_id: 're_2', p_cents: 2000 },
      { p_payment: 'p3', p_refund_id: 're_3', p_cents: 30000 },
    ]);
  });

  it('only one booking\'s when asked', async () => {
    const { db } = fakeDb({ pro_refunds_due: { data: rows }, pro_payment_refunded: { data: {} } });
    const { stripe, created } = fakeStripe(() => ({ id: 're_x' }));
    expect(await refundDuePayments(db, stripe, { bookingId: 'b1' })).toEqual({ refunded: 2, failed: 0 });
    expect(created.map((c) => c.params.payment_intent)).toEqual(['pi_1', 'pi_3']);
  });

  it('skips rows it cannot make sense of', async () => {
    const bad = [
      { payment_id: '', booking_id: 'b', stripe_payment_intent_id: 'pi', cents: 100 },
      { payment_id: 'a', booking_id: 'b', stripe_payment_intent_id: '', cents: 100 },
      { payment_id: 'b', booking_id: 'b', stripe_payment_intent_id: 'pi', cents: 0 },
      { payment_id: 'c', booking_id: 'b', stripe_payment_intent_id: 'pi', cents: -5 },
      { payment_id: 'd', booking_id: 'b', stripe_payment_intent_id: 'pi', cents: 10.5 },
    ];
    const { db } = fakeDb({ pro_refunds_due: { data: bad } });
    const { stripe, created } = fakeStripe(() => ({ id: 're_x' }));
    expect(await refundDuePayments(db, stripe, {})).toEqual({ refunded: 0, failed: 0 });
    expect(created).toHaveLength(0);
  });

  it('a refund Stripe refuses is counted and the others go on', async () => {
    const { db, calls } = fakeDb({ pro_refunds_due: { data: rows }, pro_payment_refunded: { data: {} } });
    const { stripe } = fakeStripe((params) => {
      if (params.payment_intent === 'pi_2') throw Object.assign(new Error('boom'), { code: 'charge_already_refunded' });
      return { id: 're_ok' };
    });
    expect(await refundDuePayments(db, stripe, {})).toEqual({ refunded: 2, failed: 1 });
    expect(calls.filter((c) => c[0] === 'pro_payment_refunded')).toHaveLength(2);
  });

  it('a refund Stripe made that the database could not record is counted as failed', async () => {
    const { db } = fakeDb({ pro_refunds_due: { data: [rows[0]] }, pro_payment_refunded: { error: { message: 'x' } } });
    const { stripe } = fakeStripe(() => ({ id: 're_1' }));
    expect(await refundDuePayments(db, stripe, {})).toEqual({ refunded: 0, failed: 1 });
  });

  it('nothing due, or a database that cannot be asked, is nothing done', async () => {
    const { stripe, created } = fakeStripe(() => ({ id: 're_x' }));
    expect(await refundDuePayments(fakeDb({ pro_refunds_due: { data: [] } }).db, stripe, {})).toEqual({ refunded: 0, failed: 0 });
    expect(await refundDuePayments(fakeDb({ pro_refunds_due: { data: null } }).db, stripe, {})).toEqual({ refunded: 0, failed: 0 });
    expect(await refundDuePayments(fakeDb({ pro_refunds_due: { error: { message: 'down' } } }).db, stripe, {})).toEqual({ refunded: 0, failed: 0 });
    expect(created).toHaveLength(0);
  });
});
