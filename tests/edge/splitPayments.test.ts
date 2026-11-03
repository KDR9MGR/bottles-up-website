import { beforeEach, describe, expect, it, vi } from 'vitest';
import {
  SESSION_MINUTES,
  fulfillSplitShare,
  parseId,
  pickStripeKey,
  productName,
  refundDueShares,
  refusalSentence,
  sessionParams,
  type BeginResult,
  type DbLike,
  type StripeLike,
} from '../../supabase/functions/_shared/splitPayments.ts';

const ID = '3f2b8c1e-5a4d-4e7a-9b1c-0d6e8f7a2b3c';
const begin: BeginResult = { id: ID, amount_cents: 2500, currency: 'cad', booking_id: 'bk', venue: 'Split Club', booking_date: '2026-11-07', start_time: '22:00', host: 'Ann', pending_session: null };

beforeEach(() => {
  vi.spyOn(console, 'error').mockImplementation(() => {});
});

describe('reading a request', () => {
  it('takes a uuid, in any case, and gives it back lower case', () => {
    expect(parseId({ share_id: ID.toUpperCase() }, 'share_id')).toEqual({ ok: true, id: ID });
    expect(parseId({ split_id: ID }, 'split_id')).toEqual({ ok: true, id: ID });
  });

  it('refuses anything else with a sentence for the person', () => {
    for (const body of [null, undefined, 'x', 5, [], {}, { share_id: 5 }, { share_id: '' }, { share_id: 'not-a-uuid' }, { share_id: ID + 'x' }, { split_id: ID }]) {
      const r = parseId(body, 'share_id');
      expect(r).toEqual({ ok: false, error: 'Choose a request to pay.' });
    }
    expect(parseId({}, 'split_id')).toEqual({ ok: false, error: 'Choose a split.' });
    expect(parseId({ share_id: ID }, 'split_id')).toEqual({ ok: false, error: 'Choose a split.' });
  });
});

describe('which Stripe key', () => {
  const env = (m: Record<string, string>) => (k: string) => m[k];
  it('live mode uses the live key, then the general one', () => {
    expect(pickStripeKey('live', env({ STRIPE_SECRET_KEY_LIVE: 'L', STRIPE_SECRET_KEY: 'G', STRIPE_SECRET_KEY_TEST: 'T' }))).toBe('L');
    expect(pickStripeKey('live', env({ STRIPE_SECRET_KEY: 'G', STRIPE_SECRET_KEY_TEST: 'T' }))).toBe('G');
  });
  it('anything else is test mode: the test key, the old test name, then the general one — never the live key', () => {
    expect(pickStripeKey('test', env({ STRIPE_SECRET_KEY_LIVE: 'L', STRIPE_SECRET_KEY_TEST: 'T', test_SK: 'O', STRIPE_SECRET_KEY: 'G' }))).toBe('T');
    expect(pickStripeKey(null, env({ STRIPE_SECRET_KEY_LIVE: 'L', test_SK: 'O', STRIPE_SECRET_KEY: 'G' }))).toBe('O');
    expect(pickStripeKey(undefined, env({ STRIPE_SECRET_KEY_LIVE: 'L', STRIPE_SECRET_KEY: 'G' }))).toBe('G');
    expect(pickStripeKey('LIVE', env({ STRIPE_SECRET_KEY_LIVE: 'L' }))).toBeUndefined();
    expect(pickStripeKey('test', env({}))).toBeUndefined();
  });
});

