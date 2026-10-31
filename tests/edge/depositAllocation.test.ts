import { describe, expect, it } from 'vitest';
import { recomputeTableBookingTotals } from '../../supabase/functions/_shared/bookingTotals.ts';
import { dueAtVenueBottleCents } from '../../supabase/functions/_shared/bottlePayment.ts';
import { combinationParts, creditedDepositCents, splitDeposit } from '../../supabase/functions/_shared/depositAllocation.ts';
import { createFakeDb } from './stubs/fakeDb';

// All money is integer cents. A deposit that is a COMBINATION is split into a reservation fee, a minimum-spend credit and admission; only the credit share counts toward the bottle bill.

const combo = (fee: number, credit: number, admission: number) => ({
  purpose: 'combination', recipient: 'venue', venue_pct: 100, parts: { reservation_fee_pct: fee, minimum_spend_credit_pct: credit, admission_pct: admission },
});

describe('reading a combination', () => {
  it('reads three whole-percent shares that add up to 100', () => {
    expect(combinationParts(combo(30, 50, 20))).toEqual({ reservationFeePct: 30, minimumSpendCreditPct: 50, admissionPct: 20 });
    expect(combinationParts(combo(0, 60, 40))).toEqual({ reservationFeePct: 0, minimumSpendCreditPct: 60, admissionPct: 40 });
  });

  it.each([
    ['no terms', undefined],
    ['null', null],
    ['a string', 'combination'],
    ['an array', []],
    ['another purpose', { purpose: 'minimum_spend_credit', parts: { reservation_fee_pct: 30, minimum_spend_credit_pct: 50, admission_pct: 20 } }],
    ['no parts', { purpose: 'combination' }],
    ['parts that are not an object', { purpose: 'combination', parts: 'x' }],
    ['shares adding up to 99', combo(30, 50, 19)],
    ['shares adding up to 101', combo(30, 50, 21)],
    ['a negative share', combo(-10, 60, 50)],
    ['a share of minus one that the others make up for', combo(-1, 51, 50)],
    ['a credit of minus one', combo(50, -1, 51)],
    ['an admission of minus one', combo(50, 51, -1)],
    ['a share over 100', combo(0, 150, -50)],
    ['a fractional share', combo(33.5, 33.5, 33)],
    ['text for a share', { purpose: 'combination', parts: { reservation_fee_pct: '30', minimum_spend_credit_pct: 50, admission_pct: 20 } }],
    ['a missing share', { purpose: 'combination', parts: { reservation_fee_pct: 50, minimum_spend_credit_pct: 50 } }],
    ['NaN', combo(Number.NaN, 50, 50)],
  ])('is not a combination: %s', (_name, terms) => {
    expect(combinationParts(terms)).toBeNull();
  });
});

