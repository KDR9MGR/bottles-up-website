import { beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';

const h = vi.hoisted(() => ({ create: vi.fn(), retrieve: vi.fn(), refund: vi.fn(), keys: [] as string[] }));
vi.mock('npm:stripe@17', () => {
  class Stripe {
    checkout = { sessions: { create: h.create, retrieve: h.retrieve } };
    refunds = { create: h.refund };
    constructor(key: string) { h.keys.push(key); }
    static createFetchHttpClient() { return {}; }
  }
  return { default: Stripe };
});
vi.mock('npm:@supabase/supabase-js@2', () => ({ createClient: vi.fn() }));
import { createClient } from 'npm:@supabase/supabase-js@2';

const BOOKING = '3f2b8c1e-5a4d-4e7a-9b1c-0d6e8f7a2b3c';
const PAYMENT = '9a1b2c3d-4e5f-4a6b-8c7d-0e1f2a3b4c5d';
const BEGIN = { payment_id: PAYMENT, kind: 'deposit', amount_cents: 30000, currency: 'cad', title: 'Wedding DJ set', event_date: '2026-12-05', provider: 'DJ Dee', pending_session: null };

let env: Record<string, string | undefined> = {};
const handlers: Record<string, (req: Request) => Promise<Response>> = {};
let current = '';
let callerRpc: Record<string, any>;
let serviceRpc: Record<string, any>;
let tables: Record<string, any>;
let user: { email?: string } | null;
let callerRpcCalls: [string, any][];
let serviceRpcCalls: [string, any][];

beforeAll(async () => {
  (globalThis as any).Deno = { serve: (fn: (req: Request) => Promise<Response>) => { handlers[current] = fn; }, env: { get: (k: string) => env[k] } };
  for (const name of ['create-pro-checkout', 'confirm-pro-payment', 'cancel-pro-booking', 'process-pro-bookings']) {
    current = name;
    await import(`../../supabase/functions/${name}/index.ts`);
  }
});

beforeEach(() => {
  vi.clearAllMocks();
  h.keys.length = 0;
  vi.spyOn(console, 'error').mockImplementation(() => {});
  env = { SUPABASE_URL: 'http://db.test', SUPABASE_ANON_KEY: 'anon-key', SUPABASE_SERVICE_ROLE_KEY: 'service-key', STRIPE_SECRET_KEY_TEST: 'sk_test_1', SITE_URL: 'https://site.test' };
  user = { email: 'ann@x.example' };
  callerRpc = {};
  serviceRpc = {};
  tables = { site_content: { payments_mode: 'test' }, site_pro_payments: { stripe_session_id: 'cs_open', status: 'pending' } };
  callerRpcCalls = [];
  serviceRpcCalls = [];
  h.create.mockResolvedValue({ id: 'cs_new', url: 'https://checkout.stripe.test/cs_new' });
  h.retrieve.mockResolvedValue({ id: 'cs_open', status: 'open', url: 'https://checkout.stripe.test/cs_open', payment_status: 'unpaid' });
  h.refund.mockResolvedValue({ id: 're_1' });
  const rpcFor = (calls: [string, any][], answers: () => Record<string, any>) => async (name: string, args: any) => {
    calls.push([name, args]);
    const a = answers()[name];
    return typeof a === 'function' ? a(args) : (a ?? { data: null, error: null });
  };
  // a chain that ignores the filters and gives the table's row, like the real query would for the one booking asked about
  const chain = (row: any) => {
    const c: any = { select: () => c, eq: () => c, order: () => c, limit: () => c, maybeSingle: async () => ({ data: row ?? null, error: null }) };
    return c;
  };
  (createClient as any).mockImplementation((_url: string, key: string) => {
    if (key === 'anon-key') {
      return { auth: { getUser: async () => (user ? { data: { user }, error: null } : { data: { user: null }, error: { message: 'bad jwt' } }) }, rpc: rpcFor(callerRpcCalls, () => callerRpc) };
    }
    return { rpc: rpcFor(serviceRpcCalls, () => serviceRpc), from: (table: string) => chain(tables[table]) };
  });
});

const call = (fn: string, body: unknown, headers: Record<string, string> = { Authorization: 'Bearer user-jwt' }, method = 'POST') =>
  handlers[fn](new Request(`https://fn.test/${fn}`, { method, headers: { 'content-type': 'application/json', ...headers }, body: method === 'GET' ? undefined : typeof body === 'string' ? body : JSON.stringify(body) }));

describe.each(['create-pro-checkout', 'confirm-pro-payment', 'cancel-pro-booking'])('%s: who may ask', (fn) => {
  const body = { booking_id: BOOKING };
  it('only a POST', async () => {
    expect((await call(fn, body, {}, 'GET')).status).toBe(405);
  });
  it('answers the browser\'s preflight', async () => {
    const res = await handlers[fn](new Request('https://fn.test/x', { method: 'OPTIONS', headers: { origin: 'http://localhost:5173' } }));
    expect(res.status).toBeLessThan(300);
  });
  it('only someone signed in; nothing is looked up for anyone else', async () => {
    expect((await call(fn, body, {})).status).toBe(401);
    user = null;
    expect((await call(fn, body)).status).toBe(401);
    expect(callerRpcCalls).toHaveLength(0);
    expect(h.create).not.toHaveBeenCalled();
    expect(h.refund).not.toHaveBeenCalled();
  });
  it('a body that is not a request is turned away before the database is asked', async () => {
    expect((await call(fn, '{ not json')).status).toBe(400);
    expect((await call(fn, {})).status).toBe(400);
    expect((await call(fn, { booking_id: 'nope' })).status).toBe(400);
    expect(callerRpcCalls).toHaveLength(0);
  });
});

describe('create-pro-checkout', () => {
  const ask = (headers?: Record<string, string>) => call('create-pro-checkout', { booking_id: BOOKING }, headers);

  it('a login with no e-mail is not let in', async () => {
    user = {};
    expect((await ask()).status).toBe(401);
  });

  it('asks the database, as the caller, for this booking', async () => {
    callerRpc.pro_payment_begin = { data: BEGIN, error: null };
    await call('create-pro-checkout', { booking_id: BOOKING.toUpperCase() });
    expect(callerRpcCalls[0]).toEqual(['pro_payment_begin', { p_booking: BOOKING }]);
  });

  it('a refusal is shown as its sentence, and nothing is charged', async () => {
    callerRpc.pro_payment_begin = { data: null, error: { code: 'P0001', message: 'The time to pay for this booking has passed. Ask for a new quote.' } };
    const res = await ask();
    expect(res.status).toBe(409);
    expect(await res.json()).toEqual({ error: 'The time to pay for this booking has passed. Ask for a new quote.' });
    expect(h.create).not.toHaveBeenCalled();
  });

  it('any other database failure is a plain 500 without detail', async () => {
    callerRpc.pro_payment_begin = { data: null, error: { code: '42501', message: 'permission denied for function secret' } };
    const res = await ask();
    expect(res.status).toBe(500);
    expect(await res.json()).toEqual({ error: 'Internal server error' });
  });

  it('without a Stripe key it says payments are not set up', async () => {
    callerRpc.pro_payment_begin = { data: BEGIN, error: null };
    delete env.STRIPE_SECRET_KEY_TEST;
    const res = await ask();
    expect(res.status).toBe(503);
    expect(await res.json()).toEqual({ error: 'Payments are not set up yet.' });
  });

  it('creates one page for the amount, in test mode with the test key, and remembers it for 31 minutes', async () => {
    callerRpc.pro_payment_begin = { data: BEGIN, error: null };
    const before = Date.now();
    const res = await ask();
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ url: 'https://checkout.stripe.test/cs_new', session_id: 'cs_new', kind: 'deposit', amount_cents: 30000 });
    expect(h.keys).toEqual(['sk_test_1']);
    const params = h.create.mock.calls[0][0];
    expect(params.customer_email).toBe('ann@x.example');
    expect(params.line_items[0].price_data.unit_amount).toBe(30000);
    expect(params.metadata).toEqual({ kind: 'pro_payment', payment_id: PAYMENT });
    expect(params.success_url).toBe('https://site.test/pay/booking-thanks?session_id={CHECKOUT_SESSION_ID}');
    const attach = serviceRpcCalls.find((c) => c[0] === 'pro_payment_attach')!;
    expect(attach[1].p_payment).toBe(PAYMENT);
    expect(attach[1].p_session).toBe('cs_new');
    const until = Date.parse(attach[1].p_until);
    expect(until - before).toBeGreaterThanOrEqual(31 * 60 * 1000 - 5000);
    expect(until - before).toBeLessThan(31 * 60 * 1000 + 5000);
  });

  it('uses the live key only when the website is in live mode', async () => {
    callerRpc.pro_payment_begin = { data: BEGIN, error: null };
    tables.site_content = { payments_mode: 'live' };
    env.STRIPE_SECRET_KEY_LIVE = 'sk_live_1';
    await ask();
    expect(h.keys).toEqual(['sk_live_1']);
  });

  it('returns to the website the request came from when it is one of ours, and to the configured one otherwise', async () => {
    callerRpc.pro_payment_begin = { data: BEGIN, error: null };
    await ask({ Authorization: 'Bearer x', origin: 'https://www.bottlesupapp.com' });
    expect(h.create.mock.calls[0][0].success_url).toMatch(/^https:\/\/www\.bottlesupapp\.com\/pay\/booking-thanks/);
    await ask({ Authorization: 'Bearer x', origin: 'https://evil.example' });
    expect(h.create.mock.calls[1][0].success_url).toMatch(/^https:\/\/site\.test\/pay\/booking-thanks/);
    delete env.SITE_URL;
    await ask();
    expect(h.create.mock.calls[2][0].success_url).toMatch(/^http:\/\/localhost:5173\/pay\/booking-thanks/);
  });

  it('a page opened in the last half hour and still open is handed back, and no second one is made', async () => {
    callerRpc.pro_payment_begin = { data: { ...BEGIN, pending_session: 'cs_open' }, error: null };
    const res = await ask();
    expect(await res.json()).toEqual({ url: 'https://checkout.stripe.test/cs_open', session_id: 'cs_open', kind: 'deposit', amount_cents: 30000 });
    expect(h.create).not.toHaveBeenCalled();
    expect(serviceRpcCalls.find((c) => c[0] === 'pro_payment_attach')).toBeUndefined();
  });

  it('a page that expired, completed or cannot be looked at is replaced', async () => {
    callerRpc.pro_payment_begin = { data: { ...BEGIN, pending_session: 'cs_open' }, error: null };
    h.retrieve.mockResolvedValueOnce({ id: 'cs_open', status: 'expired', url: null });
    expect((await (await ask()).json()).session_id).toBe('cs_new');
    h.retrieve.mockResolvedValueOnce({ id: 'cs_open', status: 'complete', url: 'https://x' });
    expect((await (await ask()).json()).session_id).toBe('cs_new');
    h.retrieve.mockRejectedValueOnce(Object.assign(new Error('no'), { code: 'resource_missing' }));
    expect((await (await ask()).json()).session_id).toBe('cs_new');
    expect(h.create).toHaveBeenCalledTimes(3);
  });

  it('a page without an address, or one that cannot be remembered, is an error', async () => {
    callerRpc.pro_payment_begin = { data: BEGIN, error: null };
    h.create.mockResolvedValueOnce({ id: 'cs_none', url: null });
    expect((await ask()).status).toBe(500);
    expect(serviceRpcCalls.find((c) => c[0] === 'pro_payment_attach')).toBeUndefined();
    serviceRpc.pro_payment_attach = { data: null, error: { message: 'down' } };
    expect((await ask()).status).toBe(500);
  });

  it('Stripe failing is a 500 without detail', async () => {
    callerRpc.pro_payment_begin = { data: BEGIN, error: null };
    h.create.mockRejectedValueOnce(new Error('card network exploded with secrets'));
    const res = await ask();
    expect(res.status).toBe(500);
    expect(JSON.stringify(await res.json())).not.toContain('secrets');
  });
});

