import { beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';

// Stripe and the database are stood in for; what matters here is who may ask, what is checked first, what is sent to Stripe and what is told to the database.
const h = vi.hoisted(() => ({
  create: vi.fn(),
  retrieve: vi.fn(),
  refund: vi.fn(),
  keys: [] as string[],
}));
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

const SHARE = '3f2b8c1e-5a4d-4e7a-9b1c-0d6e8f7a2b3c';
const SPLIT = '9a1b2c3d-4e5f-4a6b-8c7d-0e1f2a3b4c5d';
const BEGIN = { id: SHARE, amount_cents: 2500, currency: 'cad', booking_id: 'bk', venue: 'Split Club', booking_date: '2026-11-07', start_time: '22:00', host: 'Ann', pending_session: null };

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
  (globalThis as any).Deno = {
    serve: (fn: (req: Request) => Promise<Response>) => { handlers[current] = fn; },
    env: { get: (k: string) => env[k] },
  };
  for (const name of ['create-split-checkout', 'confirm-split-share', 'cancel-split', 'process-split-refunds']) {
    current = name;
    await import(`../../supabase/functions/${name}/index.ts`);
  }
});

beforeEach(() => {
  vi.clearAllMocks();
  h.keys.length = 0;
  vi.spyOn(console, 'error').mockImplementation(() => {});
  env = { SUPABASE_URL: 'http://db.test', SUPABASE_ANON_KEY: 'anon-key', SUPABASE_SERVICE_ROLE_KEY: 'service-key', STRIPE_SECRET_KEY_TEST: 'sk_test_1', SITE_URL: 'https://site.test' };
  user = { email: 'bob@x.example' };
  callerRpc = {};
  serviceRpc = {};
  tables = { site_content: { payments_mode: 'test' }, site_split_shares: { stripe_session_id: 'cs_open' } };
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
  (createClient as any).mockImplementation((_url: string, key: string) => {
    if (key === 'anon-key') {
      return { auth: { getUser: async () => (user ? { data: { user }, error: null } : { data: { user: null }, error: { message: 'bad jwt' } }) }, rpc: rpcFor(callerRpcCalls, () => callerRpc) };
    }
    return {
      rpc: rpcFor(serviceRpcCalls, () => serviceRpc),
      from: (table: string) => ({ select: () => ({ eq: () => ({ maybeSingle: async () => ({ data: tables[table] ?? null, error: null }) }) }) }),
    };
  });
});

const call = (fn: string, body: unknown, headers: Record<string, string> = { Authorization: 'Bearer user-jwt' }, method = 'POST') =>
  handlers[fn](new Request(`https://fn.test/${fn}`, { method, headers: { 'content-type': 'application/json', ...headers }, body: method === 'GET' ? undefined : typeof body === 'string' ? body : JSON.stringify(body) }));

describe.each([['create-split-checkout', { share_id: SHARE }], ['confirm-split-share', { share_id: SHARE }], ['cancel-split', { split_id: SPLIT }]])('%s: who may ask', (fn, body) => {
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
    expect((await call(fn, { share_id: 'x', split_id: 'y' })).status).toBe(400);
    expect(callerRpcCalls).toHaveLength(0);
  });
});

