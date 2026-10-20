import { createClient } from 'npm:@supabase/supabase-js@2';

// eslint-disable-next-line @typescript-eslint/no-explicit-any
type SupabaseClient = ReturnType<typeof createClient<any>>;

export interface RecomputedTotals {
  bottleSubtotalCents: number;
  taxCents: number;
  bottlesupFeeCents: number;
  amountTotalCents: number;
}

// Re-derives a table booking's bottle_subtotal_cents/tax_cents/bottlesup_fee_cents/
// amount_total_cents from every CURRENT bottle line plus the booking's own fixed
// deposit/discount - the single source of truth after any bottle addition (a
// due-at-venue reservation or a confirmed pay-ahead addon), so stored totals can
// never drift from what's actually on the booking. Additions have their own
// payment choice independent of the booking's original one, so unlike checkout-time
// math this can't key off a single bottlePaymentChoice - it looks at what's
// actually on each line instead.
//
// Never touches amount_paid_cents - that only changes when money actually moves
// (a confirmed Stripe session or a manually recorded in-person payment), which the
// caller handles separately, since it can also include payments this function has
// no way to derive (e.g. cash collected at the venue).
const BOOKING_COLUMNS = 'deposit_cents, discount_cents, venue:site_venues(tax_rate_bps, deposit_is_credit)';

// The booking, with what staff have discounted (staff_discount_cents, 20261024100000_staff_discounts_and_complimentary.sql). Before that migration is applied the column
// does not exist and the database says so: read the booking without it (nothing can have been discounted by staff yet).
async function readBooking(supabase: SupabaseClient, bookingId: string) {
  const withStaff = await supabase.from('site_table_bookings').select(`${BOOKING_COLUMNS}, staff_discount_cents`).eq('id', bookingId).single();
  if (!withStaff.error) return withStaff.data;
  const plain = await supabase.from('site_table_bookings').select(BOOKING_COLUMNS).eq('id', bookingId).single();
  return plain.data;
}

export async function recomputeTableBookingTotals(
  supabase: SupabaseClient,
  bookingId: string,
): Promise<RecomputedTotals> {
  const [booking, { data: lines }, { data: content }] = await Promise.all([
    readBooking(supabase, bookingId),
    supabase
      .from('site_table_booking_bottles')
      .select('line_total_cents, payment_status, cancelled_at')
      .eq('booking_id', bookingId),
    supabase.from('site_content').select('bottlesup_fee_bps').eq('id', 1).maybeSingle(),
  ]);

  if (!booking) {
    throw new Error(`recomputeTableBookingTotals: booking ${bookingId} not found`);
  }

  const venue = booking.venue as { tax_rate_bps: number; deposit_is_credit: boolean };
  const allLines = (lines ?? []) as { line_total_cents: number; payment_status: string; cancelled_at: string | null }[];

  // Section 9: a cancelled line is preserved for history but never counted
  // toward what's owed - same reasoning as excluding pending_payment lines.
  const activeLines = allLines.filter((l) => !l.cancelled_at);
  const taxedBottleCents = activeLines
    .filter((l) => l.payment_status === 'paid')
    .reduce((sum, l) => sum + l.line_total_cents, 0);
  const dueAtVenueBottleCentsRaw = activeLines
    .filter((l) => l.payment_status === 'due_at_venue')
    .reduce((sum, l) => sum + l.line_total_cents, 0);

  const creditedDueAtVenueCents = venue.deposit_is_credit
    ? Math.max(dueAtVenueBottleCentsRaw - booking.deposit_cents, 0)
    : dueAtVenueBottleCentsRaw;

  const preTax = booking.deposit_cents + taxedBottleCents;
  const discounted = Math.max(preTax - booking.discount_cents, 0);
  const taxCents = Math.round((discounted * (venue.tax_rate_bps ?? 0)) / 10000);
  const bottlesupFeeCents = Math.round((discounted * (content?.bottlesup_fee_bps ?? 0)) / 10000);
  // What the club's own people discounted (a server or manager with the owner's limits) comes off what is owed, after tax is worked out, and stays through bottles being
  // added or cancelled; it can never take the total below zero.
  const staffDiscountCents = Number((booking as { staff_discount_cents?: number | null }).staff_discount_cents ?? 0);
  const amountTotalCents = Math.max(discounted + taxCents + bottlesupFeeCents + creditedDueAtVenueCents - staffDiscountCents, 0);

  return {
    bottleSubtotalCents: taxedBottleCents + dueAtVenueBottleCentsRaw,
    taxCents,
    bottlesupFeeCents,
    amountTotalCents,
  };
}