describe('confirm-pro-payment', () => {
  const ask = () => call('confirm-pro-payment', { booking_id: BOOKING });
  const booking = (paid: number) => ({ id: BOOKING, state: 'confirmed', paid_cents: paid });

  it('asks the database, as the caller, whether the booking is theirs', async () => {
    callerRpc.pro_booking_get = { data: booking(0), error: null };
    tables.site_pro_payments = null;
    await ask();
    expect(callerRpcCalls[0]).toEqual(['pro_booking_get', { p_booking: BOOKING }]);
  });

  it('a booking that is not theirs is refused with the database\'s sentence', async () => {
    callerRpc.pro_booking_get = { data: null, error: { code: 'P0001', message: 'This booking is not available.' } };
    const res = await ask();
    expect(res.status).toBe(409);
    expect(await res.json()).toEqual({ error: 'This booking is not available.' });
    expect(h.retrieve).not.toHaveBeenCalled();
  });

  it('any other failure is a plain 500', async () => {
    callerRpc.pro_booking_get = { data: null, error: { code: 'XX000', message: 'internal' } };
    const res = await ask();
    expect(res.status).toBe(500);
    expect(await res.json()).toEqual({ error: 'Internal server error' });
  });

  it('with no page open it says none, or paid once something has been paid', async () => {
    tables.site_pro_payments = null;
    callerRpc.pro_booking_get = { data: booking(0), error: null };
    expect((await (await ask()).json()).status).toBe('none');
    callerRpc.pro_booking_get = { data: booking(30000), error: null };
    expect((await (await ask()).json()).status).toBe('paid');
    expect(h.retrieve).not.toHaveBeenCalled();
  });

  it('with a page open it asks Stripe, and stays pending while it is unpaid', async () => {
    callerRpc.pro_booking_get = { data: booking(0), error: null };
    const res = await ask();
    expect((await res.json()).status).toBe('pending');
    expect(h.retrieve).toHaveBeenCalledWith('cs_open');
    expect(serviceRpcCalls.find((c) => c[0] === 'pro_payment_paid')).toBeUndefined();
  });

  it('stays pending when there is no Stripe key, or Stripe cannot be asked', async () => {
    callerRpc.pro_booking_get = { data: booking(0), error: null };
    delete env.STRIPE_SECRET_KEY_TEST;
    expect((await (await ask()).json()).status).toBe('pending');
    env.STRIPE_SECRET_KEY_TEST = 'sk_test_1';
    h.retrieve.mockRejectedValueOnce(new Error('network'));
    expect((await (await ask()).json()).status).toBe('pending');
  });

  it('does the webhook\'s job when Stripe says it was paid, and gives back the booking as it now is', async () => {
    let paid = 0;
    callerRpc.pro_booking_get = () => ({ data: booking(paid), error: null });
    h.retrieve.mockResolvedValueOnce({ id: 'cs_open', payment_status: 'paid', payment_intent: 'pi_1', amount_total: 30000 });
    serviceRpc.pro_payment_paid = () => { paid = 30000; return { data: { result: 'applied', applied_cents: 30000, refund_cents: 0 }, error: null }; };
    const body = await (await ask()).json();
    expect(body.status).toBe('paid');
    expect(body.booking.paid_cents).toBe(30000);
    expect(serviceRpcCalls.find((c) => c[0] === 'pro_payment_paid')![1]).toEqual({ p_session: 'cs_open', p_payment_intent: 'pi_1', p_amount: 30000 });
  });

  it('reads a payment intent that comes as an object, and a payment the database could not use is still a payment made', async () => {
    callerRpc.pro_booking_get = { data: booking(0), error: null };
    h.retrieve.mockResolvedValueOnce({ id: 'cs_open', payment_status: 'paid', payment_intent: { id: 'pi_obj' }, amount_total: 30000 });
    serviceRpc.pro_payment_paid = { data: { result: 'refund', applied_cents: 0, refund_cents: 30000 }, error: null };
    serviceRpc.pro_refunds_due = { data: [{ payment_id: PAYMENT, booking_id: BOOKING, stripe_payment_intent_id: 'pi_obj', cents: 30000 }], error: null };
    expect((await (await ask()).json()).status).toBe('paid');
    expect(serviceRpcCalls.find((c) => c[0] === 'pro_payment_paid')![1].p_payment_intent).toBe('pi_obj');
    expect(h.refund).toHaveBeenCalledTimes(1);
  });

  it('stays pending when the database failed to record it, so it is asked again', async () => {
    callerRpc.pro_booking_get = { data: booking(0), error: null };
    h.retrieve.mockResolvedValueOnce({ id: 'cs_open', payment_status: 'paid', payment_intent: 'pi_1', amount_total: 30000 });
    serviceRpc.pro_payment_paid = { data: null, error: { message: 'down' } };
    expect((await (await ask()).json()).status).toBe('pending');
  });
});