describe('what Stripe is asked for', () => {
  it('names the charge after the venue and the night, and strips what should not be on a receipt', () => {
    expect(productName(begin)).toBe('Your share of the table at Split Club (2026-11-07)');
    expect(productName({ ...begin, booking_date: null })).toBe('Your share of the table at Split Club');
    expect(productName({ ...begin, venue: null })).toBe('Your share of the table at a table (2026-11-07)');
    expect(productName({ ...begin, venue: '  Split\n\tClub\u0007  ' })).toBe('Your share of the table at Split Club (2026-11-07)');
    expect(productName({ ...begin, venue: 'x'.repeat(200) }).length).toBeLessThan(120);
  });

  it('is one line for exactly the share, in the booking\'s currency, with the share in the metadata and a page that lapses in 31 minutes', () => {
    const now = 1_800_000_000_000;
    const p = sessionParams(begin, 'bob@x.example', 'https://www.bottlesupapp.com', now) as any;
    expect(p.mode).toBe('payment');
    expect(p.customer_email).toBe('bob@x.example');
    expect(p.line_items).toEqual([{ price_data: { currency: 'cad', product_data: { name: productName(begin) }, unit_amount: 2500 }, quantity: 1 }]);
    expect(p.metadata).toEqual({ kind: 'split_share', share_id: ID });
    expect(p.payment_intent_data.metadata).toEqual({ kind: 'split_share', share_id: ID });
    expect(p.adaptive_pricing).toEqual({ enabled: false });
    expect(SESSION_MINUTES).toBe(31);
    expect(p.expires_at).toBe(1_800_000_000 + 31 * 60);
    expect(p.success_url).toBe('https://www.bottlesupapp.com/pay/share-thanks?session_id={CHECKOUT_SESSION_ID}');
    expect(p.cancel_url).toBe('https://www.bottlesupapp.com/pay/share-thanks?cancelled=1');
  });

  it('never carries the booking or an order in its metadata, so the webhook cannot mistake it for one', () => {
    const p = sessionParams(begin, 'bob@x.example', 'https://x.test', 0) as any;
    expect(Object.keys(p.metadata).sort()).toEqual(['kind', 'share_id']);
  });
});

describe('the sentence a refusal carries', () => {
  it('only the database\'s own plain sentences are shown', () => {
    expect(refusalSentence({ code: 'P0001', message: 'You already paid this.' })).toBe('You already paid this.');
    expect(refusalSentence({ code: 'P0001', message: '  padded  ' })).toBe('padded');
  });
  it('anything else is not shown', () => {
    expect(refusalSentence({ code: '42501', message: 'permission denied for function x' })).toBeNull();
    expect(refusalSentence({ code: 'P0001', message: '' })).toBeNull();
    expect(refusalSentence({ code: 'P0001', message: 'x'.repeat(301) })).toBeNull();
    expect(refusalSentence({ message: 'no code' })).toBeNull();
    expect(refusalSentence(null)).toBeNull();
    expect(refusalSentence(undefined)).toBeNull();
  });
});

type Call = [string, Record<string, unknown> | undefined];
function fakeDb(answers: Record<string, { data?: unknown; error?: { message: string; code?: string } | null } | ((args: any) => any)>) {
  const calls: Call[] = [];
  const db: DbLike = {
    rpc: async (name, args) => {
      calls.push([name, args]);
      const a = answers[name];
      const r = typeof a === 'function' ? a(args) : a;
      return { data: r?.data ?? null, error: r?.error ?? null };
    },
  };
  return { db, calls };
}
function fakeStripe(behaviour: (params: any, options: any) => Promise<{ id: string }> | { id: string }) {
  const created: { params: any; options: any }[] = [];
  const stripe: StripeLike = {
    checkout: { sessions: { create: async () => ({ id: 'x', url: null }), retrieve: async () => ({ id: 'x' }) } },
    refunds: { create: async (params, options) => { created.push({ params, options }); return behaviour(params, options); } },
  };
  return { stripe, created };
}

