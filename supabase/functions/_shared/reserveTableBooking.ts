import { createClient } from 'npm:@supabase/supabase-js@2';
import { isMissingFunction } from './tableCapacity.ts';

// eslint-disable-next-line @typescript-eslint/no-explicit-any
type SupabaseClient = ReturnType<typeof createClient<any>>;

// Takes the table for an online checkout in ONE database step (site_reserve_table_booking, 20261111100000_atomic_table_checkout.sql): the database locks the table
// type, counts what is taken the same way as the desk and the walk-in, and writes the pending booking only if one is left. Counting in one call and inserting in
// another let two guests who started at the same moment both get the last table.
//
// While that migration is not applied yet (the function does not exist) this falls back to the plain insert of before, so a deploy that comes before the migration
// cannot stop bookings. Any OTHER failure is thrown: a table is never sold on an answer that could not be read.

export interface TableReservation {
  venueId: string;
  tableTypeId: string;
  slotId: string;
  arrivalDate: string; // the ARRIVAL date, as site_table_bookings.booking_date
  customerName: string;
  customerEmail: string;
  customerPhone: string | null;
  guests: number;
  hours: number | null;
  depositCents: number;
  bottleSubtotalCents: number;
  taxCents: number;
  bottlesUpFeeCents: number;
  amountTotalCents: number;
  bottlePaymentChoice: 'pay_ahead' | 'pay_at_club';
  currency: string;
  promoCodeId: string | null;
  discountCents: number;
  signText: string | null;
}

export type ReserveResult = { kind: 'reserved'; bookingId: string } | { kind: 'sold_out' };

export async function reserveTableBooking(supabase: SupabaseClient, r: TableReservation): Promise<ReserveResult> {
  const { data, error } = await supabase.rpc('site_reserve_table_booking', {
    p_venue: r.venueId,
    p_table_type: r.tableTypeId,
    p_slot: r.slotId,
    p_arrival: r.arrivalDate,
    p_customer_name: r.customerName,
    p_customer_email: r.customerEmail,
    p_customer_phone: r.customerPhone,
    p_guests: r.guests,
    p_hours: r.hours,
    p_deposit_cents: r.depositCents,
    p_bottle_subtotal_cents: r.bottleSubtotalCents,
    p_tax_cents: r.taxCents,
    p_fee_cents: r.bottlesUpFeeCents,
    p_total_cents: r.amountTotalCents,
    p_bottle_payment_choice: r.bottlePaymentChoice,
    p_currency: r.currency,
    p_promo_code_id: r.promoCodeId,
    p_discount_cents: r.discountCents,
    p_sign_text: r.signText,
  });
  if (!error) {
    if (data === null) return { kind: 'sold_out' };
    if (typeof data === 'string' && data !== '') return { kind: 'reserved', bookingId: data };
    throw new Error('The table reservation answer was not a booking.');
  }
  if (!isMissingFunction(error)) throw new Error(`Could not reserve the table: ${error.message ?? error.code ?? 'unknown error'}`);

  const { data: booking, error: insertError } = await supabase
    .from('site_table_bookings')
    .insert({
      venue_id: r.venueId,
      table_type_id: r.tableTypeId,
      time_slot_id: r.slotId,
      booking_date: r.arrivalDate,
      customer_name: r.customerName,
      customer_email: r.customerEmail,
      customer_phone: r.customerPhone,
      guest_count: r.guests,
      hours: r.hours,
      deposit_cents: r.depositCents,
      bottle_subtotal_cents: r.bottleSubtotalCents,
      tax_cents: r.taxCents,
      bottlesup_fee_cents: r.bottlesUpFeeCents,
      amount_total_cents: r.amountTotalCents,
      bottle_payment_choice: r.bottlePaymentChoice,
      currency: r.currency,
      status: 'pending',
      promo_code_id: r.promoCodeId,
      discount_cents: r.discountCents,
      bottle_sign_text: r.signText,
    })
    .select('id')
    .single();
  if (insertError || !booking) throw new Error(`Could not start the booking: ${insertError?.message ?? 'no row came back'}`);
  return { kind: 'reserved', bookingId: booking.id as string };
}
