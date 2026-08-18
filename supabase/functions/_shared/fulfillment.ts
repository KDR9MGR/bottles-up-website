import { createClient } from 'npm:@supabase/supabase-js@2';
import QRCode from 'npm:qrcode@1.5.3';
import { generateTicketCode, sendTicketEmail } from './ticketEmail.ts';
import { generateConfirmationCode, sendTableBookingEmail, formatTimeSlot } from './tableBookingEmail.ts';

// eslint-disable-next-line @typescript-eslint/no-explicit-any
type SupabaseClient = ReturnType<typeof createClient<any>>;

// Marks a ticket order paid and emails the ticket, if it hasn't been already.
// Shared by the Stripe webhook (the normal path) and site-booking-status's
// fallback (self-heals when the webhook never fires - see that function for why).
// The `.is('ticket_code', null)` condition makes the "claim" atomic so the two
// callers can never both generate a code and double-send the same order.
export async function fulfillTicketOrder(
  supabase: SupabaseClient,
  orderId: string,
  paymentIntentId: string | null,
): Promise<void> {
  const { data: order, error } = await supabase
    .from('site_orders')
    .select('*, ticket_tiers:site_ticket_tiers(*, events:site_events(*)), promo:promo_codes(code)')
    .eq('id', orderId)
    .single();

  if (error || !order) {
    console.error('fulfillTicketOrder: order not found', orderId, error);
    return;
  }
  if (order.ticket_sent_at) return;

  let ticketCode: string | null = order.ticket_code;

  if (!ticketCode) {
    const generated = generateTicketCode();
    const { data: claimed } = await supabase
      .from('site_orders')
      .update({ status: 'paid', stripe_payment_intent_id: paymentIntentId, ticket_code: generated })
      .eq('id', orderId)
      .is('ticket_code', null)
      .select('ticket_code')
      .maybeSingle();

    if (claimed) {
      ticketCode = claimed.ticket_code;
      await supabase.rpc('increment_tier_sold', { p_tier_id: order.tier_id, p_qty: order.quantity });
      if (order.promo_code_id) {
        await supabase.rpc('increment_promo_code_usage', { p_promo_id: order.promo_code_id });
      }
    } else {
      // Lost the race - another caller already claimed it. Use their code/state.
      const { data: refreshed } = await supabase
        .from('site_orders')
        .select('ticket_code, ticket_sent_at')
        .eq('id', orderId)
        .single();
      if (refreshed?.ticket_sent_at) return;
      ticketCode = refreshed?.ticket_code ?? null;
    }
  } else if (order.status !== 'paid') {
    await supabase
      .from('site_orders')
      .update({ status: 'paid', stripe_payment_intent_id: paymentIntentId })
      .eq('id', orderId);
  }

  if (!ticketCode) return;

  const qrDataUrl = await QRCode.toDataURL(ticketCode, { width: 400, margin: 1 });
  const tier = order.ticket_tiers as { name: string; events: { title: string; venue_name: string; start_date: string } };
  const promo = order.promo as { code: string } | null;

  const email = await sendTicketEmail({
    toEmail: order.customer_email,
    toName: order.customer_name,
    eventTitle: tier.events.title,
    venueName: tier.events.venue_name,
    startDate: tier.events.start_date,
    tierName: tier.name,
    quantity: order.quantity,
    ticketCode,
    qrDataUrl,
    discountCents: order.discount_cents,
    promoCode: promo?.code ?? null,
  });

  if (email.sent) {
    await supabase.from('site_orders').update({ ticket_sent_at: new Date().toISOString() }).eq('id', orderId);
  } else {
    console.error('fulfillTicketOrder: email send failed', orderId, email.error);
  }
}

// Same idea as fulfillTicketOrder, for VIP table bookings.
export async function fulfillTableBooking(
  supabase: SupabaseClient,
  bookingId: string,
  paymentIntentId: string | null,
): Promise<void> {
  const { data: booking, error } = await supabase
    .from('site_table_bookings')
    .select('*, table_type:site_table_types(*), venue:site_venues(*), time_slot:site_venue_time_slots(*), promo:promo_codes(code)')
    .eq('id', bookingId)
    .single();

  if (error || !booking) {
    console.error('fulfillTableBooking: booking not found', bookingId, error);
    return;
  }
  if (booking.confirmation_sent_at) return;

  let confirmationCode: string | null = booking.confirmation_code;

  if (!confirmationCode) {
    const generated = generateConfirmationCode();
    const { data: claimed } = await supabase
      .from('site_table_bookings')
      .update({ status: 'paid', stripe_payment_intent_id: paymentIntentId, confirmation_code: generated })
      .eq('id', bookingId)
      .is('confirmation_code', null)
      .select('confirmation_code')
      .maybeSingle();

    if (claimed) {
      confirmationCode = claimed.confirmation_code;
      if (booking.promo_code_id) {
        await supabase.rpc('increment_promo_code_usage', { p_promo_id: booking.promo_code_id });
      }
    } else {
      const { data: refreshed } = await supabase
        .from('site_table_bookings')
        .select('confirmation_code, confirmation_sent_at')
        .eq('id', bookingId)
        .single();
      if (refreshed?.confirmation_sent_at) return;
      confirmationCode = refreshed?.confirmation_code ?? null;
    }
  } else if (booking.status !== 'paid') {
    await supabase
      .from('site_table_bookings')
      .update({ status: 'paid', stripe_payment_intent_id: paymentIntentId })
      .eq('id', bookingId);
  }

  if (!confirmationCode) return;

  const { data: bottleLines } = await supabase
    .from('site_table_booking_bottles')
    .select('bottle_name, size, quantity, unit_price_cents, line_total_cents')
    .eq('booking_id', bookingId);

  const qrDataUrl = await QRCode.toDataURL(confirmationCode, { width: 400, margin: 1 });
  const tableType = booking.table_type as { name: string };
  const venue = booking.venue as { name: string };
  const timeSlot = booking.time_slot as { start_time: string };
  const promo = booking.promo as { code: string } | null;

  const email = await sendTableBookingEmail({
    toEmail: booking.customer_email,
    toName: booking.customer_name,
    venueName: venue.name,
    tableTypeName: tableType.name,
    bookingDate: booking.booking_date,
    timeSlotLabel: formatTimeSlot(timeSlot.start_time),
    guestCount: booking.guest_count,
    depositCents: booking.deposit_cents,
    bottleSubtotalCents: booking.bottle_subtotal_cents,
    taxCents: booking.tax_cents,
    bottlesupFeeCents: booking.bottlesup_fee_cents,
    discountCents: booking.discount_cents,
    promoCode: promo?.code ?? null,
    totalCents: booking.amount_total_cents,
    bottles: bottleLines ?? [],
    currency: booking.currency,
    hours: booking.hours,
    confirmationCode,
    qrDataUrl,
  });

  if (email.sent) {
    await supabase
      .from('site_table_bookings')
      .update({ confirmation_sent_at: new Date().toISOString() })
      .eq('id', bookingId);
  } else {
    console.error('fulfillTableBooking: email send failed', bookingId, email.error);
  }
}
