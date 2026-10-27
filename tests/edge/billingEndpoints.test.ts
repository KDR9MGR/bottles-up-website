import { beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';

const h = vi.hoisted(() => ({ create: vi.fn(), portal: vi.fn(), keys: [] as string[] }));
vi.mock('npm:stripe@17', () => {
  class Stripe {
    checkout = { sessions: { create: h.create } };
    billingPortal = { sessions: { create: h.portal } };
    constructor(key: string) { h.keys.push(key); }
    static createFetchHttpClient() { return {}; }
  }
  return { default: Stripe };
});
vi.mock('npm:@supabase/supabase-js@2', () => ({ createClient: vi.fn() }));
import { createClient } from 'npm:@supabase/supabase-js@2';

const PROFILE = '3f2b8c1e-5a4d-4e7a-9b1c-0d6e8f7a2b3c';
const SUB = '9a1b2c3d-4e5f-4a6b-8c7d-0e1f2a3b4c5d';
const TIP = '1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5e';
const SUB_BEGIN = { subscription_id: SUB, plan: 'monthly', currency: 'cad', amount_cents: 2999, price: null, customer: null, profile_name: 'DJ Dee' };
const TIP_BEGIN = { tip_id: TIP, amount_cents: 500, currency: 'cad', creator_name: 'DJ Dee' };

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
  for (const name of ['create-subscription-checkout', 'create-billing-portal', 'create-tip-checkout']) {
    current = name;
    await import(`../../supabase/functions/${name}/index.ts`);
  }
});

