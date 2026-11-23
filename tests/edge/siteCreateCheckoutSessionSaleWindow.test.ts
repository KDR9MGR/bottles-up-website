import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';

vi.mock('npm:@supabase/supabase-js@2', () => ({ createClient: vi.fn() }));
const sessionsCreate = vi.fn();
vi.mock('npm:stripe@17', () => {
  class FakeStripe {
    static createFetchHttpClient() { return {}; }
    checkout = { sessions: { create: sessionsCreate } };
    coupons = { create: vi.fn() };
  }
  return { default: FakeStripe };
});
import { createClient } from 'npm:@supabase/supabase-js@2';
import { createFakeDb, type FakeDb } from './stubs/fakeDb.ts';

const EVENT = 'e0000000-0000-0000-0000-000000000001';
const TIER = 'e0000000-0000-0000-0000-000000000002';
let env: Record<string, string | undefined> = {};
let handler: (req: Request) => Promise<Response>;
let db: FakeDb;

beforeAll(async () => {
  (globalThis as any).Deno = { serve: (h: (req: Request) => Promise<Response>) => { handler = h; }, env: { get: (k: string) => env[k] } };
  await import('../../supabase/functions/site-create-checkout-session/index.ts');
});

function seed(tier: Record<string, unknown> = {}) {
  db = createFakeDb({
    site_content: [{ id: 1, payments_mode: 'test' }],
    // the fake does not resolve embedded relations: the event is attached to the tier, as the function's select would return it
    site_ticket_tiers: [{
      id: TIER, event_id: EVENT, name: 'Early Bird', price_cents: 2500, currency: 'cad', capacity: 100, sold_count: 0, requires_access_code: false, is_non_transferable: false,
      events: { id: EVENT, title: 'Friday Night', status: 'published', venue_id: null },
      ...tier,
    }],
    site_orders: [],
  });
  (createClient as any).mockImplementation(() => db.client);
}

beforeEach(() => {
  vi.clearAllMocks();
  vi.spyOn(console, 'error').mockImplementation(() => {});
  vi.useFakeTimers({ toFake: ['Date'] });
  vi.setSystemTime(new Date('2026-12-07T12:00:00Z'));
  env = { SUPABASE_URL: 'http://db.test', SUPABASE_SERVICE_ROLE_KEY: 'service-key', STRIPE_SECRET_KEY_TEST: 'sk_test_x', SITE_URL: 'https://site.test' };
  sessionsCreate.mockResolvedValue({ id: 'cs_1', url: 'https://stripe.test/pay' });
  seed();
});
afterEach(() => vi.useRealTimers());

const post = (body: Record<string, unknown> = {}) =>
  handler(new Request('https://fn.test/site-create-checkout-session', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ event_id: EVENT, tier_id: TIER, quantity: 2, customer_name: 'Ann First', customer_email: 'ann@example.com', ...body }),
  }));

describe('site-create-checkout-session: a ticket type is bought only inside its sales window', () => {
  it('a ticket type with no dates is bought as always', async () => {
    const res = await post();
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ url: 'https://stripe.test/pay' });
    expect(db.tables.site_orders).toHaveLength(1);
    expect(sessionsCreate).toHaveBeenCalledTimes(1);
  });

  it('before sales open: refused with the day they open, nothing is written, Stripe is not asked', async () => {
    seed({ sale_starts_at: '2026-12-08T19:00:00Z' });
    const res = await post();
    expect(res.status).toBe(409);
    expect(await res.json()).toEqual({ error: 'Ticket sales for this ticket type have not opened yet.', code: 'sales_not_started', opens_at: '2026-12-08T19:00:00.000Z' });
    expect(db.tables.site_orders).toEqual([]);
    expect(sessionsCreate).not.toHaveBeenCalled();
  });

  it('after sales end: refused, nothing is written, Stripe is not asked', async () => {
    seed({ sale_ends_at: '2026-12-07T11:59:59Z' });
    const res = await post();
    expect(res.status).toBe(409);
    expect(await res.json()).toEqual({ error: 'Ticket sales for this ticket type have ended.', code: 'sales_ended', closed_at: '2026-12-07T11:59:59.000Z' });
    expect(db.tables.site_orders).toEqual([]);
    expect(sessionsCreate).not.toHaveBeenCalled();
  });

  it('inside the window it is bought', async () => {
    seed({ sale_starts_at: '2026-12-05T19:00:00Z', sale_ends_at: '2026-12-10T22:00:00Z' });
    const res = await post();
    expect(res.status).toBe(200);
    expect(db.tables.site_orders).toHaveLength(1);
  });

  it('on the very second sales open it is bought; on the very second they end it is not', async () => {
    seed({ sale_starts_at: '2026-12-07T12:00:00Z' });
    expect((await post()).status).toBe(200);
    seed({ sale_ends_at: '2026-12-07T12:00:00Z' });
    expect((await post()).status).toBe(409);
  });

  it('the window cannot be got round by saying so: whatever the client sends, the row\'s own dates decide', async () => {
    seed({ sale_ends_at: '2026-12-01T00:00:00Z' });
    const res = await post({ sale_ends_at: null, sale_starts_at: null, ignore_window: true, access_code: 'x' });
    expect(res.status).toBe(409);
  });

  it('the window is checked before the other rules, so a closed type never reaches the capacity or promo steps', async () => {
    seed({ sale_ends_at: '2026-12-01T00:00:00Z', capacity: 1, sold_count: 1 });
    const res = await post({ quantity: 5, promo_code: 'WHATEVER' });
    expect(res.status).toBe(409);
    expect((await res.json()).code).toBe('sales_ended');
  });

  it('an event that is not published is still refused first, with its own message', async () => {
    seed({ events: { id: EVENT, title: 'Friday Night', status: 'draft', venue_id: null }, sale_ends_at: '2026-12-01T00:00:00Z' });
    const res = await post();
    expect(res.status).toBe(400);
    expect(await res.json()).toEqual({ error: 'This event is not currently on sale' });
  });
});
