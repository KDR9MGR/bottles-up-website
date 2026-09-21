export type BottlePaymentChoice = 'pay_ahead' | 'pay_at_club';

// Shared by create-table-booking-checkout (computing this at checkout time) and
// fulfillment.ts (reconstructing it after the fact to set amount_paid_cents) -
// these must always agree on what's charged online now vs. left due at the venue.
export function dueAtVenueBottleCents(opts: {
  bottlePaymentChoice: BottlePaymentChoice;
  bottleSubtotalCents: number;
  depositCents: number;
  depositIsCredit: boolean;
}): number {
  if (opts.bottlePaymentChoice !== 'pay_at_club') return 0;
  return opts.depositIsCredit
    ? Math.max(opts.bottleSubtotalCents - opts.depositCents, 0)
    : opts.bottleSubtotalCents;
}
