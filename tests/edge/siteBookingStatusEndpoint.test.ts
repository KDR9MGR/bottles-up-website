import { beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';

vi.mock('npm:@supabase/supabase-js@2', () => ({ createClient: vi.fn() }));
const sessionRetrieve = vi.fn();
vi.mock('npm:stripe@17', () => {
  class FakeStripe {
    static createFetchHttpClient() { return {}; }
    checkout = { sessions: { retrieve: sessionRetrieve } };
  }
  return { default: FakeStripe };
});
const fulfillTableBooking = vi.fn(async () => {});
vi.mock('../../supabase/functions/_shared/fulfillment.ts', () => ({ fulfillTicketOrder: vi.fn(async () => {}), fulfillTableBooking }));
import { createClient } from 'npm:@supabase/supabase-js@2';
import { createFakeDb, type FakeDb } from './stubs/fakeDb.ts';

let handler: (req: Request) => Promise<Response>;
let db: FakeDb;
let conflictsAnswer: { data: unknown; error: unknown } | null;

beforeAll(async () => {
  (globalThis as any).Deno = { serve: (h: (req: Request) => Promise<Response>) => { handler = h; }, env: { get: () => undefined } };
  await import('../../supabase/functions/site-booking-status/index.ts');
});

const paidBooking = (over: Record<string, unknown> = {}) => ({
  id: 'b1', status: 'paid', confirmation_code: 'BT-ABC12345', customer_name: 'Ada', customer_email: 'ada@example.com', guest_count: 4, booking_date: '2026-11-14',
  deposit_cents: 10000, bottle_subtotal_cents: 0, tax_cents: 1300, bottlesup_fee_cents: 500, discount_cents: 0, amount_total_cents: 11800, amount_paid_cents: 11800, currency: 'cad',
  stripe_checkout_session_id: 'cs_test_1',
  site_table_types: { name: 'Gold' }, site_venues: { name: 'Club A' }, site_venue_time_slots: { start_time: '21:00:00' },
  ...over,
});

function seed(conflicts: Record<string, unknown>[] = [], booking = paidBooking()) {
  db = createFakeDb({ site_orders: [], site_table_bookings: [booking], site_table_booking_bottles: [], site_booking_conflicts: conflicts });
  // a client whose conflicts table can be made to fail like a missing or unreadable table
  const client = {
    ...db.client,
    from: (t: string) => {
      if (t === 'site_booking_conflicts' && conflictsAnswer) {
        const chain: any = { select: () => chain, eq: () => chain, maybeSingle: () => Promise.resolve(conflictsAnswer) };
        return chain;
      }
      return db.client.from(t);
    },
  };
  (createClient as any).mockImplementation(() => client);
}

beforeEach(() => {
  vi.clearAllMocks();
  vi.spyOn(console, 'error').mockImplementation(() => {});
  conflictsAnswer = null;
  seed();
});

const ask = (sessionId: unknown = 'cs_test_1') =>
  handler(new Request('https://fn.test/site-booking-status', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ session_id: sessionId }) }));

describe('site-booking-status: a paid table booking', () => {
  it('shows the confirmation of a booking nobody has a claim on', async () => {
    const res = await ask();
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.status).toBe('paid');
    expect(body.booking).toMatchObject({ confirmationCode: 'BT-ABC12345', customerEmail: 'ada@example.com', tableTypeName: 'Gold', venueName: 'Club A', totalCents: 11800, paidNowCents: 11800 });
  });

  it('HELD: with an open conflict the guest gets "held" and NOTHING that promises a table (no code, no booking, no e-mail address)', async () => {
    seed([{ id: 'k1', booking_id: 'b1', status: 'open' }]);
    const res = await ask();
    expect(res.status).toBe(200);
    const text = await res.text();
    expect(JSON.parse(text)).toEqual({ status: 'held' });
    expect(text).not.toContain('BT-ABC12345');
  });

  it('a conflict the manager has dealt with no longer holds it back', async () => {
    seed([{ id: 'k1', booking_id: 'b1', status: 'resolved' }]);
    expect((await (await ask()).json()).status).toBe('paid');
  });

  it('another booking\'s conflict does not hold this one back', async () => {
    seed([{ id: 'k2', booking_id: 'someone-else', status: 'open' }]);
    expect((await (await ask()).json()).status).toBe('paid');
  });

  it('before the migration is applied (no conflicts table) nothing changes', async () => {
    conflictsAnswer = { data: null, error: { code: 'PGRST205', message: 'Could not find the table public.site_booking_conflicts in the schema cache' } };
    seed();
    expect((await (await ask()).json()).status).toBe('paid');
  });

  it('if the conflicts cannot be read the guest is NOT shown a confirmation: the page keeps saying it is still confirming', async () => {
    conflictsAnswer = { data: null, error: { code: '42501', message: 'permission denied for table site_booking_conflicts' } };
    seed();
    const res = await ask();
    expect(res.status).toBe(500);
    expect(await res.json()).toEqual({ error: 'Internal server error' });
  });

  it('a booking not paid yet gets its status and no booking', async () => {
    seed([], paidBooking({ status: 'pending', confirmation_code: null }));
    sessionRetrieve.mockResolvedValue({ payment_status: 'unpaid' });
    expect(await (await ask()).json()).toEqual({ status: 'pending' });
  });

  it('a missing session id is refused', async () => {
    expect((await ask(null)).status).toBe(400);
  });
});