describe('splitting a deposit', () => {
  it('works the examples by hand', () => {
    // $200: 30% fee, 50% credit, 20% admission
    expect(splitDeposit(20000, { reservationFeePct: 30, minimumSpendCreditPct: 50, admissionPct: 20 })).toEqual({ reservationFeeCents: 6000, minimumSpendCreditCents: 10000, admissionCents: 4000 });
    // the client's own example: a $200 reservation charge, none of it credited
    expect(splitDeposit(20000, { reservationFeePct: 100, minimumSpendCreditPct: 0, admissionPct: 0 })).toEqual({ reservationFeeCents: 20000, minimumSpendCreditCents: 0, admissionCents: 0 });
    // $200 paid toward the minimum
    expect(splitDeposit(20000, { reservationFeePct: 0, minimumSpendCreditPct: 100, admissionPct: 0 })).toEqual({ reservationFeeCents: 0, minimumSpendCreditCents: 20000, admissionCents: 0 });
    // admission-only money is not credit
    expect(splitDeposit(20000, { reservationFeePct: 0, minimumSpendCreditPct: 0, admissionPct: 100 })).toEqual({ reservationFeeCents: 0, minimumSpendCreditCents: 0, admissionCents: 20000 });
  });

  it('rounds the credit and the admission DOWN and gives the cents left over to the reservation fee', () => {
    // 10001 cents at 33/33/34: credit floor(3300.33)=3300, admission floor(3400.34)=3400, fee 10001-3300-3400=3301
    expect(splitDeposit(10001, { reservationFeePct: 33, minimumSpendCreditPct: 33, admissionPct: 34 })).toEqual({ reservationFeeCents: 3301, minimumSpendCreditCents: 3300, admissionCents: 3400 });
    // a half cent on both: the credit is never more than its share
    expect(splitDeposit(1, { reservationFeePct: 0, minimumSpendCreditPct: 50, admissionPct: 50 })).toEqual({ reservationFeeCents: 1, minimumSpendCreditCents: 0, admissionCents: 0 });
  });

  it('always adds up to the deposit exactly, never credits more than its share, and never goes negative (10,000 cases)', () => {
    let seed = 20261120;
    const rand = (n: number) => {
      seed = (seed * 1103515245 + 12345) & 0x7fffffff;
      return seed % n;
    };
    for (let i = 0; i < 10000; i++) {
      const credit = rand(101);
      const admission = rand(101 - credit);
      const parts = { reservationFeePct: 100 - credit - admission, minimumSpendCreditPct: credit, admissionPct: admission };
      const deposit = rand(5_000_000);
      const s = splitDeposit(deposit, parts);
      expect(s.reservationFeeCents + s.minimumSpendCreditCents + s.admissionCents).toBe(deposit);
      expect(s.reservationFeeCents).toBeGreaterThanOrEqual(0);
      expect(s.minimumSpendCreditCents).toBeLessThanOrEqual((deposit * credit) / 100);
      expect(s.admissionCents).toBeLessThanOrEqual((deposit * admission) / 100);
      expect(Number.isInteger(s.minimumSpendCreditCents) && Number.isInteger(s.admissionCents) && Number.isInteger(s.reservationFeeCents)).toBe(true);
    }
  });

  it('a deposit that is zero, negative or not a number splits into nothing', () => {
    const parts = { reservationFeePct: 30, minimumSpendCreditPct: 50, admissionPct: 20 };
    const zero = { reservationFeeCents: 0, minimumSpendCreditCents: 0, admissionCents: 0 };
    for (const d of [0, -500, Number.NaN, Number.POSITIVE_INFINITY]) expect(splitDeposit(d, parts)).toEqual(zero);
  });
});

describe('what counts toward the bottle bill', () => {
  it('BottlesUp\'s switch comes first: with it off nothing is credited, whatever the terms say', () => {
    for (const terms of [undefined, null, combo(30, 50, 20), { purpose: 'minimum_spend_credit' }, { purpose: 'reservation_fee' }]) {
      expect(creditedDepositCents({ depositCents: 20000, depositIsCredit: false, terms })).toBe(0);
    }
  });

  it('with it on, a deposit that is not a combination is credited in full, exactly as before', () => {
    for (const terms of [undefined, null, {}, { purpose: 'minimum_spend_credit' }, { purpose: 'reservation_fee' }, { purpose: 'admission' }, combo(30, 50, 19)]) {
      expect(creditedDepositCents({ depositCents: 20000, depositIsCredit: true, terms })).toBe(20000);
    }
  });

  it('with it on, a combination credits only its credit share', () => {
    expect(creditedDepositCents({ depositCents: 20000, depositIsCredit: true, terms: combo(30, 50, 20) })).toBe(10000);
    expect(creditedDepositCents({ depositCents: 20000, depositIsCredit: true, terms: combo(50, 0, 50) })).toBe(0);
    expect(creditedDepositCents({ depositCents: 20000, depositIsCredit: true, terms: combo(0, 60, 40) })).toBe(12000);
  });
});

describe('nothing changes for a deposit that is not a combination (the live money path)', () => {
  // The formula the code used before a combination existed.
  const before = (o: { choice: 'pay_ahead' | 'pay_at_club'; subtotal: number; deposit: number; credit: boolean }) =>
    o.choice !== 'pay_at_club' ? 0 : o.credit ? Math.max(o.subtotal - o.deposit, 0) : o.subtotal;

  it('gives the same due-at-venue amount as before in 20,000 cases', () => {
    let seed = 7;
    const rand = (n: number) => {
      seed = (seed * 1103515245 + 12345) & 0x7fffffff;
      return seed % n;
    };
    const terms = [undefined, null, {}, { purpose: 'reservation_fee', recipient: 'venue', venue_pct: 100 }, { purpose: 'minimum_spend_credit', recipient: 'split', venue_pct: 70 }, { purpose: 'admission', recipient: 'organizer', venue_pct: 0 }, { purpose: 'combination' }, combo(30, 50, 19)];
    for (let i = 0; i < 20000; i++) {
      const o = { choice: rand(2) ? 'pay_at_club' : ('pay_ahead' as const), subtotal: rand(2_000_000), deposit: rand(500_000), credit: rand(2) === 1 };
      const now = dueAtVenueBottleCents({ bottlePaymentChoice: o.choice as 'pay_ahead' | 'pay_at_club', bottleSubtotalCents: o.subtotal, depositCents: o.deposit, depositIsCredit: o.credit, depositTerms: terms[rand(terms.length)] });
      expect(now).toBe(before({ ...o, choice: o.choice as 'pay_ahead' | 'pay_at_club' }));
    }
  });

  it('and the old call, with no terms at all, is untouched', () => {
    expect(dueAtVenueBottleCents({ bottlePaymentChoice: 'pay_at_club', bottleSubtotalCents: 30000, depositCents: 10000, depositIsCredit: true })).toBe(20000);
    expect(dueAtVenueBottleCents({ bottlePaymentChoice: 'pay_at_club', bottleSubtotalCents: 30000, depositCents: 10000, depositIsCredit: false })).toBe(30000);
  });
});