beforeEach(() => {
  vi.clearAllMocks();
  h.keys.length = 0;
  vi.spyOn(console, 'error').mockImplementation(() => {});
  env = { SUPABASE_URL: 'http://db.test', SUPABASE_ANON_KEY: 'anon-key', SUPABASE_SERVICE_ROLE_KEY: 'service-key', STRIPE_SECRET_KEY_TEST: 'sk_test_1', SITE_URL: 'https://site.test' };
  user = { email: 'dee@x.example' };
  callerRpc = {};
  serviceRpc = {};
  tables = { site_content: { payments_mode: 'test' } };
  callerRpcCalls = [];
  serviceRpcCalls = [];
  h.create.mockResolvedValue({ id: 'cs_new', url: 'https://checkout.stripe.test/cs_new' });
  h.portal.mockResolvedValue({ url: 'https://billing.stripe.test/portal' });
  const rpcFor = (calls: [string, any][], answers: () => Record<string, any>) => async (name: string, args: any) => {
    calls.push([name, args]);
    const a = answers()[name];
    return typeof a === 'function' ? a(args) : (a ?? { data: null, error: null });
  };
  const chain = (row: any) => {
    const c: any = { select: () => c, eq: () => c, maybeSingle: async () => ({ data: row ?? null, error: null }) };
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

const goodBody: Record<string, unknown> = {
  'create-subscription-checkout': { profile_id: PROFILE, plan: 'monthly' },
  'create-billing-portal': { profile_id: PROFILE },
  'create-tip-checkout': { creator_id: PROFILE, amount_cents: 500 },
};

describe.each(['create-subscription-checkout', 'create-billing-portal', 'create-tip-checkout'])('%s: who may ask', (fn) => {
  it('only a POST', async () => {
    expect((await call(fn, goodBody[fn], {}, 'GET')).status).toBe(405);
  });
  it('answers the browser\'s preflight', async () => {
    const res = await handlers[fn](new Request('https://fn.test/x', { method: 'OPTIONS', headers: { origin: 'http://localhost:5173' } }));
    expect(res.status).toBeLessThan(300);
  });
  it('only someone signed in; nothing is looked up for anyone else', async () => {
    expect((await call(fn, goodBody[fn], {})).status).toBe(401);
    user = null;
    expect((await call(fn, goodBody[fn])).status).toBe(401);
    expect(callerRpcCalls).toHaveLength(0);
    expect(h.create).not.toHaveBeenCalled();
    expect(h.portal).not.toHaveBeenCalled();
  });
  it('a body that is not a request is turned away before the database is asked', async () => {
    expect((await call(fn, '{ not json')).status).toBe(400);
    expect((await call(fn, {})).status).toBe(400);
    expect((await call(fn, { profile_id: 'nope', creator_id: 'nope' })).status).toBe(400);
    expect(callerRpcCalls).toHaveLength(0);
  });
});

describe('create-subscription-checkout', () => {
  const ask = (body: unknown = goodBody['create-subscription-checkout'], headers?: Record<string, string>) => call('create-subscription-checkout', body, headers);

  it('wants a plan that is monthly or yearly', async () => {
    const res = await ask({ profile_id: PROFILE, plan: 'weekly' });
    expect(res.status).toBe(400);
    expect(await res.json()).toEqual({ error: 'Choose monthly or yearly.' });
    expect(callerRpcCalls).toHaveLength(0);
  });

  it('a login with no e-mail is not let in', async () => {
    user = {};
    expect((await ask()).status).toBe(401);
  });

  it('asks the database, as the caller, to begin this plan for this profile', async () => {
    callerRpc.sub_begin = { data: SUB_BEGIN, error: null };
    await ask({ profile_id: PROFILE.toUpperCase(), plan: 'yearly' });
    expect(callerRpcCalls[0]).toEqual(['sub_begin', { p_profile: PROFILE, p_plan: 'yearly' }]);
  });

  it('a refusal is shown as its sentence, and nothing is charged', async () => {
    callerRpc.sub_begin = { data: null, error: { code: 'P0001', message: 'This profile already has a subscription.' } };
    const res = await ask();
    expect(res.status).toBe(409);
    expect(await res.json()).toEqual({ error: 'This profile already has a subscription.' });
    expect(h.create).not.toHaveBeenCalled();
  });

  it('any other database failure is a plain 500 without detail', async () => {
    callerRpc.sub_begin = { data: null, error: { code: '42501', message: 'permission denied for function secret' } };
    const res = await ask();
    expect(res.status).toBe(500);
    expect(await res.json()).toEqual({ error: 'Internal server error' });
  });

  it('without a Stripe key it says payments are not set up', async () => {
    callerRpc.sub_begin = { data: SUB_BEGIN, error: null };
    delete env.STRIPE_SECRET_KEY_TEST;
    const res = await ask();
    expect(res.status).toBe(503);
    expect(await res.json()).toEqual({ error: 'Payments are not set up yet.' });
  });

  it('opens a subscription page for the amount, with the test key, and tells the database which page it is', async () => {
    callerRpc.sub_begin = { data: SUB_BEGIN, error: null };
    const res = await ask();
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ url: 'https://checkout.stripe.test/cs_new', session_id: 'cs_new', amount_cents: 2999, plan: 'monthly' });
    expect(h.keys).toEqual(['sk_test_1']);
    const params = h.create.mock.calls[0][0];
    expect(params.mode).toBe('subscription');
    expect(params.customer_email).toBe('dee@x.example');
    expect(params.metadata).toEqual({ kind: 'subscription', subscription_id: SUB });
    expect(params.success_url).toBe('https://site.test/pay/subscription-thanks?session_id={CHECKOUT_SESSION_ID}');
    expect(serviceRpcCalls.find((c) => c[0] === 'sub_attach')).toEqual(['sub_attach', { p_sub: SUB, p_session: 'cs_new' }]);
  });

  it('uses the live key only when the website is in live mode', async () => {
    callerRpc.sub_begin = { data: SUB_BEGIN, error: null };
    tables.site_content = { payments_mode: 'live' };
    env.STRIPE_SECRET_KEY_LIVE = 'sk_live_1';
    await ask();
    expect(h.keys).toEqual(['sk_live_1']);
  });

  it('returns to the website the request came from when it is one of ours, and to the configured one otherwise', async () => {
    callerRpc.sub_begin = { data: SUB_BEGIN, error: null };
    await ask(undefined, { Authorization: 'Bearer x', origin: 'https://www.bottlesupapp.com' });
    expect(h.create.mock.calls[0][0].success_url).toMatch(/^https:\/\/www\.bottlesupapp\.com\/pay\/subscription-thanks/);
    await ask(undefined, { Authorization: 'Bearer x', origin: 'https://evil.example' });
    expect(h.create.mock.calls[1][0].success_url).toMatch(/^https:\/\/site\.test\/pay\/subscription-thanks/);
    delete env.SITE_URL;
    await ask();
    expect(h.create.mock.calls[2][0].success_url).toMatch(/^http:\/\/localhost:5173\/pay\/subscription-thanks/);
  });

  it('a page without an address, or one that cannot be remembered, is an error', async () => {
    callerRpc.sub_begin = { data: SUB_BEGIN, error: null };
    h.create.mockResolvedValueOnce({ id: 'cs_none', url: null });
    expect((await ask()).status).toBe(500);
    expect(serviceRpcCalls.find((c) => c[0] === 'sub_attach')).toBeUndefined();
    serviceRpc.sub_attach = { data: null, error: { message: 'down' } };
    expect((await ask()).status).toBe(500);
  });

  it('Stripe failing is a plain 500', async () => {
    callerRpc.sub_begin = { data: SUB_BEGIN, error: null };
    h.create.mockRejectedValueOnce(new Error('stripe down'));
    const res = await ask();
    expect(res.status).toBe(500);
    expect(await res.json()).toEqual({ error: 'Internal server error' });
  });
});

describe('create-billing-portal', () => {
  const ask = (body: unknown = goodBody['create-billing-portal']) => call('create-billing-portal', body);

  it('asks the database, as the caller, for the customer of this profile', async () => {
    callerRpc.sub_customer = { data: 'cus_1', error: null };
    await ask({ profile_id: PROFILE.toUpperCase() });
    expect(callerRpcCalls[0]).toEqual(['sub_customer', { p_profile: PROFILE }]);
  });

  it('a refusal is shown as its sentence', async () => {
    callerRpc.sub_customer = { data: null, error: { code: 'P0001', message: 'This profile has no subscription to manage.' } };
    const res = await ask();
    expect(res.status).toBe(409);
    expect(await res.json()).toEqual({ error: 'This profile has no subscription to manage.' });
    expect(h.portal).not.toHaveBeenCalled();
  });

  it('any other database failure is a plain 500, and an answer that is no customer is refused', async () => {
    callerRpc.sub_customer = { data: null, error: { code: '42501', message: 'permission denied for function secret' } };
    expect((await ask()).status).toBe(500);
    callerRpc.sub_customer = { data: 'not-a-customer', error: null };
    expect((await ask()).status).toBe(409);
    callerRpc.sub_customer = { data: null, error: null };
    expect((await ask()).status).toBe(409);
    expect(h.portal).not.toHaveBeenCalled();
  });

  it('without a Stripe key it says payments are not set up', async () => {
    callerRpc.sub_customer = { data: 'cus_1', error: null };
    delete env.STRIPE_SECRET_KEY_TEST;
    expect((await ask()).status).toBe(503);
  });

  it('opens Stripe\'s billing page for that customer and returns to the website', async () => {
    callerRpc.sub_customer = { data: 'cus_1', error: null };
    const res = await ask();
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ url: 'https://billing.stripe.test/portal' });
    expect(h.portal).toHaveBeenCalledWith({ customer: 'cus_1', return_url: 'https://site.test/pay/subscription-thanks?portal=1' });
    expect(h.keys).toEqual(['sk_test_1']);
  });

  it('Stripe failing is a plain 500', async () => {
    callerRpc.sub_customer = { data: 'cus_1', error: null };
    h.portal.mockRejectedValueOnce(new Error('stripe down'));
    expect((await ask()).status).toBe(500);
  });
});