describe('create-split-checkout', () => {
  it('a person with no e-mail on their login is not let in', async () => {
    user = {};
    expect((await call('create-split-checkout', { share_id: SHARE })).status).toBe(401);
  });

  it('asks the database with the caller\'s own login for exactly this request', async () => {
    callerRpc.split_share_begin = { data: BEGIN, error: null };
    await call('create-split-checkout', { share_id: SHARE.toUpperCase() });
    expect(callerRpcCalls[0]).toEqual(['split_share_begin', { p_share: SHARE }]);
  });

  it('a refusal from the database is shown as its sentence, and nothing is charged', async () => {
    callerRpc.split_share_begin = { data: null, error: { code: 'P0001', message: 'You already paid this.' } };
    const res = await call('create-split-checkout', { share_id: SHARE });
    expect(res.status).toBe(409);
    expect(await res.json()).toEqual({ error: 'You already paid this.' });
    expect(h.create).not.toHaveBeenCalled();
  });

  it('any other database failure is a plain 500 without detail', async () => {
    callerRpc.split_share_begin = { data: null, error: { code: '42501', message: 'permission denied for function secret' } };
    const res = await call('create-split-checkout', { share_id: SHARE });
    expect(res.status).toBe(500);
    expect(await res.json()).toEqual({ error: 'Internal server error' });
  });

  it('without a Stripe key it says payments are not set up', async () => {
    callerRpc.split_share_begin = { data: BEGIN, error: null };
    delete env.STRIPE_SECRET_KEY_TEST;
    const res = await call('create-split-checkout', { share_id: SHARE });
    expect(res.status).toBe(503);
    expect(await res.json()).toEqual({ error: 'Payments are not set up yet.' });
  });

  it('creates one page for the share\'s amount, in test mode with the test key, and remembers it for 31 minutes', async () => {
    callerRpc.split_share_begin = { data: BEGIN, error: null };
    const before = Date.now();
    const res = await call('create-split-checkout', { share_id: SHARE });
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ url: 'https://checkout.stripe.test/cs_new', session_id: 'cs_new' });
    expect(h.keys).toEqual(['sk_test_1']);
    const params = h.create.mock.calls[0][0];
    expect(params.customer_email).toBe('bob@x.example');
    expect(params.line_items[0].price_data.unit_amount).toBe(2500);
    expect(params.metadata).toEqual({ kind: 'split_share', share_id: SHARE });
    expect(params.success_url).toBe('https://site.test/pay/share-thanks?session_id={CHECKOUT_SESSION_ID}');
    const attach = serviceRpcCalls.find((c) => c[0] === 'split_share_attach')!;
    expect(attach[1].p_share).toBe(SHARE);
    expect(attach[1].p_session).toBe('cs_new');
    const until = Date.parse(attach[1].p_until);
    expect(until - before).toBeGreaterThanOrEqual(31 * 60 * 1000 - 5000);
    expect(until - before).toBeLessThan(31 * 60 * 1000 + 5000);
  });

  it('uses the live key only when the website is in live mode', async () => {
    callerRpc.split_share_begin = { data: BEGIN, error: null };
    tables.site_content = { payments_mode: 'live' };
    env.STRIPE_SECRET_KEY_LIVE = 'sk_live_1';
    await call('create-split-checkout', { share_id: SHARE });
    expect(h.keys).toEqual(['sk_live_1']);
  });

  it('returns to the website the request came from when it is one of ours, and to the configured one otherwise', async () => {
    callerRpc.split_share_begin = { data: BEGIN, error: null };
    await call('create-split-checkout', { share_id: SHARE }, { Authorization: 'Bearer x', origin: 'https://www.bottlesupapp.com' });
    expect(h.create.mock.calls[0][0].success_url).toMatch(/^https:\/\/www\.bottlesupapp\.com\/pay\/share-thanks/);
    await call('create-split-checkout', { share_id: SHARE }, { Authorization: 'Bearer x', origin: 'https://evil.example' });
    expect(h.create.mock.calls[1][0].success_url).toMatch(/^https:\/\/site\.test\/pay\/share-thanks/);
    delete env.SITE_URL;
    await call('create-split-checkout', { share_id: SHARE });
    expect(h.create.mock.calls[2][0].success_url).toMatch(/^http:\/\/localhost:5173\/pay\/share-thanks/);
  });

  it('a page opened in the last half hour and still open is handed back, and no second one is made', async () => {
    callerRpc.split_share_begin = { data: { ...BEGIN, pending_session: 'cs_open' }, error: null };
    const res = await call('create-split-checkout', { share_id: SHARE });
    expect(await res.json()).toEqual({ url: 'https://checkout.stripe.test/cs_open', session_id: 'cs_open' });
    expect(h.retrieve).toHaveBeenCalledWith('cs_open');
    expect(h.create).not.toHaveBeenCalled();
    expect(serviceRpcCalls.find((c) => c[0] === 'split_share_attach')).toBeUndefined();
  });

  it('a page that has expired, been completed or cannot be looked at is replaced by a new one', async () => {
    callerRpc.split_share_begin = { data: { ...BEGIN, pending_session: 'cs_open' }, error: null };
    h.retrieve.mockResolvedValueOnce({ id: 'cs_open', status: 'expired', url: null });
    expect((await (await call('create-split-checkout', { share_id: SHARE })).json()).session_id).toBe('cs_new');
    h.retrieve.mockResolvedValueOnce({ id: 'cs_open', status: 'complete', url: 'https://x' });
    expect((await (await call('create-split-checkout', { share_id: SHARE })).json()).session_id).toBe('cs_new');
    h.retrieve.mockRejectedValueOnce(Object.assign(new Error('no'), { code: 'resource_missing' }));
    expect((await (await call('create-split-checkout', { share_id: SHARE })).json()).session_id).toBe('cs_new');
    expect(h.create).toHaveBeenCalledTimes(3);
  });

  it('a page Stripe gave no address for is an error and is not remembered', async () => {
    callerRpc.split_share_begin = { data: BEGIN, error: null };
    h.create.mockResolvedValueOnce({ id: 'cs_none', url: null });
    expect((await call('create-split-checkout', { share_id: SHARE })).status).toBe(500);
    expect(serviceRpcCalls.find((c) => c[0] === 'split_share_attach')).toBeUndefined();
  });

  it('a page that could not be remembered is an error, so nobody is sent to pay for something the website cannot match', async () => {
    callerRpc.split_share_begin = { data: BEGIN, error: null };
    serviceRpc.split_share_attach = { data: null, error: { message: 'down' } };
    const res = await call('create-split-checkout', { share_id: SHARE });
    expect(res.status).toBe(500);
    expect(await res.json()).toEqual({ error: 'Internal server error' });
  });

  it('Stripe failing is a 500 without detail', async () => {
    callerRpc.split_share_begin = { data: BEGIN, error: null };
    h.create.mockRejectedValueOnce(new Error('card network exploded with secrets'));
    const res = await call('create-split-checkout', { share_id: SHARE });
    expect(res.status).toBe(500);
    expect(JSON.stringify(await res.json())).not.toContain('secrets');
  });
});