describe('recording a payment', () => {
  it('tells the database the session, the payment and the amount, and answers what it said', async () => {
    const { db, calls } = fakeDb({ split_share_paid: { data: { result: 'applied', applied_cents: 2500, refund_cents: 0 } } });
    const { stripe, created } = fakeStripe(() => ({ id: 're_1' }));
    expect(await fulfillSplitShare(db, stripe, 'cs_1', 'pi_1', 2500)).toEqual({ result: 'applied', refundCents: 0 });
    expect(calls).toEqual([['split_share_paid', { p_session: 'cs_1', p_payment_intent: 'pi_1', p_amount: 2500 }]]);
    expect(created).toHaveLength(0);
  });

  it('pays back at once what could not be applied (and only then)', async () => {
    const { db, calls } = fakeDb({
      split_share_paid: { data: { result: 'refund', applied_cents: 0, refund_cents: 2500 } },
      split_refunds_due: { data: [{ share_id: 'sh1', split_id: 'sp1', stripe_payment_intent_id: 'pi_1', cents: 2500 }] },
      split_share_refunded: { data: { result: 'refunded' } },
    });
    const { stripe, created } = fakeStripe(() => ({ id: 're_1' }));
    expect(await fulfillSplitShare(db, stripe, 'cs_1', 'pi_1', 2500)).toEqual({ result: 'refund', refundCents: 2500 });
    expect(calls.map((c) => c[0])).toEqual(['split_share_paid', 'split_refunds_due', 'split_share_refunded']);
    expect(created).toHaveLength(1);
  });

  it('without a Stripe client the refund waits for the next run, and nothing breaks', async () => {
    const { db, calls } = fakeDb({ split_share_paid: { data: { result: 'refund', refund_cents: 100 } } });
    expect(await fulfillSplitShare(db, null, 'cs_1', null, 100)).toEqual({ result: 'refund', refundCents: 100 });
    expect(calls.map((c) => c[0])).toEqual(['split_share_paid']);
  });

  it('a payment seen twice is not paid back or recorded twice', async () => {
    const { db, calls } = fakeDb({ split_share_paid: { data: { result: 'already', applied_cents: 2500, refund_cents: 0 } } });
    const { stripe } = fakeStripe(() => ({ id: 're_1' }));
    expect(await fulfillSplitShare(db, stripe, 'cs_1', 'pi_1', 2500)).toEqual({ result: 'already', refundCents: 0 });
    expect(calls).toHaveLength(1);
  });

  it('a session no share has is reported, not guessed at', async () => {
    const { db } = fakeDb({ split_share_paid: { data: { result: 'unknown' } } });
    const { stripe } = fakeStripe(() => ({ id: 're_1' }));
    expect(await fulfillSplitShare(db, stripe, 'cs_x', null, 100)).toEqual({ result: 'unknown', refundCents: 0 });
    expect(console.error).toHaveBeenCalled();
  });

  it('a database error is an error result, with no refund and nothing said about why', async () => {
    const { db, calls } = fakeDb({ split_share_paid: { error: { message: 'secret internals' } } });
    const { stripe, created } = fakeStripe(() => ({ id: 're_1' }));
    expect(await fulfillSplitShare(db, stripe, 'cs_1', 'pi_1', 100)).toEqual({ result: 'error', refundCents: 0 });
    expect(calls).toHaveLength(1);
    expect(created).toHaveLength(0);
  });

  it('an answer with no body is an error result too', async () => {
    const { db } = fakeDb({ split_share_paid: { data: null } });
    expect(await fulfillSplitShare(db, null, 'cs_1', null, 100)).toEqual({ result: 'error', refundCents: 0 });
  });
});

