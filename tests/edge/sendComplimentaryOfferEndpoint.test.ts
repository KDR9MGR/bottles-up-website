import { beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';

vi.mock('npm:@supabase/supabase-js@2', () => ({ createClient: vi.fn() }));
vi.mock('../../supabase/functions/_shared/compOfferSender.ts', () => ({ sendCompOfferEmail: vi.fn(async () => ({ sent: true })) }));
import { createClient } from 'npm:@supabase/supabase-js@2';
import { sendCompOfferEmail } from '../../supabase/functions/_shared/compOfferSender.ts';

// The door of send-complimentary-offer: a signed-in person only, POST only, the person's own session asks the question, the service key (held here only) makes the link and records the result.
const OFFER = '11111111-1111-4111-8111-111111111111';
const SEND = '22222222-2222-4222-8222-222222222222';
const TOKEN = 'ef'.repeat(32);
const ROW = { send_id: SEND, venue_id: 'v', to_email: 'gina@x.example', to_name: 'Gina', venue_name: 'Club A', event_title: null, item: 'Patron', quantity: 2, expires_at: '2026-11-25T02:00:00Z', time_zone: null, first_send: true };

let env: Record<string, string | undefined> = {};
let handler: (req: Request) => Promise<Response>;
let getUser: ReturnType<typeof vi.fn>;
let serviceRpc: ReturnType<typeof vi.fn>;
let userRpc: ReturnType<typeof vi.fn>;

beforeAll(async () => {
  (globalThis as any).Deno = { serve: (h: (req: Request) => Promise<Response>) => { handler = h; }, env: { get: (k: string) => env[k] } };
  await import('../../supabase/functions/send-complimentary-offer/index.ts');
});

beforeEach(() => {
  vi.clearAllMocks();
  vi.spyOn(console, 'error').mockImplementation(() => {});
  env = { SUPABASE_URL: 'http://db.test', SUPABASE_ANON_KEY: 'anon-key', SUPABASE_SERVICE_ROLE_KEY: 'service-key' };
  getUser = vi.fn(async () => ({ data: { user: { id: 'u1', email: 'mgr@club.example' } }, error: null }));
  serviceRpc = vi.fn(async (fn: string) => (fn === 'comp_offer_issue_link' ? { data: TOKEN, error: null } : { data: true, error: null }));
  userRpc = vi.fn(async () => ({ data: [ROW], error: null }));
  (createClient as any).mockImplementation((_url: string, key: string) => (key === 'service-key' ? { rpc: serviceRpc } : { auth: { getUser }, rpc: userRpc }));
});

const post = (body: unknown, headers: Record<string, string> = { Authorization: 'Bearer user-jwt' }) =>
  handler(new Request('https://fn.test/send-complimentary-offer', { method: 'POST', headers: { 'Content-Type': 'application/json', ...headers }, body: typeof body === 'string' ? body : JSON.stringify(body) }));

describe('the endpoint', () => {
  it('answers a browser preflight', async () => {
    expect((await handler(new Request('https://fn.test/x', { method: 'OPTIONS', headers: { origin: 'https://www.bottlesupapp.com' } }))).status).toBe(200);
  });

  it('only accepts POST', async () => {
    expect((await handler(new Request('https://fn.test/x', { method: 'GET' }))).status).toBe(405);
  });

  it('refuses a request with no sign-in, before doing anything', async () => {
    const res = await post({ offerId: OFFER }, {});
    expect(res.status).toBe(401);
    expect(createClient).not.toHaveBeenCalled();
  });

  it('refuses a session the auth service does not accept, and a person with no session user', async () => {
    getUser.mockResolvedValue({ data: { user: null }, error: { message: 'bad jwt' } });
    expect((await post({ offerId: OFFER })).status).toBe(401);
    getUser.mockResolvedValue({ data: { user: null }, error: null });
    expect((await post({ offerId: OFFER })).status).toBe(401);
    expect(userRpc).not.toHaveBeenCalled();
    expect(serviceRpc).not.toHaveBeenCalled();
  });

  it('refuses a body that is not JSON', async () => {
    const res = await post('{not json');
    expect(res.status).toBe(400);
    expect(userRpc).not.toHaveBeenCalled();
  });

  it('refuses when the service key is not configured, without sending anything', async () => {
    delete env.SUPABASE_SERVICE_ROLE_KEY;
    const res = await post({ offerId: OFFER });
    expect(res.status).toBe(500);
    expect(sendCompOfferEmail).not.toHaveBeenCalled();
    expect(userRpc).not.toHaveBeenCalled();
  });

  it('asks as the person, makes the link and records with the service role, and sends', async () => {
    const res = await post({ offerId: OFFER });
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ sent: true });
    expect(userRpc.mock.calls.map((c) => c[0])).toEqual(['comp_offer_send_begin']);
    expect(serviceRpc.mock.calls.map((c) => c[0])).toEqual(['comp_offer_issue_link', 'comp_offer_send_finish']);
    expect(sendCompOfferEmail).toHaveBeenCalledTimes(1);
    expect((sendCompOfferEmail as any).mock.calls[0][0]).toBe('gina@x.example');
  });

  it('the link goes to the site address from the settings, or the default', async () => {
    await post({ offerId: OFFER });
    expect((sendCompOfferEmail as any).mock.calls[0][3]).toContain(`https://bottlesupapp.com/claim/${TOKEN}`);
    env.SITE_URL = 'https://www.bottlesupapp.com';
    await post({ offerId: OFFER });
    expect((sendCompOfferEmail as any).mock.calls[1][3]).toContain(`https://www.bottlesupapp.com/claim/${TOKEN}`);
  });

  it('never returns the link, even when the e-mail fails', async () => {
    (sendCompOfferEmail as any).mockResolvedValueOnce({ sent: false, reason: 'send_failed' });
    const res = await post({ offerId: OFFER });
    expect(await res.text()).not.toContain(TOKEN);
  });

  it('passes a refusal from the database on, as a sentence', async () => {
    userRpc.mockResolvedValue({ data: null, error: { message: 'not allowed' } });
    const res = await post({ offerId: OFFER });
    expect(res.status).toBe(403);
    expect(await res.json()).toEqual({ error: 'You cannot send this link.' });
    expect(serviceRpc).not.toHaveBeenCalled();
    expect(sendCompOfferEmail).not.toHaveBeenCalled();
  });
});
