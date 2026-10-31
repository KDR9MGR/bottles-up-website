import { describe, expect, it } from 'vitest';
import * as browser from './depositAllocation';
import * as server from '../../supabase/functions/_shared/depositAllocation.ts';

// The booking page shows a guest what is due at the club; the server decides what is charged. They must work it out the same way.

const combo = (fee: number, credit: number, admission: number) => ({
  purpose: 'combination', recipient: 'venue', venue_pct: 100, parts: { reservation_fee_pct: fee, minimum_spend_credit_pct: credit, admission_pct: admission },
});

describe('the page and the server agree about a deposit', () => {
  it('on the examples worked by hand', () => {
    expect(browser.creditedDepositCents({ depositCents: 20000, depositIsCredit: true, terms: combo(30, 50, 20) })).toBe(10000);
    expect(browser.creditedDepositCents({ depositCents: 20000, depositIsCredit: true, terms: { purpose: 'minimum_spend_credit' } })).toBe(20000);
    expect(browser.creditedDepositCents({ depositCents: 20000, depositIsCredit: false, terms: combo(30, 50, 20) })).toBe(0);
    expect(browser.splitDeposit(10001, { reservationFeePct: 33, minimumSpendCreditPct: 33, admissionPct: 34 })).toEqual({ reservationFeeCents: 3301, minimumSpendCreditCents: 3300, admissionCents: 3400 });
  });

  it('on 10,000 random deposits, switches and terms, including terms that are not a combination', () => {
    let seed = 99;
    const rand = (n: number) => {
      seed = (seed * 1103515245 + 12345) & 0x7fffffff;
      return seed % n;
    };
    const others: unknown[] = [undefined, null, {}, { purpose: 'reservation_fee' }, { purpose: 'admission' }, { purpose: 'combination' }, combo(30, 50, 19), 'x'];
    for (let i = 0; i < 10000; i++) {
      const credit = rand(101);
      const admission = rand(101 - credit);
      const terms = rand(3) === 0 ? others[rand(others.length)] : combo(100 - credit - admission, credit, admission);
      const o = { depositCents: rand(3_000_000), depositIsCredit: rand(2) === 1, terms };
      expect(browser.creditedDepositCents(o)).toBe(server.creditedDepositCents(o));
      expect(browser.combinationParts(terms)).toEqual(server.combinationParts(terms));
      if (browser.combinationParts(terms)) expect(browser.splitDeposit(o.depositCents, browser.combinationParts(terms)!)).toEqual(server.splitDeposit(o.depositCents, server.combinationParts(terms)!));
    }
  });
});
