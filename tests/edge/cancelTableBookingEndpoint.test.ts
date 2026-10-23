import { beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';

vi.mock('npm:@supabase/supabase-js@2', () => ({ createClient: vi.fn() }));
import { createClient } from 'npm:@supabase/supabase-js@2';
import { createFakeDb, type FakeDb } from './stubs/fakeDb.ts';

const BOOKING = 'b0000000-0000-0000-0000-000000000001';
let env: Record<string, string | undefined> = {};
let handler: (req: Request) => Promise<Response>;
let db: FakeDb;
let rpc: ReturnType<typeof vi.fn>;
let user: { id: string; email: string | null };

beforeAll(async () => {
  (globalThis as any).Deno = { serve: (h: (req: Request) => Promise<Response>) => { handler = h; }, env: { get: (k: string) => env[k] } };
  await import('../../supabase/functions/cancel-table-booking/index.ts');
});

function seed(extra: Record<string, any[]> = {}) {
  db = createFakeDb({
    cms_admins: [], door_staff: [],
    site_table_bookings: [{ id: BOOKING, status: 'paid', amount_paid_cents: 0 }],
    site_table_booking_bottles: [],
    audit_log: [],
    ...extra,
  });
  // the function builds two clients: one with the caller's own login (anon key) and one with the service key
  (createClient as any).mockImplementation((_url: string, key: string) =>
    key === 'anon-key' ? { auth: { getUser: async () => ({ data: { user }, error: null }) }, rpc } : db.client);
}

beforeEach(() => {
  vi.clearAllMocks();
  vi.spyOn(console, 'error').mockImplementation(() => {});
  env = { SUPABASE_URL: 'http://db.test', SUPABASE_ANON_KEY: 'anon-key', SUPABASE_SERVICE_ROLE_KEY: 'service-key' };
  user = { id: 'u1', email: 'someone@club.example' };
  rpc = vi.fn(async () => ({ data: true, error: null }));
  seed();
});

const post = (body: unknown, headers: Record<string, string> = { Authorization: 'Bearer user-jwt' }) =>
  handler(new Request('https://fn.test/cancel-table-booking', { method: 'POST', headers: { 'Content-Type': 'application/json', ...headers }, body: JSON.stringify(body) }));
const cancelled = () => db.tables.site_table_bookings[0].status === 'cancelled';

describe('cancel-table-booking: who may cancel', () => {
  it('refuses a request with no sign-in', async () => {
    expect((await post({ booking_id: BOOKING, reason: 'Guest cancelled' }, {})).status).toBe(401);
    expect(createClient).not.toHaveBeenCalled();
  });

  it('a BottlesUp admin cancels, without asking the club check', async () => {
    seed({ cms_admins: [{ id: 'u1', email: 'admin@bottlesup.example' }] });
    const res = await post({ booking_id: BOOKING, reason: 'Guest cancelled' });
    expect(res.status).toBe(200);
    expect(cancelled()).toBe(true);
    expect(rpc).not.toHaveBeenCalled();
    expect(db.tables.audit_log[0].actor_email).toBe('admin@bottlesup.example');
  });

  it('website door staff cancel, as before', async () => {
    seed({ door_staff: [{ id: 'u1', email: 'door@bottlesup.example' }] });
    expect((await post({ booking_id: BOOKING, reason: 'Guest cancelled' })).status).toBe(200);
    expect(cancelled()).toBe(true);
    expect(rpc).not.toHaveBeenCalled();
  });

  it('a club\'s manager or owner cancels, when the DATABASE says so with their own login; they are the actor in the log', async () => {
    const res = await post({ booking_id: BOOKING, reason: 'Guest cancelled' });
    expect(res.status).toBe(200);
    expect(rpc).toHaveBeenCalledWith('desk_may_cancel_booking', { p_booking: BOOKING });
    expect(cancelled()).toBe(true);
    expect(db.tables.audit_log[0]).toMatchObject({ actor_id: 'u1', actor_email: 'someone@club.example', action: 'table_booking.cancelled' });
  });

  it('anyone the database does not allow (a server, another club\'s manager, a stranger) is refused and nothing changes', async () => {
    rpc = vi.fn(async () => ({ data: null, error: { code: 'P0001', message: 'not allowed' } }));
    seed();
    const res = await post({ booking_id: BOOKING, reason: 'Guest cancelled' });
    expect(res.status).toBe(403);
    expect(cancelled()).toBe(false);
    expect(db.tables.audit_log).toHaveLength(0);
  });

  it('a failure of the check itself is a refusal, never an acceptance', async () => {
    rpc = vi.fn(async () => ({ data: null, error: { code: '42883', message: 'function desk_may_cancel_booking does not exist' } }));
    seed();
    expect((await post({ booking_id: BOOKING, reason: 'Guest cancelled' })).status).toBe(403);
    expect(cancelled()).toBe(false);
  });

  it('a booking that is already cancelled is not cancelled twice', async () => {
    seed({ site_table_bookings: [{ id: BOOKING, status: 'cancelled', amount_paid_cents: 0 }] });
    expect((await post({ booking_id: BOOKING, reason: 'Guest cancelled' })).status).toBe(400);
    expect(db.tables.audit_log).toHaveLength(0);
  });

  it('needs a booking and a reason', async () => {
    expect((await post({ reason: 'Guest cancelled' })).status).toBe(400);
    expect((await post({ booking_id: BOOKING, reason: '  ' })).status).toBe(400);
  });
});
