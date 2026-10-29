import { beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';

vi.mock('npm:@supabase/supabase-js@2', () => ({ createClient: vi.fn() }));
const sessionsCreate = vi.fn();
const couponsCreate = vi.fn();
vi.mock('npm:stripe@17', () => {
  class FakeStripe {
    static createFetchHttpClient() { return {}; }
    checkout = { sessions: { create: sessionsCreate } };
    coupons = { create: couponsCreate };
  }
  return { default: FakeStripe };
});
import { createClient } from 'npm:@supabase/supabase-js@2';
import { createFakeDb, type FakeDb } from './stubs/fakeDb.ts';

const VENUE = 'a0000000-0000-0000-0000-000000000001';
const TYPE = 'a0000000-0000-0000-0000-000000000002';
const SLOT = 'a0000000-0000-0000-0000-000000000003';
const LATE_SLOT = 'a0000000-0000-0000-0000-000000000004';
const BOTTLE = 'a0000000-0000-0000-0000-000000000005';
const BOOKING = 'b0000000-0000-0000-0000-0000000000f1';
let env: Record<string, string | undefined> = {};
let handler: (req: Request) => Promise<Response>;
let db: FakeDb;
// what site_reserve_table_booking answers: { data, error }
let reserveAnswer: { data: unknown; error: unknown };
// what site_table_taken_count answers for the early check
let taken: number;

beforeAll(async () => {
  (globalThis as any).Deno = { serve: (h: (req: Request) => Promise<Response>) => { handler = h; }, env: { get: (k: string) => env[k] } };
  await import('../../supabase/functions/create-table-booking-checkout/index.ts');
});

function seed(opts: { venueMode?: 'pay_ahead' | 'pay_at_club' | 'both'; type?: Record<string, unknown> } = {}) {
  db = createFakeDb({
    site_content: [{ id: 1, payments_mode: 'test', bottlesup_fee_bps: 500 }],
    // the fake does not resolve embedded relations: the venue is attached to the table type, as the function's select would return it
    site_table_types: [{
      id: TYPE, venue_id: VENUE, name: 'Gold', max_guests: 6, deposit_cents: 10000, currency: 'cad', inventory_count: 1, pricing_mode: 'flat',
      venue: { id: VENUE, name: 'Club A', status: 'published', booking_start_date: null, booking_end_date: null, tax_rate_bps: 1300, bottle_payment_mode: opts.venueMode ?? 'pay_ahead', deposit_is_credit: false },
      ...opts.type,
    }],
    site_venue_time_slots: [
      { id: SLOT, venue_id: VENUE, day_of_week: 6, start_time: '21:00:00' },
      { id: LATE_SLOT, venue_id: VENUE, day_of_week: 6, start_time: '01:00:00' },
    ],
    site_bottles: [{ id: BOTTLE, venue_id: VENUE, name: 'Vodka', size: '750ml', price_cents: 5000, currency: 'cad', is_available: true, is_sold_out: false, stock_quantity: null }],
    site_table_bookings: [],
    site_table_booking_bottles: [],
  });
  db.rpcHandlers = { site_table_taken_count: () => taken };
  const client = { ...db.client, rpc: (name: string, args: unknown) => (name === 'site_reserve_table_booking' ? (db.rpcCalls.push({ name, args }), Promise.resolve(reserveAnswer)) : db.client.rpc(name, args)) };
  (createClient as any).mockImplementation(() => client);
}

beforeEach(() => {
  vi.clearAllMocks();
  vi.spyOn(console, 'error').mockImplementation(() => {});
  env = { SUPABASE_URL: 'http://db.test', SUPABASE_SERVICE_ROLE_KEY: 'service-key', STRIPE_SECRET_KEY_TEST: 'sk_test_x', SITE_URL: 'https://site.test' };
  reserveAnswer = { data: BOOKING, error: null };
  taken = 0;
  sessionsCreate.mockResolvedValue({ id: 'cs_1', url: 'https://stripe.test/pay' });
  couponsCreate.mockResolvedValue({ id: 'co_1' });
  seed();
});

const request = (over: Record<string, unknown> = {}) => ({
  venue_id: VENUE, table_type_id: TYPE, time_slot_id: SLOT, booking_date: '2026-11-14', guest_count: 4,
  customer_name: 'Ann First', customer_email: 'ann@example.com', customer_phone: '+1 555 0100', ...over,
});
const post = (body: unknown) =>
  handler(new Request('https://fn.test/create-table-booking-checkout', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) }));
const reserveArgs = () => db.rpcCalls.find((c) => c.name === 'site_reserve_table_booking')?.args;