describe('paying back', () => {
  const rows = [
    { share_id: 'sh1', split_id: 'sp1', stripe_payment_intent_id: 'pi_1', cents: 5000 },
    { share_id: 'sh2', split_id: 'sp2', stripe_payment_intent_id: 'pi_2', cents: 2000 },
    { share_id: 'sh3', split_id: 'sp1', stripe_payment_intent_id: 'pi_3', cents: 700 },
  ];

  it('refunds each share once, with a key that makes a repeat the same refund, and records Stripe\'s refund id', async () => {
    const { db, calls } = fakeDb({ split_refunds_due: { data: rows }, split_share_refunded: { data: { result: 'refunded' } } });
    let n = 0;
    const { stripe, created } = fakeStripe(() => ({ id: `re_${++n}` }));
    expect(await refundDueShares(db, stripe, {})).toEqual({ refunded: 3, failed: 0 });
    expect(created.map((c) => [c.params.payment_intent, c.params.amount, c.options.idempotencyKey])).toEqual([
      ['pi_1', 5000, 'split-share-sh1-5000'],
      ['pi_2', 2000, 'split-share-sh2-2000'],
      ['pi_3', 700, 'split-share-sh3-700'],
    ]);
    expect(created[0].params.metadata).toEqual({ kind: 'split_share', share_id: 'sh1' });
    expect(calls.filter((c) => c[0] === 'split_share_refunded').map((c) => c[1])).toEqual([
      { p_share: 'sh1', p_refund_id: 're_1', p_cents: 5000 },
      { p_share: 'sh2', p_refund_id: 're_2', p_cents: 2000 },
      { p_share: 'sh3', p_refund_id: 're_3', p_cents: 700 },
    ]);
  });

  it('only one split\'s when asked', async () => {
    const { db } = fakeDb({ split_refunds_due: { data: rows }, split_share_refunded: { data: {} } });
    const { stripe, created } = fakeStripe(() => ({ id: 're_x' }));
    expect(await refundDueShares(db, stripe, { splitId: 'sp1' })).toEqual({ refunded: 2, failed: 0 });
    expect(created.map((c) => c.params.payment_intent)).toEqual(['pi_1', 'pi_3']);
  });

  it('skips rows it cannot make sense of', async () => {
    const bad = [
      { share_id: '', split_id: 'sp', stripe_payment_intent_id: 'pi', cents: 100 },
      { share_id: 'a', split_id: 'sp', stripe_payment_intent_id: '', cents: 100 },
      { share_id: 'b', split_id: 'sp', stripe_payment_intent_id: 'pi', cents: 0 },
      { share_id: 'c', split_id: 'sp', stripe_payment_intent_id: 'pi', cents: -5 },
      { share_id: 'd', split_id: 'sp', stripe_payment_intent_id: 'pi', cents: 10.5 },
    ];
    const { db } = fakeDb({ split_refunds_due: { data: bad } });
    const { stripe, created } = fakeStripe(() => ({ id: 're_x' }));
    expect(await refundDueShares(db, stripe, {})).toEqual({ refunded: 0, failed: 0 });
    expect(created).toHaveLength(0);
  });

  it('a refund Stripe refuses is counted and the others go on; it is tried again next run', async () => {
    const { db, calls } = fakeDb({ split_refunds_due: { data: rows }, split_share_refunded: { data: {} } });
    const { stripe } = fakeStripe((params) => {
      if (params.payment_intent === 'pi_2') throw Object.assign(new Error('boom'), { code: 'charge_already_refunded' });
      return { id: 're_ok' };
    });
    expect(await refundDueShares(db, stripe, {})).toEqual({ refunded: 2, failed: 1 });
    expect(calls.filter((c) => c[0] === 'split_share_refunded')).toHaveLength(2);
  });

  it('a refund Stripe made that the database could not record is counted as failed', async () => {
    const { db } = fakeDb({ split_refunds_due: { data: [rows[0]] }, split_share_refunded: { error: { message: 'x' } } });
    const { stripe } = fakeStripe(() => ({ id: 're_1' }));
    expect(await refundDueShares(db, stripe, {})).toEqual({ refunded: 0, failed: 1 });
  });

  it('nothing due, or a database that cannot be asked, is nothing done', async () => {
    const { stripe, created } = fakeStripe(() => ({ id: 're_x' }));
    expect(await refundDueShares(fakeDb({ split_refunds_due: { data: [] } }).db, stripe, {})).toEqual({ refunded: 0, failed: 0 });
    expect(await refundDueShares(fakeDb({ split_refunds_due: { data: null } }).db, stripe, {})).toEqual({ refunded: 0, failed: 0 });
    expect(await refundDueShares(fakeDb({ split_refunds_due: { error: { message: 'down' } } }).db, stripe, {})).toEqual({ refunded: 0, failed: 0 });
    expect(created).toHaveLength(0);
  });
});