describe('cancel-pro-booking', () => {
  const ask = (reason?: unknown) => call('cancel-pro-booking', { booking_id: BOOKING, reason });
  const card = { id: BOOKING, state: 'cancelled' };

  it('the database decides who may; a refusal is its sentence and nothing is paid back', async () => {
    callerRpc.pro_booking_cancel = { data: null, error: { code: 'P0001', message: 'This booking is already closed.' } };
    const res = await ask();
    expect(res.status).toBe(409);
    expect(await res.json()).toEqual({ error: 'This booking is already closed.' });
    expect(h.refund).not.toHaveBeenCalled();
    expect(serviceRpcCalls).toHaveLength(0);
  });

  it('any other failure is a plain 500', async () => {
    callerRpc.pro_booking_cancel = { data: null, error: { code: 'XX000', message: 'internal' } };
    const res = await ask();
    expect(res.status).toBe(500);
    expect(await res.json()).toEqual({ error: 'Internal server error' });
  });

  it('cancels as the caller with the reason (trimmed, at most 300), then pays back this booking\'s payments and no one else\'s', async () => {
    callerRpc.pro_booking_cancel = { data: card, error: null };
    serviceRpc.pro_refunds_due = {
      data: [
        { payment_id: 'p1', booking_id: BOOKING, stripe_payment_intent_id: 'pi_1', cents: 70000 },
        { payment_id: 'p9', booking_id: 'another-booking', stripe_payment_intent_id: 'pi_9', cents: 900 },
      ],
      error: null,
    };
    const res = await ask('  plans changed  ');
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ booking: card, refunded: 1, failed: 0 });
    expect(callerRpcCalls[0]).toEqual(['pro_booking_cancel', { p_booking: BOOKING, p_reason: 'plans changed' }]);
    expect(h.refund).toHaveBeenCalledTimes(1);
    expect(h.refund.mock.calls[0][0].payment_intent).toBe('pi_1');
    await ask('r'.repeat(400));
    expect(callerRpcCalls[1][1].p_reason.length).toBe(300);
    await ask(5);
    expect(callerRpcCalls[2][1].p_reason).toBe('');
  });

  it('with no Stripe key the booking is still cancelled and the refunds are left for the next run', async () => {
    callerRpc.pro_booking_cancel = { data: card, error: null };
    delete env.STRIPE_SECRET_KEY_TEST;
    expect(await (await ask()).json()).toEqual({ booking: card, refunded: 0, failed: 0 });
    expect(h.refund).not.toHaveBeenCalled();
  });

  it('a Stripe that refuses is counted, and the booking is cancelled all the same', async () => {
    callerRpc.pro_booking_cancel = { data: card, error: null };
    serviceRpc.pro_refunds_due = { data: [{ payment_id: 'p1', booking_id: BOOKING, stripe_payment_intent_id: 'pi_1', cents: 70000 }], error: null };
    h.refund.mockRejectedValueOnce(Object.assign(new Error('no'), { code: 'charge_already_refunded' }));
    expect(await (await ask()).json()).toEqual({ booking: card, refunded: 0, failed: 1 });
  });
});