describe('create-tip-checkout', () => {
  const ask = (body: unknown = goodBody['create-tip-checkout'], headers?: Record<string, string>) => call('create-tip-checkout', body, headers);

  it('wants an amount that is a whole number of cents', async () => {
    for (const amount_cents of [0, -1, 5.5, '500', null]) {
      const res = await ask({ creator_id: PROFILE, amount_cents });
      expect(res.status).toBe(400);
      expect(await res.json()).toEqual({ error: 'Choose an amount.' });
    }
    expect(callerRpcCalls).toHaveLength(0);
  });

  it('a login with no e-mail is not let in', async () => {
    user = {};
    expect((await ask()).status).toBe(401);
  });

  it('asks the database, as the caller, to begin this tip, with the note trimmed or nothing', async () => {
    callerRpc.tip_begin = { data: TIP_BEGIN, error: null };
    await ask({ creator_id: PROFILE.toUpperCase(), amount_cents: 500, message: '  Great set  ' });
    expect(callerRpcCalls[0]).toEqual(['tip_begin', { p_creator: PROFILE, p_amount_cents: 500, p_message: 'Great set' }]);
    await ask({ creator_id: PROFILE, amount_cents: 500 });
    expect(callerRpcCalls[1][1].p_message).toBeNull();
  });

  it('a refusal is shown as its sentence, and nothing is charged', async () => {
    callerRpc.tip_begin = { data: null, error: { code: 'P0001', message: 'A tip is from 2.00 to 500.00.' } };
    const res = await ask();
    expect(res.status).toBe(409);
    expect(await res.json()).toEqual({ error: 'A tip is from 2.00 to 500.00.' });
    expect(h.create).not.toHaveBeenCalled();
  });

  it('any other database failure is a plain 500 without detail', async () => {
    callerRpc.tip_begin = { data: null, error: { code: '42501', message: 'permission denied for function secret' } };
    const res = await ask();
    expect(res.status).toBe(500);
    expect(await res.json()).toEqual({ error: 'Internal server error' });
  });

  it('without a Stripe key it says payments are not set up', async () => {
    callerRpc.tip_begin = { data: TIP_BEGIN, error: null };
    delete env.STRIPE_SECRET_KEY_TEST;
    expect((await ask()).status).toBe(503);
  });

  it('opens one page for exactly the amount, and tells the database which page it is', async () => {
    callerRpc.tip_begin = { data: TIP_BEGIN, error: null };
    const res = await ask();
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ url: 'https://checkout.stripe.test/cs_new', session_id: 'cs_new', amount_cents: 500 });
    const params = h.create.mock.calls[0][0];
    expect(params.mode).toBe('payment');
    expect(params.customer_email).toBe('dee@x.example');
    expect(params.line_items[0].price_data.unit_amount).toBe(500);
    expect(params.metadata).toEqual({ kind: 'tip', tip_id: TIP });
    expect(params.success_url).toBe('https://site.test/pay/tip-thanks?session_id={CHECKOUT_SESSION_ID}');
    expect(serviceRpcCalls.find((c) => c[0] === 'tip_attach')).toEqual(['tip_attach', { p_tip: TIP, p_session: 'cs_new' }]);
  });

  it('a page without an address, or one that cannot be remembered, is an error', async () => {
    callerRpc.tip_begin = { data: TIP_BEGIN, error: null };
    h.create.mockResolvedValueOnce({ id: 'cs_none', url: null });
    expect((await ask()).status).toBe(500);
    serviceRpc.tip_attach = { data: null, error: { message: 'down' } };
    expect((await ask()).status).toBe(500);
  });

  it('uses the live key only when the website is in live mode', async () => {
    callerRpc.tip_begin = { data: TIP_BEGIN, error: null };
    tables.site_content = { payments_mode: 'live' };
    env.STRIPE_SECRET_KEY_LIVE = 'sk_live_1';
    await ask();
    expect(h.keys).toEqual(['sk_live_1']);
  });
});
