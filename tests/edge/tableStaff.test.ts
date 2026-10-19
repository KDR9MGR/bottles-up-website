import { beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';

vi.mock('npm:@supabase/supabase-js@2', () => ({ createClient: vi.fn() }));
vi.mock('../../supabase/functions/_shared/bottleOrdering.ts', () => ({ addBottlesToBooking: vi.fn(async () => ({ status: 200, body: { success: true, mode: 'due_at_venue' } })) }));
import { createClient } from 'npm:@supabase/supabase-js@2';
import { addBottlesToBooking } from '../../supabase/functions/_shared/bottleOrdering.ts';
import { tableStaffVerdict } from '../../supabase/functions/_shared/tableStaff.ts';
import { createFakeDb } from './stubs/fakeDb.ts';

describe('tableStaffVerdict: what the database\'s answer means for the endpoint', () => {
  it('no error means table staff', () => {
    expect(tableStaffVerdict(null)).toEqual({ kind: 'staff' });
    expect(tableStaffVerdict(undefined)).toEqual({ kind: 'staff' });
  });

  it('the database\'s "not allowed" and "not authenticated" mean "not table staff", so the customer rules go on as before', () => {
    for (const message of ['not allowed', 'Not allowed', 'not allowed.', 'not authenticated', ' not authenticated ']) {
      expect(tableStaffVerdict({ code: 'P0001', message })).toEqual({ kind: 'customer' });
    }
  });

  it('any other plain sentence is a reason, said as it is: the person is table staff, but not now', () => {
    for (const message of ['this table has already been closed out', 'this night has been closed, so no bottles can be added', 'only a confirmed booking can have bottles added']) {
      expect(tableStaffVerdict({ code: 'P0001', message })).toEqual({ kind: 'refused', message });
    }
  });

  it('a sentence that only CONTAINS "not allowed" is a reason, not a lack of access', () => {
    expect(tableStaffVerdict({ code: 'P0001', message: 'bottles are not allowed on a closed table' })).toEqual({ kind: 'refused', message: 'bottles are not allowed on a closed table' });
  });

  it('anything that is not one of the database\'s own sentences is never "staff": a missing function, a dropped connection, no message', () => {
    expect(tableStaffVerdict({ code: '42883', message: 'function public.desk_may_add_bottles(uuid) does not exist' })).toEqual({ kind: 'customer' });
    expect(tableStaffVerdict({ code: 'PGRST202', message: 'Could not find the function' })).toEqual({ kind: 'customer' });
    expect(tableStaffVerdict({ message: 'fetch failed' })).toEqual({ kind: 'customer' });
    expect(tableStaffVerdict({ code: 'P0001', message: '' })).toEqual({ kind: 'customer' });
    expect(tableStaffVerdict({ code: 'P0001', message: null })).toEqual({ kind: 'customer' });
    expect(tableStaffVerdict({ code: 'P0001' })).toEqual({ kind: 'customer' });
  });
});

let handler: (req: Request) => Promise<Response>;
let env: Record<string, string | undefined> = {};
let db: ReturnType<typeof createFakeDb>;
let anonRpc: ReturnType<typeof vi.fn>;
let created: { key: string; options?: any }[] = [];

beforeAll(async () => {
  (globalThis as any).Deno = { serve: (h: (req: Request) => Promise<Response>) => { handler = h; }, env: { get: (k: string) => env[k] } };
  await import('../../supabase/functions/add-table-booking-bottles/index.ts');
});

beforeEach(() => {
  vi.clearAllMocks();
  vi.spyOn(console, 'error').mockImplementation(() => {});
  env = { SUPABASE_URL: 'http://db.test', SUPABASE_ANON_KEY: 'anon-key', SUPABASE_SERVICE_ROLE_KEY: 'service-key' };
  db = createFakeDb({
    cms_admins: [],
    door_staff: [],
    site_table_bookings: [{ id: 'b1', customer_email: 'owner@guest.example' }],
  });
  anonRpc = vi.fn(async () => ({ data: true, error: null }));
  created = [];
  (createClient as any).mockImplementation((_url: string, key: string, options?: any) => {
    created.push({ key, options });
    if (key === 'anon-key') return { auth: { getUser: async () => ({ data: { user: { id: 'u1', email: 'caller@club.example' } }, error: null }) }, rpc: anonRpc };
    return db.client;
  });
});

const call = (body: Record<string, unknown> = { booking_id: 'b1', bottles: [{ bottle_id: 'x', quantity: 2 }] }, headers: Record<string, string> = { Authorization: 'Bearer user-jwt' }) =>
  handler(new Request('https://fn.test/add-table-booking-bottles', { method: 'POST', headers, body: JSON.stringify(body) }));

describe('add-table-booking-bottles: who may add', () => {
  it('needs a signed-in caller', async () => {
    expect((await call(undefined, {})).status).toBe(401);
    expect(addBottlesToBooking).not.toHaveBeenCalled();
  });

  it('a server or manager of the table (the database says yes) adds as staff, settled at the club, and the question is asked with the caller\'s own login', async () => {
    const res = await call();
    expect(res.status).toBe(200);
    expect(anonRpc).toHaveBeenCalledWith('desk_may_add_bottles', { p_booking: 'b1' });
    const anon = created.find((c) => c.key === 'anon-key')!;
    expect(anon.options.global.headers.Authorization).toBe('Bearer user-jwt');
    expect(addBottlesToBooking).toHaveBeenCalledWith(expect.anything(), expect.objectContaining({ bookingId: 'b1', isStaff: true, actorId: 'u1', actorEmail: 'caller@club.example', bottleRequests: [{ bottle_id: 'x', quantity: 2 }] }));
  });

  it('door staff and administrators are staff as before, without asking the database', async () => {
    db.tables.door_staff.push({ id: 'u1' });
    expect((await call()).status).toBe(200);
    expect(anonRpc).not.toHaveBeenCalled();
    expect(addBottlesToBooking).toHaveBeenCalledWith(expect.anything(), expect.objectContaining({ isStaff: true }));
    vi.clearAllMocks();
    db.tables.door_staff.length = 0;
    db.tables.cms_admins.push({ id: 'u1' });
    expect((await call()).status).toBe(200);
    expect(anonRpc).not.toHaveBeenCalled();
    expect(addBottlesToBooking).toHaveBeenCalledWith(expect.anything(), expect.objectContaining({ isStaff: true }));
  });

  it('a table that is closed out, or a night that is closed, is refused with the database\'s own sentence and nothing is added', async () => {
    for (const message of ['this table has already been closed out', 'this night has been closed, so no bottles can be added']) {
      anonRpc.mockResolvedValueOnce({ data: null, error: { code: 'P0001', message } });
      const res = await call();
      expect(res.status).toBe(409);
      expect(await res.json()).toEqual({ error: message });
    }
    expect(addBottlesToBooking).not.toHaveBeenCalled();
  });

  it('a person who is not table staff goes on as a customer: their own booking is allowed, as staff = false', async () => {
    anonRpc.mockResolvedValue({ data: null, error: { code: 'P0001', message: 'not allowed' } });
    db.tables.site_table_bookings[0].customer_email = 'Caller@Club.example';
    const res = await call();
    expect(res.status).toBe(200);
    expect(addBottlesToBooking).toHaveBeenCalledWith(expect.anything(), expect.objectContaining({ isStaff: false }));
  });

  it('...and someone else\'s booking is Forbidden, exactly as before', async () => {
    anonRpc.mockResolvedValue({ data: null, error: { code: 'P0001', message: 'not allowed' } });
    const res = await call();
    expect(res.status).toBe(403);
    expect(addBottlesToBooking).not.toHaveBeenCalled();
  });

  it('a database that does not have the function yet behaves as before: a customer\'s own booking works, nobody becomes staff', async () => {
    anonRpc.mockResolvedValue({ data: null, error: { code: '42883', message: 'function desk_may_add_bottles does not exist' } });
    expect((await call()).status).toBe(403);
    db.tables.site_table_bookings[0].customer_email = 'caller@club.example';
    expect((await call()).status).toBe(200);
    expect(addBottlesToBooking).toHaveBeenLastCalledWith(expect.anything(), expect.objectContaining({ isStaff: false }));
  });

  it('a failed question never makes anyone staff', async () => {
    anonRpc.mockResolvedValue({ data: null, error: { message: 'fetch failed' } });
    expect((await call()).status).toBe(403);
    expect(addBottlesToBooking).not.toHaveBeenCalled();
  });

  it('still refuses a request with no bottles or a bad quantity before asking anything', async () => {
    expect((await call({ booking_id: 'b1', bottles: [] })).status).toBe(400);
    expect((await call({ booking_id: 'b1', bottles: [{ bottle_id: 'x', quantity: 0 }] })).status).toBe(400);
    expect((await call({ booking_id: 'b1', bottles: [{ bottle_id: 'x', quantity: 1.5 }] })).status).toBe(400);
    expect((await call({ bottles: [{ bottle_id: 'x', quantity: 1 }] })).status).toBe(400);
    expect(anonRpc).not.toHaveBeenCalled();
  });
});