describe('process-pro-bookings', () => {
  const run = (headers: Record<string, string> = { Authorization: 'Bearer service-key' }, method = 'POST') => call('process-pro-bookings', {}, headers, method);
  const swept = { lapsed: 1, balance_unpaid: 0, accounts_gone: 0, completed: 2 };

  it('only a POST with the service key; no one else, and nothing is touched for them', async () => {
    expect((await run({ Authorization: 'Bearer service-key' }, 'GET')).status).toBe(405);
    expect((await run({})).status).toBe(401);
    expect((await run({ Authorization: 'Bearer user-jwt' })).status).toBe(401);
    expect((await run({ Authorization: 'service-key' })).status).toBe(401);
    expect((await run({ Authorization: 'Bearer service-keyx' })).status).toBe(401);
    expect(createClient).not.toHaveBeenCalled();
    expect(h.refund).not.toHaveBeenCalled();
  });

  it('runs the housekeeping, then pays back everything that is due, and says what it did', async () => {
    serviceRpc.market_housekeeping = { data: swept, error: null };
    serviceRpc.pro_refunds_due = {
      data: [
        { payment_id: 'p1', booking_id: 'a', stripe_payment_intent_id: 'pi_1', cents: 5000 },
        { payment_id: 'p2', booking_id: 'b', stripe_payment_intent_id: 'pi_2', cents: 2000 },
      ],
      error: null,
    };
    const res = await run();
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ housekeeping: swept, refunded: 2, failed: 0 });
    expect(serviceRpcCalls[0][0]).toBe('market_housekeeping');
    expect(h.refund).toHaveBeenCalledTimes(2);
  });

  it('with no Stripe key it still does the housekeeping and says the refunds wait', async () => {
    serviceRpc.market_housekeeping = { data: swept, error: null };
    delete env.STRIPE_SECRET_KEY_TEST;
    const res = await run();
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ housekeeping: swept, refunded: 0, failed: 0, refunds: 'Payments are not set up yet.' });
    expect(h.refund).not.toHaveBeenCalled();
  });

  it('a housekeeping failure is a plain 500 without detail and refunds nothing', async () => {
    serviceRpc.market_housekeeping = { data: null, error: { message: 'secret internals' } };
    const res = await run();
    expect(res.status).toBe(500);
    expect(JSON.stringify(await res.json())).not.toContain('secret');
    expect(h.refund).not.toHaveBeenCalled();
  });

  it('a failure on the way is a plain 500', async () => {
    (createClient as any).mockImplementationOnce(() => { throw new Error('secret internals'); });
    expect((await run()).status).toBe(500);
  });
});
