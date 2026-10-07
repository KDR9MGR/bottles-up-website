import { describe, expect, it } from 'vitest';
import { derivePaymentStatus, PAYMENT_STATUS_LABELS } from './clubPayment';

const verified = { managerVerifiedAt: '2026-01-01T00:00:00Z' };
const unverified = { managerVerifiedAt: null };

// This status decides what a server sees on a table card: "Payment Due",
// "Payment Recorded" (cash taken, manager has not checked it) or "Venue Verified".
describe('derivePaymentStatus', () => {
  it('any balance still owed is payment_due, whatever has been recorded', () => {
    expect(derivePaymentStatus(1, [])).toBe('payment_due');
    expect(derivePaymentStatus(5000, [verified])).toBe('payment_due');
  });
  it('nothing owed and nothing recorded: no status at all (a fully pre-paid table)', () => {
    expect(derivePaymentStatus(0, [])).toBeNull();
  });
  it('nothing owed, and every club payment has been checked by a manager: venue_verified', () => {
    expect(derivePaymentStatus(0, [verified, verified])).toBe('venue_verified');
  });
  it('nothing owed, but at least one payment is still unchecked: payment_recorded', () => {
    expect(derivePaymentStatus(0, [verified, unverified])).toBe('payment_recorded');
    expect(derivePaymentStatus(0, [unverified])).toBe('payment_recorded');
  });
  it('an overpayment (negative balance) is not treated as owing', () => {
    expect(derivePaymentStatus(-500, [unverified])).toBe('payment_recorded');
  });
});

describe('PAYMENT_STATUS_LABELS', () => {
  it('has a label for every status', () => {
    expect(PAYMENT_STATUS_LABELS).toEqual({
      payment_due: 'Payment Due',
      payment_recorded: 'Payment Recorded',
      venue_verified: 'Venue Verified',
    });
  });
});
