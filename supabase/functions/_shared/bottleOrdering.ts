import Stripe from 'npm:stripe@17';
import { isPreviewOrLocalOrigin } from './cors.ts';
import { recomputeTableBookingTotals } from './bookingTotals.ts';
import { sendBottleAdditionEmail } from './tableBookingEmail.ts';

// eslint-disable-next-line @typescript-eslint/no-explicit-any
type SupabaseClient = any;

export interface BottleRequest {
  bottle_id: string;
  quantity: number;
}

export interface AddBottlesResult {
  status: number;
  body: Record<string, unknown>;
}

// Shared core for "add bottles to an existing paid booking" - one place so
// the pricing/stock/Stripe logic can never drift between its three entry
// points: add-table-booking-bottles (a signed-in customer adding to their own
// booking, section 3; or staff adding to any booking, section 8), and
// order-bottles-by-code (anyone holding the booking's confirmation code, e.g.
// a table QR code - section 8's other bullet).
//
// Staff is a person physically completing the sale, not a checkout flow -
// there's no "redirect the customer to Stripe" step in a live in-person
// interaction, so a staff-added item is always settled the same way a club
// payment already is (section 5), regardless of the venue's online payment
// modes. Only a customer's own order (dashboard or table QR) goes through
// the venue's actual pay_ahead/pay_at_club/both choice.
export async function addBottlesToBooking(
  supabase: SupabaseClient,
  opts: {
    bookingId: string;
    bottleRequests: BottleRequest[];
    isStaff: boolean;
    requestedPaymentChoice: 'pay_ahead' | 'pay_at_club' | undefined;
    actorId: string | null;
    actorEmail: string;
    origin: string;
    allowedOriginEnv: string;
    siteUrlEnv: string;
  },
): Promise<AddBottlesResult> {
  const { data: booking, error: bookingError } = await supabase
    .from('site_table_bookings')
    .select('*, table_type:site_table_types(name), venue:site_venues(id, name, tax_rate_bps, bottle_payment_mode, deposit_is_credit)')
    .eq('id', opts.bookingId)
    .single();

  if (bookingError || !booking) {
    return { status: 404, body: { error: 'Booking not found' } };
  }
  if (booking.status !== 'paid') {
    return { status: 400, body: { error: 'This booking is not confirmed yet' } };
  }

  const venue = booking.venue as {
    id: string;
    name: string;
    tax_rate_bps: number;
    bottle_payment_mode: 'pay_ahead' | 'pay_at_club' | 'both';
    deposit_is_credit: boolean;
  };
  const tableType = booking.table_type as { name: string };

  const bottlePaymentChoice: 'pay_ahead' | 'pay_at_club' = opts.isStaff
    ? 'pay_at_club'
    : venue.bottle_payment_mode === 'both'
      ? (opts.requestedPaymentChoice === 'pay_at_club' ? 'pay_at_club' : 'pay_ahead')
      : venue.bottle_payment_mode;

  // Re-read bottle prices from the DB (never trust the client), scoped to
  // this venue and currently orderable. Best-effort stock check against
  // everything already committed to a paid booking (charged online or
  // reserved for the club - both are a real hold either way), same
  // trade-off as every other stock check in this codebase.
  type BottleLine = { bottle_id: string; name: string; size: string | null; unit_price_cents: number; quantity: number; line_total_cents: number };
  const bottleIds = opts.bottleRequests.map((b) => b.bottle_id);
  const { data: bottleRows, error: bottlesError } = await supabase
    .from('site_bottles')
    .select('id, venue_id, name, size, price_cents, currency, is_available, is_sold_out, stock_quantity')
    .in('id', bottleIds);

  if (bottlesError) {
    console.error('addBottlesToBooking: bottles lookup error', bottlesError);
    return { status: 500, body: { error: 'Failed to load bottles' } };
  }

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const bottleById = new Map((bottleRows ?? []).map((b: any) => [b.id, b]));
  const bottleLines: BottleLine[] = [];
  let bottleSubtotalCents = 0;

  for (const bottleReq of opts.bottleRequests) {
    const bottle = bottleById.get(bottleReq.bottle_id);
    if (!bottle || bottle.venue_id !== venue.id || !bottle.is_available || bottle.is_sold_out) {
      return { status: 400, body: { error: 'One of the selected bottles is no longer available' } };
    }

    if (bottle.stock_quantity !== null) {
      const { data: committedLines } = await supabase
        .from('site_table_booking_bottles')
        .select('quantity, booking:site_table_bookings!inner(status)')
        .eq('bottle_id', bottle.id)
        .eq('booking.status', 'paid')
        .in('payment_status', ['paid', 'due_at_venue']);
      const committedSoFar = (committedLines ?? []).reduce((sum: number, l: { quantity: number }) => sum + l.quantity, 0);
      if (committedSoFar + bottleReq.quantity > bottle.stock_quantity) {
        return { status: 409, body: { error: `Not enough "${bottle.name}" left in stock` } };
      }
    }

    const lineTotal = bottle.price_cents * bottleReq.quantity;
    bottleSubtotalCents += lineTotal;
    bottleLines.push({
      bottle_id: bottle.id,
      name: bottle.name,
      size: bottle.size,
      unit_price_cents: bottle.price_cents,
      quantity: bottleReq.quantity,
      line_total_cents: lineTotal,
    });
  }

  if (bottlePaymentChoice === 'pay_at_club') {
    const { error: insertError } = await supabase.from('site_table_booking_bottles').insert(
      bottleLines.map((b) => ({
        booking_id: opts.bookingId,
        bottle_id: b.bottle_id,
        bottle_name: b.name,
        size: b.size,
        unit_price_cents: b.unit_price_cents,
        quantity: b.quantity,
        line_total_cents: b.line_total_cents,
        payment_status: 'due_at_venue',
        is_addon: true,
        added_by: opts.actorId,
      })),
    );
    if (insertError) {
      console.error('addBottlesToBooking: due_at_venue insert failed', insertError);
      return { status: 500, body: { error: 'Failed to add bottles' } };
    }

    const totals = await recomputeTableBookingTotals(supabase, opts.bookingId);
    const { error: updateError } = await supabase
      .from('site_table_bookings')
      .update({
        bottle_subtotal_cents: totals.bottleSubtotalCents,
        tax_cents: totals.taxCents,
        bottlesup_fee_cents: totals.bottlesupFeeCents,
        amount_total_cents: totals.amountTotalCents,
      })
      .eq('id', opts.bookingId);
    if (updateError) {
      console.error('addBottlesToBooking: totals update failed', updateError);
      return { status: 500, body: { error: 'Failed to add bottles' } };
    }

    await supabase.from('audit_log').insert({
      actor_id: opts.actorId,
      actor_email: opts.actorEmail,
      action: opts.isStaff ? 'table_booking.staff_added_bottles' : 'table_booking.customer_added_bottles',
      entity_type: 'site_table_bookings',
      entity_id: opts.bookingId,
      details: { mode: 'due_at_venue', bottles: bottleLines, new_amount_total_cents: totals.amountTotalCents },
    });

    const email = await sendBottleAdditionEmail({
      toEmail: booking.customer_email,
      toName: booking.customer_name,
      venueName: venue.name,
      tableTypeName: tableType.name,
      confirmationCode: booking.confirmation_code,
      addedBottles: bottleLines.map((b) => ({
        bottle_name: b.name,
        size: b.size,
        quantity: b.quantity,
        line_total_cents: b.line_total_cents,
        payment_status: 'due_at_venue' as const,
      })),
      amountChargedNowCents: 0,
      newAmountTotalCents: totals.amountTotalCents,
      newAmountPaidCents: booking.amount_paid_cents,
      currency: booking.currency,
    });
    if (!email.sent) {
      console.error('addBottlesToBooking: email send failed', email.error);
    }

    return { status: 200, body: { success: true, mode: 'due_at_venue' } };
  }

  // pay_ahead: charge these specific new bottles now via their own Stripe
  // Checkout session - the original booking's session already completed and
  // is never reopened or adjusted.
  const { data: content } = await supabase
    .from('site_content')
    .select('payments_mode, bottlesup_fee_bps')
    .eq('id', 1)
    .maybeSingle();
  const paymentsMode = content?.payments_mode === 'live' ? 'live' : 'test';
  const bottlesupFeeBps = content?.bottlesup_fee_bps ?? 0;

  const stripeSecretKey =
    paymentsMode === 'live'
      ? (Deno.env.get('STRIPE_SECRET_KEY_LIVE') ?? Deno.env.get('STRIPE_SECRET_KEY'))
      : (Deno.env.get('STRIPE_SECRET_KEY_TEST') ??
        Deno.env.get('test_SK') ??
        Deno.env.get('STRIPE_SECRET_KEY'));
  if (!stripeSecretKey) {
    return { status: 500, body: { error: 'Stripe is not configured' } };
  }
  const stripe = new Stripe(stripeSecretKey, { apiVersion: '2024-06-20' });

  const taxCents = Math.round((bottleSubtotalCents * (venue.tax_rate_bps ?? 0)) / 10000);
  const bottlesUpFeeCents = Math.round((bottleSubtotalCents * bottlesupFeeBps) / 10000);

  const allowedOrigins = (opts.allowedOriginEnv ?? '').split(',').map((o: string) => o.trim());
  const siteUrl = allowedOrigins.includes(opts.origin) || isPreviewOrLocalOrigin(opts.origin)
    ? opts.origin
    : (opts.siteUrlEnv || 'http://localhost:5173');

  const lineItems: Stripe.Checkout.SessionCreateParams.LineItem[] = bottleLines.map((b) => ({
    price_data: {
      currency: booking.currency,
      product_data: { name: b.size ? `${b.name} (${b.size})` : b.name },
      unit_amount: b.unit_price_cents,
    },
    quantity: b.quantity,
  }));
  const taxAndFeeCents = taxCents + bottlesUpFeeCents;
  if (taxAndFeeCents > 0) {
    lineItems.push({
      price_data: {
        currency: booking.currency,
        product_data: { name: 'Taxes & fees' },
        unit_amount: taxAndFeeCents,
      },
      quantity: 1,
    });
  }

  const session = await stripe.checkout.sessions.create({
    mode: 'payment',
    customer_email: booking.customer_email,
    line_items: lineItems,
    adaptive_pricing: { enabled: false },
    metadata: { booking_id: opts.bookingId, kind: 'bottle_addon' },
    success_url: `${siteUrl}/bookings/table/${opts.bookingId}?addon_session_id={CHECKOUT_SESSION_ID}`,
    cancel_url: `${siteUrl}/bookings/table/${opts.bookingId}`,
  });

  const { error: insertError } = await supabase.from('site_table_booking_bottles').insert(
    bottleLines.map((b) => ({
      booking_id: opts.bookingId,
      bottle_id: b.bottle_id,
      bottle_name: b.name,
      size: b.size,
      unit_price_cents: b.unit_price_cents,
      quantity: b.quantity,
      line_total_cents: b.line_total_cents,
      payment_status: 'pending_payment',
      is_addon: true,
      added_by: opts.actorId,
      stripe_checkout_session_id: session.id,
    })),
  );
  if (insertError) {
    console.error('addBottlesToBooking: pending insert failed', insertError);
    return { status: 500, body: { error: 'Failed to start checkout' } };
  }

  return { status: 200, body: { success: true, mode: 'pay_ahead', url: session.url } };
}
