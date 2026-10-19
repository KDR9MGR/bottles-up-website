import { beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';

vi.mock('npm:@supabase/supabase-js@2', () => ({ createClient: vi.fn() }));
vi.mock('../../supabase/functions/_shared/outboxEmail.ts', () => ({
  outboxEmailConfigured: vi.fn(() => true),
  sendOutboxEmail: vi.fn(async () => ({ sent: true })),
}));
import { createClient } from 'npm:@supabase/supabase-js@2';
import { outboxEmailConfigured, sendOutboxEmail } from '../../supabase/functions/_shared/outboxEmail.ts';
import { createFakeDb } from './stubs/fakeDb.ts';

const KEY = 'service-role-key-0123456789';
let env: Record<string, string | undefined> = {};
let handler: (req: Request) => Promise<Response>;
let db: ReturnType<typeof createFakeDb>;
let rpc: ReturnType<typeof vi.fn>;

beforeAll(async () => {
  (globalThis as any).Deno = {
    serve: (h: (req: Request) => Promise<Response>) => { handler = h; },
    env: { get: (k: string) => env[k] },
  };
  await import('../../supabase/functions/process-outbox/index.ts');
});

beforeEach(() => {
  vi.clearAllMocks();
  vi.spyOn(console, 'error').mockImplementation(() => {});
  (outboxEmailConfigured as any).mockReturnValue(true);
  env = { SUPABASE_URL: 'http://db.test', SUPABASE_SERVICE_ROLE_KEY: KEY };
  db = createFakeDb({
    site_table_bookings: [{ id: 'b1', customer_email: 'hana@guest.example', customer_name: 'Hana', guest_count: 2, confirmation_code: 'BT-1', table_type: { name: 'Booth' }, venue: { name: 'Club' }, time_slot: { start_time: '22:00:00' } }],
    site_booking_seating: [{ booking_id: 'b1', estimate_minutes: 15 }],
  });
  rpc = vi.fn(async (name: string, _args: any) => {
    if (name === 'outbox_claim') return { data: [{ id: 'm1', kind: 'seated_ack', venue_id: null, ref_id: 'b1', payload: {}, attempts: 1, created_at: new Date().toISOString() }], error: null };
    if (name === 'chat_purge_expired') return { data: 2, error: null };
    return { data: 'sent', error: null };
  });
  (createClient as any).mockReturnValue({ ...db.client, rpc });
});

const post = (headers: Record<string, string> = { Authorization: `Bearer ${KEY}` }, method = 'POST') =>
  handler(new Request('https://fn.test/process-outbox', { method, headers }));

describe('process-outbox', () => {
  it('only accepts POST', async () => {
    expect((await post({ Authorization: `Bearer ${KEY}` }, 'GET')).status).toBe(405);
  });

  it('refuses a request with no key, a wrong key or a key of another length, before touching anything', async () => {
    for (const headers of [{}, { Authorization: 'Bearer ' }, { Authorization: 'Bearer wrong' }, { Authorization: `Bearer ${KEY}x` }, { Authorization: `Bearer ${KEY.slice(0, -1)}` }, { Authorization: `Bearer ${KEY.slice(1)}` }, { Authorization: KEY }]) {
      const res = await post(headers as Record<string, string>);
      expect(res.status).toBe(401);
    }
    expect(createClient).not.toHaveBeenCalled();
    expect(rpc).not.toHaveBeenCalled();
    expect(sendOutboxEmail).not.toHaveBeenCalled();
  });

  it('refuses everything when the service key is not configured, even an empty bearer', async () => {
    env.SUPABASE_SERVICE_ROLE_KEY = undefined;
    expect((await post({ Authorization: 'Bearer ' })).status).toBe(401);
    expect((await post({ Authorization: 'Bearer anything' })).status).toBe(401);
    expect(rpc).not.toHaveBeenCalled();
  });

  it('does not accept an ordinary signed-in user, only the service key', async () => {
    expect((await post({ Authorization: 'Bearer some-user-jwt' })).status).toBe(401);
    expect(rpc).not.toHaveBeenCalled();
  });

  it('claims, sends, records and cleans up, with the service key', async () => {
    const res = await post();
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ claimed: 1, sent: 1, retried: 0, failed: 0, chatPurged: 2 });
    expect(createClient).toHaveBeenCalledWith('http://db.test', KEY);
    expect(rpc).toHaveBeenCalledWith('outbox_claim', { p_limit: 20 });
    expect(sendOutboxEmail).toHaveBeenCalledWith('hana@guest.example', "You're seated at Club", expect.stringContaining('about 15 minutes'), expect.any(String));
    expect(rpc).toHaveBeenCalledWith('outbox_finish', { p_id: 'm1', p_result: 'sent', p_error: null });
    expect(rpc).toHaveBeenCalledWith('chat_purge_expired');
  });

  it('claims nothing and says so when no e-mail provider key is set', async () => {
    (outboxEmailConfigured as any).mockReturnValue(false);
    const body = await (await post()).json();
    expect(body).toMatchObject({ skipped: 'not_configured', claimed: 0 });
    expect(rpc).not.toHaveBeenCalledWith('outbox_claim', expect.anything());
    expect(rpc).toHaveBeenCalledWith('chat_purge_expired');
  });

  it('reports a failed claim in the answer and still cleans up chats', async () => {
    rpc.mockImplementation(async (name: string) => (name === 'outbox_claim' ? { data: null, error: { message: 'db detail' } } : { data: 4, error: null }));
    const res = await post();
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.error).toBe('could not claim messages: outbox_claim failed');
    expect(JSON.stringify(body)).not.toContain('db detail');
    expect(body.chatPurged).toBe(4);
  });

  it('records a refused send as a retry, not a loss', async () => {
    (sendOutboxEmail as any).mockResolvedValueOnce({ sent: false, reason: 'send_failed' });
    const body = await (await post()).json();
    expect(body).toMatchObject({ sent: 0, retried: 1 });
    expect(rpc).toHaveBeenCalledWith('outbox_finish', { p_id: 'm1', p_result: 'retry', p_error: 'the e-mail provider did not accept the message' });
  });

  it('counts a message as not sent when the database will not record it, rather than pretending it went', async () => {
    rpc.mockImplementation(async (name: string) => {
      if (name === 'outbox_claim') return { data: [{ id: 'm1', kind: 'seated_ack', venue_id: null, ref_id: 'b1', payload: {}, attempts: 1, created_at: new Date().toISOString() }], error: null };
      if (name === 'outbox_finish') return { data: null, error: { message: 'db detail' } };
      return { data: 0, error: null };
    });
    const body = await (await post()).json();
    expect(body).toMatchObject({ claimed: 1, sent: 0, retried: 1 });
    expect(JSON.stringify(body)).not.toContain('db detail');
  });

  it('answers a clean 500 with no detail if something unexpected breaks', async () => {
    (createClient as any).mockImplementation(() => { throw new Error('secret internals'); });
    const res = await post();
    expect(res.status).toBe(500);
    expect(await res.json()).toEqual({ error: 'Internal server error' });
  });
});
