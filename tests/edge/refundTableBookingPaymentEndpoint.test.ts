import { beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';

vi.mock('npm:@supabase/supabase-js@2', () => ({ createClient: vi.fn() }));
const stripeRefundsCreate = vi.fn();
vi.mock('npm:stripe@17', () => {
  class FakeStripe {
    static createFetchHttpClient() { return {}; }
    refunds = { create: stripeRefundsCreate };
    checkout = { sessions: { retrieve: vi.fn() } };
  }
  return { default: FakeStripe };
});
import { createClient } from 'npm:@supabase/supabase-js@2';
import { createFakeDb, type FakeDb } from './stubs/fakeDb.ts';

const BOOKING = 'b0000000-0000-0000-0000-000000000001';
const OTHER_BOOKING = 'b0000000-0000-0000-0000-000000000002';
const REQUEST = 'c0000000-0000-0000-0000-000000000001';
let env: Record<string, string | undefined> = {};
let handler: (req: Request) => Promise<Response>;
let db: FakeDb;
let claim: { data: any; error: any };

beforeAll(async () => {
  (globalThis as any).Deno = { serve: (h: (req: Request) => Promise<Response>) => { handler = h; }, env: { get: (k: string) => env[k] } };
  await import('../../supabase/functions/refund-table-booking-payment/index.ts');
});

function seed(opts: { admin?: boolean; intent?: string | null; paid?: number } = {}) {
  db = createFakeDb({
    cms_admins: opts.admin === false ? [] : [{ id: 'u1', email: 'admin@bottlesup.example' }],
    site_table_bookings: [{ id: BOOKING, amount_paid_cents: opts.paid ?? 10000, stripe_payment_intent_id: opts.intent === undefined ? 'pi_123' : opts.intent }],
    site_table_booking_bottles: [],
    site_table_booking_refunds: [],
    site_content: [{ id: 1, payments_mode: 'test' }],
    audit_log: [],
  });
  db.rpcHandlers = {
    refund_request_begin: () => claim.data,
    refund_request_finish: () => 'ok',
  };
  const baseRpc = db.client.rpc;
  db.client.rpc = (name: string, args: any) => {
    if (name === 'refund_request_begin') { db.rpcCalls.push({ name, args }); return Promise.resolve(claim); }
    return baseRpc(name, args);
  };
  (createClient as any).mockImplementation((_url: string, key: string) =>
    key === 'anon-key' ? { auth: { getUser: async () => ({ data: { user: { id: 'u1' } }, error: null }) } } : db.client);
}

beforeEach(() => {
  vi.clearAllMocks();
  vi.spyOn(console, 'error').mockImplementation(() => {});
  env = { SUPABASE_URL: 'http://db.test', SUPABASE_ANON_KEY: 'anon-key', SUPABASE_SERVICE_ROLE_KEY: 'service-key', STRIPE_SECRET_KEY_TEST: 'sk_test_x' };
  claim = { data: { request_id: REQUEST, booking_id: BOOKING, amount_cents: 4000, reason: 'Event cancelled by us' }, error: null };
  stripeRefundsCreate.mockResolvedValue({ id: 're_1' });
  seed();
});

const post = (body: unknown) =>
  handler(new Request('https://fn.test/refund', { method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: 'Bearer jwt' }, body: JSON.stringify(body) }));
const finishes = () => db.rpcCalls.filter((c) => c.name === 'refund_request_finish').map((c) => c.args);
const begins = () => db.rpcCalls.filter((c) => c.name === 'refund_request_begin');

