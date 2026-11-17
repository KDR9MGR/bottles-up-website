import { beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';

vi.mock('npm:@supabase/supabase-js@2', () => ({ createClient: vi.fn() }));
import { createClient } from 'npm:@supabase/supabase-js@2';

// The public door of the claim page: nobody is signed in. What matters here is the wiring: only the service key is used, the visitor's address is hashed before it is a key, nothing is cached, and
// the page can call it from the website.
const TOKEN = 'ab'.repeat(32);
const TABLE = '33333333-3333-4333-8333-333333333333';

let env: Record<string, string | undefined> = {};
let handler: (req: Request) => Promise<Response>;
let serviceRpc: ReturnType<typeof vi.fn>;

beforeAll(async () => {
  (globalThis as any).Deno = { serve: (h: (req: Request) => Promise<Response>) => { handler = h; }, env: { get: (k: string) => env[k] } };
  await import('../../supabase/functions/comp-claim/index.ts');
});

beforeEach(() => {
  vi.clearAllMocks();
  vi.spyOn(console, 'error').mockImplementation(() => {});
  env = { SUPABASE_URL: 'http://db.test', SUPABASE_ANON_KEY: 'anon-key', SUPABASE_SERVICE_ROLE_KEY: 'service-key' };
  serviceRpc = vi.fn(async (fn: string) => (fn === 'comp_claim_throttle' ? { data: true, error: null } : { data: { state: 'submitted' }, error: null }));
  (createClient as any).mockImplementation(() => ({ rpc: serviceRpc }));
});

const post = (body: unknown, headers: Record<string, string> = {}) =>
  handler(new Request('https://fn.test/comp-claim', { method: 'POST', headers: { 'Content-Type': 'application/json', ...headers }, body: typeof body === 'string' ? body : JSON.stringify(body) }));

describe('the endpoint', () => {
  it('answers a browser preflight from the website', async () => {
    const res = await handler(new Request('https://fn.test/x', { method: 'OPTIONS', headers: { origin: 'https://www.bottlesupapp.com' } }));
    expect(res.status).toBe(200);
    expect(res.headers.get('Access-Control-Allow-Origin')).toBe('https://www.bottlesupapp.com');
  });

  it('only accepts POST', async () => {
    expect((await handler(new Request('https://fn.test/x', { method: 'GET' }))).status).toBe(405);
  });

  it('needs no sign-in: a visitor reaches it', async () => {
    const res = await post({ action: 'submit', token: TOKEN, tableId: TABLE });
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ state: 'submitted' });
  });

  it('refuses a body that is not JSON', async () => {
    const res = await post('{not json');
    expect(res.status).toBe(400);
    expect(serviceRpc).not.toHaveBeenCalled();
  });

  it('fails without the service key and asks nothing', async () => {
    delete env.SUPABASE_SERVICE_ROLE_KEY;
    expect((await post({ action: 'view', token: TOKEN })).status).toBe(500);
    expect(createClient).not.toHaveBeenCalled();
  });

  it('uses only the service key, never the visitor\'s', async () => {
    await post({ action: 'view', token: TOKEN }, { Authorization: 'Bearer visitor-jwt' });
    expect((createClient as any).mock.calls.every((c: unknown[]) => c[1] === 'service-key')).toBe(true);
  });

  it('keys the throttle on a hash of the visitor\'s address, not the address', async () => {
    await post({ action: 'view', token: TOKEN }, { 'x-forwarded-for': '203.0.113.9, 10.0.0.1' });
    const key = serviceRpc.mock.calls[0][1].p_key as string;
    expect(key).toMatch(/^ip:[0-9a-f]{32}$/);
    expect(key).not.toContain('203.0.113.9');
  });

  it('counts two visitors apart and the same visitor together, using the first address', async () => {
    await post({ action: 'view', token: TOKEN }, { 'x-forwarded-for': '203.0.113.9, 10.0.0.1' });
    await post({ action: 'view', token: TOKEN }, { 'x-forwarded-for': '203.0.113.9, 10.9.9.9' });
    await post({ action: 'view', token: TOKEN }, { 'x-forwarded-for': '198.51.100.7' });
    const keys = serviceRpc.mock.calls.filter((c) => c[0] === 'comp_claim_throttle' && String(c[1].p_key).startsWith('ip:')).map((c) => c[1].p_key);
    expect(keys[0]).toBe(keys[1]);
    expect(keys[2]).not.toBe(keys[0]);
  });

  it('is never cached', async () => {
    expect((await post({ action: 'view', token: TOKEN })).headers.get('Cache-Control')).toBe('no-store');
  });

  it('too many tries is 429', async () => {
    serviceRpc.mockImplementation(async (fn: string) => (fn === 'comp_claim_throttle' ? { data: false, error: null } : { data: null, error: null }));
    const res = await post({ action: 'view', token: TOKEN });
    expect(res.status).toBe(429);
    expect(await res.json()).toEqual({ error: 'Too many tries. Wait a few minutes and try again.' });
  });
});
