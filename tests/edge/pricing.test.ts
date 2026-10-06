import { describe, expect, it } from 'vitest';
import { recomputeTableBookingTotals } from '../../supabase/functions/_shared/bookingTotals.ts';
import { dueAtVenueBottleCents } from '../../supabase/functions/_shared/bottlePayment.ts';
import { createFakeDb } from './stubs/fakeDb';

// All money is integer cents. Expected values below are worked out by hand.

type Line = { line_total_cents: number; payment_status: 'paid' | 'due_at_venue' | 'pending_payment'; cancelled_at?: string | null };

function bookingWith(opts: {
  deposit?: number; discount?: number; taxBps?: number | null; depositIsCredit?: boolean; feeBps?: number | null; lines?: Line[];
}) {
  const { deposit = 10000, discount = 0, taxBps = 1300, depositIsCredit = false, feeBps = 500, lines = [] } = opts;
  return createFakeDb({
    site_table_bookings: [{ id: 'bk1', deposit_cents: deposit, discount_cents: discount, venue: { tax_rate_bps: taxBps, deposit_is_credit: depositIsCredit } }],
    site_table_booking_bottles: lines.map((l) => ({ booking_id: 'bk1', cancelled_at: null, ...l })),
    site_content: feeBps === null ? [] : [{ id: 1, bottlesup_fee_bps: feeBps }],
  });
}
const totals = (db: ReturnType<typeof createFakeDb>) => recomputeTableBookingTotals(db.client, 'bk1');

describe('recomputeTableBookingTotals', () => {
  it('deposit only: tax 13% and platform fee 5% are added on top', async () => {
    // 10000 + 1300 tax + 500 fee
    expect(await totals(bookingWith({}))).toEqual({ bottleSubtotalCents: 0, taxCents: 1300, bottlesupFeeCents: 500, amountTotalCents: 11800 });
  });

  it('bottles paid now are taxed and fee-d along with the deposit', async () => {
    // preTax 10000 + 20000 = 30000 -> tax 3900, fee 1500 -> 35400
    const t = await totals(bookingWith({ lines: [{ line_total_cents: 20000, payment_status: 'paid' }] }));
    expect(t).toEqual({ bottleSubtotalCents: 20000, taxCents: 3900, bottlesupFeeCents: 1500, amountTotalCents: 35400 });
  });

  it('bottles due at the venue are in the total but are NOT taxed or fee-d here', async () => {
    // preTax = deposit only -> tax 1300, fee 500; plus 15000 due at venue = 26800
    const t = await totals(bookingWith({ lines: [{ line_total_cents: 15000, payment_status: 'due_at_venue' }] }));
    expect(t).toEqual({ bottleSubtotalCents: 15000, taxCents: 1300, bottlesupFeeCents: 500, amountTotalCents: 26800 });
  });

  it('when the deposit is a credit, it is netted off the due-at-venue bottles', async () => {
    // due 15000 - deposit 10000 = 5000 owed at venue -> 10000 + 1300 + 500 + 5000 = 16800
    const credited = await totals(bookingWith({ depositIsCredit: true, lines: [{ line_total_cents: 15000, payment_status: 'due_at_venue' }] }));
    expect(credited.amountTotalCents).toBe(16800);
    // the bottle subtotal still reports the full 15000
    expect(credited.bottleSubtotalCents).toBe(15000);
  });

  it('a credit never goes negative: bottles smaller than the deposit add nothing', async () => {
    const t = await totals(bookingWith({ depositIsCredit: true, lines: [{ line_total_cents: 8000, payment_status: 'due_at_venue' }] }));
    expect(t.amountTotalCents).toBe(11800);
  });

  it('a discount comes off BEFORE tax and fee are calculated', async () => {
    // (10000 - 2500) = 7500 -> tax 975, fee 375 -> 8850
    const t = await totals(bookingWith({ discount: 2500 }));
    expect(t).toMatchObject({ taxCents: 975, bottlesupFeeCents: 375, amountTotalCents: 8850 });
  });

  it('a discount bigger than the charge floors at zero (no negative tax or total)', async () => {
    const t = await totals(bookingWith({ discount: 99999 }));
    expect(t).toEqual({ bottleSubtotalCents: 0, taxCents: 0, bottlesupFeeCents: 0, amountTotalCents: 0 });
  });

  it('cancelled lines never count, and neither do lines still waiting on payment', async () => {
    const t = await totals(
      bookingWith({
        lines: [
          { line_total_cents: 5000, payment_status: 'paid', cancelled_at: '2026-01-01T00:00:00Z' },
          { line_total_cents: 4000, payment_status: 'due_at_venue', cancelled_at: '2026-01-01T00:00:00Z' },
          { line_total_cents: 7000, payment_status: 'pending_payment' },
        ],
      }),
    );
    expect(t).toEqual({ bottleSubtotalCents: 0, taxCents: 1300, bottlesupFeeCents: 500, amountTotalCents: 11800 });
  });

  it('rounds tax to the nearest cent (half up)', async () => {
    // 10010 * 7.5% = 750.75 -> 751 ; fee 0
    const t = await totals(bookingWith({ deposit: 10010, taxBps: 750, feeBps: 0 }));
    expect(t.taxCents).toBe(751);
    expect(t.amountTotalCents).toBe(10010 + 751);
  });

  it('a venue with no tax rate, and a missing site_content row, charge no tax and no fee', async () => {
    const t = await totals(bookingWith({ taxBps: null, feeBps: null }));
    expect(t).toEqual({ bottleSubtotalCents: 0, taxCents: 0, bottlesupFeeCents: 0, amountTotalCents: 10000 });
  });

  it('throws for a booking that does not exist, rather than returning zeros', async () => {
    const db = createFakeDb({ site_table_bookings: [], site_table_booking_bottles: [], site_content: [] });
    await expect(recomputeTableBookingTotals(db.client, 'missing')).rejects.toThrow(/missing.*not found/);
  });

  it('only reads: it never writes to the database', async () => {
    const db = bookingWith({ lines: [{ line_total_cents: 100, payment_status: 'paid' }] });
    await totals(db);
    expect(db.writes).toEqual([]);
  });
});