describe('confirm-split-share', () => {
  const ask = () => call('confirm-split-share', { share_id: SHARE });

  it('asks the database, as the caller, whether the request is theirs', async () => {
    callerRpc.split_share_status = { data: { state: 'unpaid' }, error: null };
    await ask();
    expect(callerRpcCalls[0]).toEqual(['split_share_status', { p_share: SHARE }]);
  });

  it('a request that is not theirs is refused with the database\'s sentence', async () => {
    callerRpc.split_share_status = { data: null, error: { code: 'P0001', message: 'This request is not available.' } };
    const res = await ask();
    expect(res.status).toBe(409);
    expect(await res.json()).toEqual({ error: 'This request is not available.' });
    expect(h.retrieve).not.toHaveBeenCalled();
  });

  it('any other failure is a plain 500', async () => {
    callerRpc.split_share_status = { data: null, error: { code: 'XX000', message: 'internal detail' } };
    const res = await ask();
    expect(res.status).toBe(500);
    expect(await res.json()).toEqual({ error: 'Internal server error' });
  });

  it.each(['paid', 'refunding', 'refunded'])('a share already %s is paid, and Stripe is not asked', async (state) => {
    callerRpc.split_share_status = { data: { state }, error: null };
    expect(await (await ask()).json()).toEqual({ status: 'paid' });
    expect(h.retrieve).not.toHaveBeenCalled();
  });

  it.each(['unpaid', 'expired', 'cancelled', 'declined'])('a share that is %s is said as it is, and Stripe is not asked', async (state) => {
    callerRpc.split_share_status = { data: { state }, error: null };
    expect(await (await ask()).json()).toEqual({ status: state });
    expect(h.retrieve).not.toHaveBeenCalled();
  });

  it('a state the database does not give is treated as unpaid', async () => {
    callerRpc.split_share_status = { data: {}, error: null };
    expect(await (await ask()).json()).toEqual({ status: 'unpaid' });
  });

  describe('while the payment page is open', () => {
    beforeEach(() => { callerRpc.split_share_status = { data: { state: 'pending' }, error: null }; });

    it('stays pending when Stripe says it is not paid yet', async () => {
      expect(await (await ask()).json()).toEqual({ status: 'pending' });
      expect(h.retrieve).toHaveBeenCalledWith('cs_open');
      expect(serviceRpcCalls.find((c) => c[0] === 'split_share_paid')).toBeUndefined();
    });

    it('stays pending when the website has no record of a page, or no Stripe key', async () => {
      tables.site_split_shares = { stripe_session_id: null };
      expect(await (await ask()).json()).toEqual({ status: 'pending' });
      tables.site_split_shares = null;
      expect(await (await ask()).json()).toEqual({ status: 'pending' });
      tables.site_split_shares = { stripe_session_id: 'cs_open' };
      delete env.STRIPE_SECRET_KEY_TEST;
      expect(await (await ask()).json()).toEqual({ status: 'pending' });
      expect(h.retrieve).not.toHaveBeenCalled();
    });

    it('does the webhook\'s job when Stripe says it was paid', async () => {
      h.retrieve.mockResolvedValueOnce({ id: 'cs_open', payment_status: 'paid', payment_intent: 'pi_1', amount_total: 2500 });
      serviceRpc.split_share_paid = { data: { result: 'applied', applied_cents: 2500, refund_cents: 0 }, error: null };
      expect(await (await ask()).json()).toEqual({ status: 'paid' });
      expect(serviceRpcCalls.find((c) => c[0] === 'split_share_paid')![1]).toEqual({ p_session: 'cs_open', p_payment_intent: 'pi_1', p_amount: 2500 });
    });

    it('reads a payment intent that comes as an object', async () => {
      h.retrieve.mockResolvedValueOnce({ id: 'cs_open', payment_status: 'paid', payment_intent: { id: 'pi_obj' }, amount_total: 2500 });
      serviceRpc.split_share_paid = { data: { result: 'already' }, error: null };
      await ask();
      expect(serviceRpcCalls.find((c) => c[0] === 'split_share_paid')![1].p_payment_intent).toBe('pi_obj');
    });

    it('a payment the database could not use is still a payment the person made: it says paid, and the money is paid back', async () => {
      h.retrieve.mockResolvedValueOnce({ id: 'cs_open', payment_status: 'paid', payment_intent: 'pi_1', amount_total: 2500 });
      serviceRpc.split_share_paid = { data: { result: 'refund', applied_cents: 0, refund_cents: 2500 }, error: null };
      serviceRpc.split_refunds_due = { data: [{ share_id: SHARE, split_id: SPLIT, stripe_payment_intent_id: 'pi_1', cents: 2500 }], error: null };
      expect(await (await ask()).json()).toEqual({ status: 'paid' });
      expect(h.refund).toHaveBeenCalledTimes(1);
    });

    it('stays pending when the database failed to record it, so it is asked again', async () => {
      h.retrieve.mockResolvedValueOnce({ id: 'cs_open', payment_status: 'paid', payment_intent: 'pi_1', amount_total: 2500 });
      serviceRpc.split_share_paid = { data: null, error: { message: 'down' } };
      expect(await (await ask()).json()).toEqual({ status: 'pending' });
    });

    it('stays pending when Stripe cannot be asked', async () => {
      h.retrieve.mockRejectedValueOnce(new Error('network'));
      expect(await (await ask()).json()).toEqual({ status: 'pending' });
    });
  });
});