describe('a combination in the money', () => {
  const base = { bottleSubtotalCents: 30000, depositCents: 20000, depositIsCredit: true, depositTerms: combo(30, 50, 20) };

  it('pay_at_club: only the credit share is netted off what is due at the venue', () => {
    // 30000 of bottles - 10000 credited = 20000 due (a whole-deposit credit would have left 10000)
    expect(dueAtVenueBottleCents({ ...base, bottlePaymentChoice: 'pay_at_club' })).toBe(20000);
  });
  it('a credit larger than the bottles leaves nothing due, never a negative', () => {
    expect(dueAtVenueBottleCents({ ...base, bottlePaymentChoice: 'pay_at_club', bottleSubtotalCents: 4000 })).toBe(0);
  });
  it('pay_ahead still leaves nothing for the venue', () => {
    expect(dueAtVenueBottleCents({ ...base, bottlePaymentChoice: 'pay_ahead' })).toBe(0);
  });
  it('with the credit switch off, nothing is netted off', () => {
    expect(dueAtVenueBottleCents({ ...base, depositIsCredit: false, bottlePaymentChoice: 'pay_at_club' })).toBe(30000);
  });

  const booking = (terms: unknown, credit: boolean, lines: { line_total_cents: number; payment_status: string }[]) =>
    createFakeDb({
      site_table_bookings: [{ id: 'bk1', deposit_cents: 20000, discount_cents: 0, deposit_terms: terms, venue: { tax_rate_bps: 0, deposit_is_credit: credit } }],
      site_table_booking_bottles: lines.map((l) => ({ booking_id: 'bk1', cancelled_at: null, ...l })),
      site_content: [{ id: 1, bottlesup_fee_bps: 0 }],
    });

  it('the totals after a bottle is added net off the credit share only', async () => {
    const t = await recomputeTableBookingTotals(booking(combo(30, 50, 20), true, [{ line_total_cents: 30000, payment_status: 'due_at_venue' }]).client, 'bk1');
    // deposit 20000 (paid now) + 30000 - 10000 credited = 40000; the whole-deposit credit would have been 30000
    expect(t.amountTotalCents).toBe(40000);
    expect(t.bottleSubtotalCents).toBe(30000);
  });

  it('a booking with the same deposit and a single purpose credits all of it, as before', async () => {
    const t = await recomputeTableBookingTotals(booking({ purpose: 'minimum_spend_credit', recipient: 'venue', venue_pct: 100 }, true, [{ line_total_cents: 30000, payment_status: 'due_at_venue' }]).client, 'bk1');
    expect(t.amountTotalCents).toBe(30000);
  });

  it('a booking with no terms at all (made before they existed) credits all of it too', async () => {
    const t = await recomputeTableBookingTotals(booking(undefined, true, [{ line_total_cents: 30000, payment_status: 'due_at_venue' }]).client, 'bk1');
    expect(t.amountTotalCents).toBe(30000);
  });

  it('checkout and the totals after the fact agree about what is owed at the venue', async () => {
    const due = dueAtVenueBottleCents({ ...base, bottlePaymentChoice: 'pay_at_club' });
    const t = await recomputeTableBookingTotals(booking(combo(30, 50, 20), true, [{ line_total_cents: 30000, payment_status: 'due_at_venue' }]).client, 'bk1');
    expect(t.amountTotalCents - due).toBe(20000);
  });

  it('the admission and fee shares are never credited, however many bottles are bought', async () => {
    const t = await recomputeTableBookingTotals(booking(combo(50, 0, 50), true, [{ line_total_cents: 5000, payment_status: 'due_at_venue' }]).client, 'bk1');
    // credit share is 0: 20000 deposit + 5000 bottles
    expect(t.amountTotalCents).toBe(25000);
  });
});