describe('refund-table-booking-payment: an approved request', () => {
  it('is claimed once, returned with the REQUEST\'s amount (not the caller\'s) and the request id as the Stripe idempotency key, recorded, and finished as completed', async () => {
    const res = await post({ booking_id: BOOKING, refund_type: 'online', request_id: REQUEST, amount_cents: 99999, reason: 'something else' });
    expect(res.status).toBe(200);
    expect(begins()).toHaveLength(1);
    expect(stripeRefundsCreate).toHaveBeenCalledWith({ payment_intent: 'pi_123', amount: 4000 }, { idempotencyKey: `refund-request-${REQUEST}` });
    const refund = db.tables.site_table_booking_refunds[0];
    expect(refund).toMatchObject({ booking_id: BOOKING, refund_type: 'online', amount_cents: 4000, reason: 'Event cancelled by us', stripe_refund_id: 're_1' });
    expect(db.tables.site_table_bookings[0].amount_paid_cents).toBe(6000);
    expect(finishes()).toEqual([{ p_request: REQUEST, p_refund_id: refund.id, p_ok: true, p_note: null }]);
    expect(db.tables.audit_log[0].details).toMatchObject({ request_id: REQUEST, amount_cents: 4000 });
  });

  it('needs no amount or reason from the caller', async () => {
    expect((await post({ booking_id: BOOKING, refund_type: 'online', request_id: REQUEST })).status).toBe(200);
  });

  it('is refused for a signed-in person who is not a BottlesUp admin, before anything is claimed', async () => {
    seed({ admin: false });
    expect((await post({ booking_id: BOOKING, refund_type: 'online', request_id: REQUEST })).status).toBe(403);
    expect(begins()).toHaveLength(0);
    expect(stripeRefundsCreate).not.toHaveBeenCalled();
  });

  it('cannot be a club refund (those are recorded in the app, not returned here)', async () => {
    expect((await post({ booking_id: BOOKING, refund_type: 'club', request_id: REQUEST })).status).toBe(400);
    expect(begins()).toHaveLength(0);
  });

  it('that cannot be claimed (not approved, already processing) is refused and Stripe is never called', async () => {
    claim = { data: null, error: { message: 'this refund is not an approved online refund waiting to be processed' } };
    seed();
    const res = await post({ booking_id: BOOKING, refund_type: 'online', request_id: REQUEST });
    expect(res.status).toBe(409);
    expect(stripeRefundsCreate).not.toHaveBeenCalled();
    expect(finishes()).toHaveLength(0);
  });

  it('that belongs to a different booking than the call names is ended as failed, and Stripe is never called', async () => {
    db.tables.site_table_bookings.push({ id: OTHER_BOOKING, amount_paid_cents: 5000, stripe_payment_intent_id: 'pi_other' });
    // the request is for BOOKING; the call names OTHER_BOOKING
    const res = await post({ booking_id: OTHER_BOOKING, refund_type: 'online', request_id: REQUEST });
    expect(res.status).toBe(400);
    expect(stripeRefundsCreate).not.toHaveBeenCalled();
    expect(finishes()).toEqual([{ p_request: REQUEST, p_refund_id: null, p_ok: false, p_note: 'The call named a different booking than the request.' }]);
    expect(db.tables.site_table_booking_refunds).toHaveLength(0);
  });

  it('for more than the booking has taken in is ended as failed, and Stripe is never called', async () => {
    seed({ paid: 1000 });
    const res = await post({ booking_id: BOOKING, refund_type: 'online', request_id: REQUEST });
    expect(res.status).toBe(400);
    expect(stripeRefundsCreate).not.toHaveBeenCalled();
    expect(finishes()).toEqual([{ p_request: REQUEST, p_refund_id: null, p_ok: false, p_note: 'The refund is more than the booking has taken in.' }]);
  });

  it('with no online payment to return against is ended as failed', async () => {
    seed({ intent: null });
    const res = await post({ booking_id: BOOKING, refund_type: 'online', request_id: REQUEST });
    expect(res.status).toBe(400);
    expect(stripeRefundsCreate).not.toHaveBeenCalled();
    expect(finishes()[0]).toMatchObject({ p_ok: false, p_note: 'There is no online payment on this booking to refund against.' });
  });

  it('when Stripe fails is ended as failed with Stripe\'s words, and the booking keeps its money', async () => {
    stripeRefundsCreate.mockRejectedValue(new Error('Charge ch_1 has already been refunded.'));
    const res = await post({ booking_id: BOOKING, refund_type: 'online', request_id: REQUEST });
    expect(res.status).toBe(502);
    expect(finishes()).toEqual([{ p_request: REQUEST, p_refund_id: null, p_ok: false, p_note: 'Stripe: Charge ch_1 has already been refunded.' }]);
    expect(db.tables.site_table_booking_refunds).toHaveLength(0);
    expect(db.tables.site_table_bookings[0].amount_paid_cents).toBe(10000);
  });

  it('when the money WAS returned but could not be recorded stays claimed (never marked failed, so nobody returns it again) and tells the person', async () => {
    const realFrom = db.client.from;
    db.client.from = (table: string) => {
      if (table === 'site_table_booking_refunds') {
        const q: any = { insert: () => q, select: () => q, single: () => Promise.resolve({ data: null, error: { message: 'insert failed' } }) };
        return q;
      }
      return realFrom(table);
    };
    const res = await post({ booking_id: BOOKING, refund_type: 'online', request_id: REQUEST });
    expect(res.status).toBe(500);
    expect((await res.json()).error).toContain('Do not return it again');
    expect(stripeRefundsCreate).toHaveBeenCalledTimes(1);
    expect(finishes()).toHaveLength(0);
  });
});

describe('refund-table-booking-payment: the original ad hoc refund is unchanged', () => {
  it('needs an amount and a reason from the caller, and uses no idempotency key', async () => {
    expect((await post({ booking_id: BOOKING, refund_type: 'online', reason: 'x' })).status).toBe(400);
    expect((await post({ booking_id: BOOKING, refund_type: 'online', amount_cents: 2500 })).status).toBe(400);
    const res = await post({ booking_id: BOOKING, refund_type: 'online', amount_cents: 2500, reason: 'Goodwill' });
    expect(res.status).toBe(200);
    expect(stripeRefundsCreate).toHaveBeenCalledWith({ payment_intent: 'pi_123', amount: 2500 }, undefined);
    expect(begins()).toHaveLength(0);
    expect(finishes()).toHaveLength(0);
    expect(db.tables.site_table_bookings[0].amount_paid_cents).toBe(7500);
  });

  it('records a club refund without touching Stripe', async () => {
    const res = await post({ booking_id: BOOKING, refund_type: 'club', amount_cents: 1000, reason: 'Cash returned', pos_reference: 'T-1' });
    expect(res.status).toBe(200);
    expect(stripeRefundsCreate).not.toHaveBeenCalled();
    expect(db.tables.site_table_booking_refunds[0]).toMatchObject({ refund_type: 'club', pos_reference: 'T-1' });
  });

  it('refuses more than has been paid', async () => {
    expect((await post({ booking_id: BOOKING, refund_type: 'online', amount_cents: 10001, reason: 'Too much' })).status).toBe(400);
    expect(stripeRefundsCreate).not.toHaveBeenCalled();
  });
});