describe('cancel-split', () => {
  const ask = () => call('cancel-split', { split_id: SPLIT });
  const card = { id: SPLIT, state: 'cancelled' };

  it('the database decides who may; a refusal is its sentence and nothing is paid back', async () => {
    callerRpc.split_cancel = { data: null, error: { code: 'P0001', message: 'This split is not available.' } };
    const res = await ask();
    expect(res.status).toBe(409);
    expect(await res.json()).toEqual({ error: 'This split is not available.' });
    expect(h.refund).not.toHaveBeenCalled();
    expect(serviceRpcCalls).toHaveLength(0);
  });

  it('any other failure is a plain 500', async () => {
    callerRpc.split_cancel = { data: null, error: { code: 'XX000', message: 'internal' } };
    const res = await ask();
    expect(res.status).toBe(500);
    expect(await res.json()).toEqual({ error: 'Internal server error' });
  });

  it('cancels as the caller, then pays back this split\'s shares and no one else\'s', async () => {
    callerRpc.split_cancel = { data: card, error: null };
    serviceRpc.split_refunds_due = {
      data: [
        { share_id: 'sh1', split_id: SPLIT, stripe_payment_intent_id: 'pi_1', cents: 5000 },
        { share_id: 'sh9', split_id: 'another-split', stripe_payment_intent_id: 'pi_9', cents: 900 },
      ],
      error: null,
    };
    const res = await ask();
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ split: card, refunded: 1, failed: 0 });
    expect(callerRpcCalls[0]).toEqual(['split_cancel', { p_split: SPLIT }]);
    expect(h.refund).toHaveBeenCalledTimes(1);
    expect(h.refund.mock.calls[0][0].payment_intent).toBe('pi_1');
  });

  it('with no Stripe key the split is still cancelled and the refunds are left for the next run', async () => {
    callerRpc.split_cancel = { data: card, error: null };
    delete env.STRIPE_SECRET_KEY_TEST;
    const res = await ask();
    expect(await res.json()).toEqual({ split: card, refunded: 0, failed: 0 });
    expect(h.refund).not.toHaveBeenCalled();
  });

  it('a Stripe that refuses is counted, and the split is cancelled all the same', async () => {
    callerRpc.split_cancel = { data: card, error: null };
    serviceRpc.split_refunds_due = { data: [{ share_id: 'sh1', split_id: SPLIT, stripe_payment_intent_id: 'pi_1', cents: 5000 }], error: null };
    h.refund.mockRejectedValueOnce(Object.assign(new Error('no'), { code: 'charge_already_refunded' }));
    expect(await (await ask()).json()).toEqual({ split: card, refunded: 0, failed: 1 });
  });
});