describe('create-table-booking-checkout: the table is taken in one step, then the guest pays', () => {
  it('reserves with the prices the DATABASE gave, then starts Stripe for that booking', async () => {
    const res = await post(request());
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ url: 'https://stripe.test/pay' });
    // deposit 100.00 + 13% tax (13.00) + BottlesUp's 5% (5.00) = 118.00
    expect(reserveArgs()).toEqual({
      p_venue: VENUE, p_table_type: TYPE, p_slot: SLOT, p_arrival: '2026-11-14',
      p_customer_name: 'Ann First', p_customer_email: 'ann@example.com', p_customer_phone: '+1 555 0100',
      p_guests: 4, p_hours: null,
      p_deposit_cents: 10000, p_bottle_subtotal_cents: 0, p_tax_cents: 1300, p_fee_cents: 500, p_total_cents: 11800,
      p_bottle_payment_choice: 'pay_ahead', p_currency: 'cad', p_promo_code_id: null, p_discount_cents: 0, p_sign_text: null,
    });
    expect(sessionsCreate).toHaveBeenCalledTimes(1);
    expect(sessionsCreate.mock.calls[0][0].metadata).toEqual({ booking_id: BOOKING });
    expect(db.tables.site_table_bookings).toEqual([]); // the function itself writes no booking row: the database function did
  });

  it('the client cannot choose the price: whatever it sends, the table type\'s own deposit is used', async () => {
    await post(request({ deposit_cents: 1, amount_total_cents: 1, price: 1 }));
    expect(reserveArgs()).toMatchObject({ p_deposit_cents: 10000, p_total_cents: 11800 });
  });

  it('an after-midnight arrival is booked on the next calendar day', async () => {
    await post(request({ time_slot_id: LATE_SLOT }));
    expect(reserveArgs()).toMatchObject({ p_slot: LATE_SLOT, p_arrival: '2026-11-15' });
  });

  it('the sign text is trimmed to 24 characters', async () => {
    await post(request({ bottle_sign_text: '   Happy Birthday to the best friend ever   ' }));
    expect((reserveArgs() as any).p_sign_text).toBe('Happy Birthday to the be');
  });

  it('an hourly table is priced by the hours asked for', async () => {
    seed({ type: { pricing_mode: 'hourly', hourly_rate_cents: 4000, min_hours: 2 } });
    await post(request({ hours: 3 }));
    expect(reserveArgs()).toMatchObject({ p_hours: 3, p_deposit_cents: 12000, p_tax_cents: 1560, p_fee_cents: 600, p_total_cents: 14160 });
  });

  it('bottles paid online are added to the total and written for the booking the database made', async () => {
    await post(request({ bottles: [{ bottle_id: BOTTLE, quantity: 2 }] }));
    // 100.00 + 2 x 50.00 = 200.00; tax 26.00; fee 10.00
    expect(reserveArgs()).toMatchObject({ p_bottle_subtotal_cents: 10000, p_tax_cents: 2600, p_fee_cents: 1000, p_total_cents: 23600, p_bottle_payment_choice: 'pay_ahead' });
    expect(db.tables.site_table_booking_bottles).toEqual([
      { id: 'fake-site_table_booking_bottles-1', booking_id: BOOKING, bottle_id: BOTTLE, bottle_name: 'Vodka', size: '750ml', unit_price_cents: 5000, quantity: 2, line_total_cents: 10000, payment_status: 'paid' },
    ]);
  });

  it('bottles paid at the club are recorded but only the deposit is charged now; the rest is due at the club', async () => {
    seed({ venueMode: 'both' });
    await post(request({ bottles: [{ bottle_id: BOTTLE, quantity: 2 }], bottle_payment_choice: 'pay_at_club' }));
    expect(reserveArgs()).toMatchObject({ p_bottle_subtotal_cents: 10000, p_tax_cents: 1300, p_fee_cents: 500, p_total_cents: 21800, p_bottle_payment_choice: 'pay_at_club' });
    expect(db.tables.site_table_booking_bottles[0]).toMatchObject({ booking_id: BOOKING, payment_status: 'due_at_venue' });
  });
});

describe('create-table-booking-checkout: when no table can be reserved the guest is never sent to pay', () => {
  it('the database says none is left (the last table went a moment ago): 409, no bottle lines, no Stripe', async () => {
    reserveAnswer = { data: null, error: null };
    const res = await post(request({ bottles: [{ bottle_id: BOTTLE, quantity: 1 }] }));
    expect(res.status).toBe(409);
    expect(await res.json()).toEqual({ error: 'No tables of this type left for that date and time' });
    expect(db.tables.site_table_booking_bottles).toEqual([]);
    expect(sessionsCreate).not.toHaveBeenCalled();
  });

  it('the early check already sees none left: 409 and the reservation is not even tried', async () => {
    taken = 1;
    const res = await post(request());
    expect(res.status).toBe(409);
    expect(reserveArgs()).toBeUndefined();
    expect(sessionsCreate).not.toHaveBeenCalled();
  });

  it('the database fails: 500, no bottle lines, no Stripe, and the cause stays in the log, not the answer', async () => {
    reserveAnswer = { data: null, error: { code: '57014', message: 'canceling statement due to statement timeout' } };
    const res = await post(request({ bottles: [{ bottle_id: BOTTLE, quantity: 1 }] }));
    expect(res.status).toBe(500);
    expect(await res.json()).toEqual({ error: 'Failed to start booking' });
    expect(db.tables.site_table_booking_bottles).toEqual([]);
    expect(sessionsCreate).not.toHaveBeenCalled();
  });

  it('before the migration is applied the plain insert is used, so bookings keep working', async () => {
    reserveAnswer = { data: null, error: { code: 'PGRST202', message: 'Could not find the function public.site_reserve_table_booking' } };
    const res = await post(request());
    expect(res.status).toBe(200);
    expect(db.tables.site_table_bookings).toHaveLength(1);
    expect(db.tables.site_table_bookings[0]).toMatchObject({ status: 'pending', deposit_cents: 10000, amount_total_cents: 11800, customer_email: 'ann@example.com' });
    expect(sessionsCreate.mock.calls[0][0].metadata).toEqual({ booking_id: db.tables.site_table_bookings[0].id });
  });

  it('a request that is missing what it needs never reaches the database', async () => {
    const res = await post(request({ customer_email: '' }));
    expect(res.status).toBe(400);
    expect(db.rpcCalls).toEqual([]);
  });
});
