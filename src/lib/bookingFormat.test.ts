import { describe, expect, it } from 'vitest';
import { formatMoney, statusBadgeClass } from './bookingFormat';

describe('formatMoney', () => {
  it('shows cents as dollars with two decimals and an upper-case currency', () => {
    expect(formatMoney(123456, 'cad')).toBe('$1234.56 CAD');
    expect(formatMoney(0, 'cad')).toBe('$0.00 CAD');
    expect(formatMoney(5, 'usd')).toBe('$0.05 USD');
    expect(formatMoney(100, 'CAD')).toBe('$1.00 CAD');
  });
});

describe('statusBadgeClass', () => {
  it('has a style for every status a booking can show', () => {
    for (const s of ['paid', 'pending', 'cancelled', 'refunded']) {
      expect(statusBadgeClass[s], s).toBeTruthy();
    }
  });
});