describe('process-split-refunds', () => {
  const run = (headers: Record<string, string> = { Authorization: 'Bearer service-key' }, method = 'POST') => call('process-split-refunds', {}, headers, method);

  it('only a POST with the service key; no one else, and nothing is touched for them', async () => {
    expect((await run({ Authorization: 'Bearer service-key' }, 'GET')).status).toBe(405);
    expect((await run({})).status).toBe(401);
    expect((await run({ Authorization: 'Bearer user-jwt' })).status).toBe(401);
    expect((await run({ Authorization: 'service-key' })).status).toBe(401);
    expect((await run({ Authorization: 'Bearer service-keyx' })).status).toBe(401);
    expect(createClient).not.toHaveBeenCalled();
    expect(h.refund).not.toHaveBeenCalled();
  });

  it('pays back everything that is due, and says how many', async () => {
    serviceRpc.split_refunds_due = {
      data: [
        { share_id: 'sh1', split_id: 'a', stripe_payment_intent_id: 'pi_1', cents: 5000 },
        { share_id: 'sh2', split_id: 'b', stripe_payment_intent_id: 'pi_2', cents: 2000 },
      ],
      error: null,
    };
    const res = await run();
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ refunded: 2, failed: 0 });
    expect(h.refund).toHaveBeenCalledTimes(2);
  });

  it('nothing due is nothing paid back', async () => {
    expect(await (await run()).json()).toEqual({ refunded: 0, failed: 0 });
    expect(h.refund).not.toHaveBeenCalled();
  });

  it('with no Stripe key it says payments are not set up and touches nothing', async () => {
    delete env.STRIPE_SECRET_KEY_TEST;
    const res = await run();
    expect(res.status).toBe(503);
    expect(serviceRpcCalls).toHaveLength(0);
  });

  it('a failure on the way is a plain 500 without detail', async () => {
    (createClient as any).mockImplementationOnce(() => { throw new Error('secret internals'); });
    const res = await run();
    expect(res.status).toBe(500);
    expect(JSON.stringify(await res.json())).not.toContain('secret');
  });
});
