import { describe, expect, it } from 'vitest';
import { validatePromoCode } from '../../supabase/functions/_shared/promoCode.ts';
import { createFakeDb } from './stubs/fakeDb';

const DAY = 24 * 60 * 60 * 1000;
const iso = (offsetMs: number) => new Date(Date.now() + offsetMs).toISOString();

const promo = (over: Record<string, unknown> = {}) => ({
  id: 'p1', code: 'SAVE10', discount_type: 'percentage', discount_value: 10, applies_to: 'both',
  max_uses: null, used_count: 0, min_purchase_cents: null, starts_at: null, expires_at: null, is_active: true,
  ...over,
});
const check = (
  row: Record<string, unknown> | null,
  opts: Partial<{ code: string; appliesTo: 'tickets' | 'tables'; venueId: string | null; subtotalCents: number }> = {},
  venueLinks: string[] = [],
) => {
  const db = createFakeDb({
    promo_codes: row ? [row] : [],
    promo_code_venues: venueLinks.map((venue_id) => ({ promo_code_id: 'p1', venue_id })),
  });
  return validatePromoCode(db.client, { code: 'SAVE10', appliesTo: 'tickets', venueId: null, subtotalCents: 10000, ...opts });
};

describe('validatePromoCode: is the code usable?', () => {
  it('accepts a normal code', async () => {
    expect(await check(promo())).toEqual({ valid: true, message: 'Promo code applied', promoCodeId: 'p1', discountCents: 1000 });
  });
  it('an empty or whitespace code is rejected before touching the database', async () => {
    expect((await check(promo(), { code: '   ' })).valid).toBe(false);
  });
  it('trims and upper-cases what the customer typed', async () => {
    expect((await check(promo(), { code: '  save10 ' })).valid).toBe(true);
  });
  it('rejects an unknown code', async () => {
    expect(await check(null)).toMatchObject({ valid: false, message: 'Invalid promo code' });
  });
  it('rejects an inactive code', async () => {
    expect(await check(promo({ is_active: false }))).toMatchObject({ valid: false, message: 'This promo code is no longer active' });
  });
  it('rejects a code that has not started, and one that has expired', async () => {
    expect(await check(promo({ starts_at: iso(DAY) }))).toMatchObject({ valid: false, message: 'This promo code is not active yet' });
    expect(await check(promo({ expires_at: iso(-DAY) }))).toMatchObject({ valid: false, message: 'This promo code has expired' });
  });
  it('accepts a code inside its window', async () => {
    expect((await check(promo({ starts_at: iso(-DAY), expires_at: iso(DAY) }))).valid).toBe(true);
  });
  it('usage limit: the last use is allowed, the next one is not', async () => {
    expect((await check(promo({ max_uses: 5, used_count: 4 }))).valid).toBe(true);
    expect(await check(promo({ max_uses: 5, used_count: 5 }))).toMatchObject({ valid: false, message: 'This promo code has reached its usage limit' });
  });
  it('a code for tickets does not work on tables, and the message says which', async () => {
    expect(await check(promo({ applies_to: 'tickets' }), { appliesTo: 'tables' })).toMatchObject({ valid: false, message: "This promo code doesn't apply to table bookings" });
    expect(await check(promo({ applies_to: 'tables' }), { appliesTo: 'tickets' })).toMatchObject({ valid: false, message: "This promo code doesn't apply to event tickets" });
    expect((await check(promo({ applies_to: 'both' }), { appliesTo: 'tables' })).valid).toBe(true);
  });
  it('minimum purchase: just under is rejected (with the amount shown), exactly at it is accepted', async () => {
    expect(await check(promo({ min_purchase_cents: 5000 }), { subtotalCents: 4999 })).toMatchObject({ valid: false, message: 'This promo code requires a minimum purchase of $50.00' });
    expect((await check(promo({ min_purchase_cents: 5000 }), { subtotalCents: 5000 })).valid).toBe(true);
  });
});

describe('validatePromoCode: venue scoping', () => {
  it('a code with no venue links works everywhere', async () => {
    expect((await check(promo(), { venueId: 'any-venue' }, [])).valid).toBe(true);
  });
  it('a venue-scoped code works at its venue only', async () => {
    expect((await check(promo(), { venueId: 'v1' }, ['v1', 'v2'])).valid).toBe(true);
    expect(await check(promo(), { venueId: 'v9' }, ['v1', 'v2'])).toMatchObject({ valid: false, message: 'This promo code is not valid for this venue' });
  });
  it('a venue-scoped code cannot be used on something with no venue (e.g. an event ticket)', async () => {
    expect((await check(promo(), { venueId: null }, ['v1'])).valid).toBe(false);
  });
});

describe('validatePromoCode: how much it takes off', () => {
  it('percentage of the subtotal, rounded to the cent', async () => {
    // 10% of 12345 = 1234.5 -> 1235
    expect((await check(promo(), { subtotalCents: 12345 })).discountCents).toBe(1235);
  });
  it('accepts the discount value as a string, as Postgres numeric arrives', async () => {
    expect((await check(promo({ discount_value: '25' }), { subtotalCents: 10000 })).discountCents).toBe(2500);
  });
  it('fixed amount', async () => {
    expect((await check(promo({ discount_type: 'fixed_amount', discount_value: 2500 }))).discountCents).toBe(2500);
  });
  it('never discounts more than the subtotal', async () => {
    expect((await check(promo({ discount_type: 'fixed_amount', discount_value: 5000 }), { subtotalCents: 3000 })).discountCents).toBe(3000);
    expect((await check(promo({ discount_value: 150 }), { subtotalCents: 3000 })).discountCents).toBe(3000);
  });
  it('a code that would take off nothing is rejected, not "applied"', async () => {
    expect(await check(promo({ discount_value: 0 }))).toMatchObject({ valid: false, message: 'This promo code has no effect on this order' });
    expect((await check(promo(), { subtotalCents: 0 })).valid).toBe(false);
  });
});