describe('dueAtVenueBottleCents (what is left unpaid at checkout)', () => {
  const base = { bottleSubtotalCents: 30000, depositCents: 10000, depositIsCredit: false };

  it('pay_ahead: nothing is left for the venue', () => {
    expect(dueAtVenueBottleCents({ ...base, bottlePaymentChoice: 'pay_ahead' })).toBe(0);
  });
  it('pay_at_club: every bottle dollar is due at the venue', () => {
    expect(dueAtVenueBottleCents({ ...base, bottlePaymentChoice: 'pay_at_club' })).toBe(30000);
  });
  it('pay_at_club with a credit deposit: the deposit is netted off', () => {
    expect(dueAtVenueBottleCents({ ...base, bottlePaymentChoice: 'pay_at_club', depositIsCredit: true })).toBe(20000);
  });
  it('a credit deposit larger than the bottles leaves nothing due, never a negative', () => {
    expect(dueAtVenueBottleCents({ ...base, bottlePaymentChoice: 'pay_at_club', depositIsCredit: true, bottleSubtotalCents: 4000 })).toBe(0);
  });
  it('agrees with recomputeTableBookingTotals about what is owed at the venue', async () => {
    // This is the contract in the code comments: checkout and fulfillment must agree.
    const subtotal = 30000, deposit = 10000;
    const due = dueAtVenueBottleCents({ bottlePaymentChoice: 'pay_at_club', bottleSubtotalCents: subtotal, depositCents: deposit, depositIsCredit: true });
    const t = await totals(bookingWith({ deposit, depositIsCredit: true, taxBps: 0, feeBps: 0, lines: [{ line_total_cents: subtotal, payment_status: 'due_at_venue' }] }));
    // total = deposit (paid now) + due-at-venue
    expect(t.amountTotalCents - due).toBe(deposit);
  });
});
