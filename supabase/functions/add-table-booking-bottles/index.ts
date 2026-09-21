import { createClient } from 'npm:@supabase/supabase-js@2';
import Stripe from 'npm:stripe@17';
import { corsHeadersFor, handleOptions, isPreviewOrLocalOrigin } from '../_shared/cors.ts';
import { recomputeTableBookingTotals } from '../_shared/bookingTotals.ts';
import { sendBottleAdditionEmail } from '../_shared/tableBookingEmail.ts';

// Bottle Payment Options section 3: a customer adds bottles to their OWN
// already-paid booking from "My Bookings", choosing pay-ahead or reserve-for-club
// when the venue allows both. Requires the customer's own auth session - the
// service-role client below is only used after ownership is verified, exactly
// like every other money-touching function in this codebase never trusts the
// client for prices.
Deno.serve(async (req: Request) => {
  const preflight = handleOptions(req);
  if (preflight) return preflight;

  const cors = corsHeadersFor(req);
  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

  if (req.method !== 'POST') {
    return json({ error: 'Method not allowed' }, 405);
  }

  const authHeader = req.headers.get('Authorization');
  if (!authHeader) {
    return json({ error: 'Unauthorized' }, 401);
  }

  try {
    const { booking_id, bottles: requestedBottles, bottle_payment_choice } = await req.json();

    if (!booking_id || typeof booking_id !== 'string') {
      return json({ error: 'booking_id is required' }, 400);
    }
    if (!Array.isArray(requestedBottles) || requestedBottles.length === 0) {
      return json({ error: 'Select at least one bottle' }, 400);
    }
    const bottleRequests: { bottle_id: string; quantity: number }[] = [];
    for (const b of requestedBottles) {
      const qty = Number(b?.quantity);
      if (typeof b?.bottle_id !== 'string' || !b.bottle_id || !Number.isInteger(qty) || qty < 1) {
        return json({ error: 'Invalid bottle selection' }, 400);
      }
      bottleRequests.push({ bottle_id: b.bottle_id, quantity: qty });
    }

    const anonClient = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: userData, error: userError } = await anonClient.auth.getUser();
    if (userError || !userData.user?.email) {
      return json({ error: 'Unauthorized' }, 401);
    }

    const supabase = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    );

    const { data: booking, error: bookingError } = await supabase
      .from('site_table_bookings')
      .select('*, table_type:site_table_types(name), venue:site_venues(id, name, tax_rate_bps, bottle_payment_mode, deposit_is_credit)')
      .eq('id', booking_id)
      .single();

    if (bookingError || !booking) {
      return json({ error: 'Booking not found' }, 404);
    }
    // Ownership check - the anon client above only proves who the caller is,
    // never which bookings they're allowed to touch. This mirrors the RLS
    // policy that already scopes a customer's own SELECT access (verified
    // email = booking.customer_email), re-checked here since this runs with
    // the service-role key, which bypasses RLS entirely.
    if (booking.customer_email.toLowerCase() !== userData.user.email.toLowerCase()) {
      return json({ error: 'Forbidden' }, 403);
    }
    if (booking.status !== 'paid') {
      return json({ error: 'This booking is not confirmed yet' }, 400);
    }

    const venue = booking.venue as {
      id: string;
      name: string;
      tax_rate_bps: number;
      bottle_payment_mode: 'pay_ahead' | 'pay_at_club' | 'both';
      deposit_is_credit: boolean;
    };
    const tableType = booking.table_type as { name: string };

    const bottlePaymentChoice: 'pay_ahead' | 'pay_at_club' =
      venue.bottle_payment_mode === 'both'
        ? (bottle_payment_choice === 'pay_at_club' ? 'pay_at_club' : 'pay_ahead')
        : venue.bottle_payment_mode;

    // Re-read bottle prices from the DB (never trust the client), scoped to this
    // venue and currently orderable. Best-effort stock check against everything
    // already committed to a paid booking (charged online or reserved for the
    // club - both are a real hold on the bottle either way), same trade-off as
    // every other stock check in this codebase - not airtight under heavy
    // concurrent checkouts.
    type BottleLine = { bottle_id: string; name: string; size: string | null; unit_price_cents: number; quantity: number; line_total_cents: number };
    const bottleIds = bottleRequests.map((b) => b.bottle_id);
    const { data: bottleRows, error: bottlesError } = await supabase
      .from('site_bottles')
      .select('id, venue_id, name, size, price_cents, currency, is_available, is_sold_out, stock_quantity')
      .in('id', bottleIds);

    if (bottlesError) {
      console.error('bottles lookup error:', bottlesError);
      return json({ error: 'Failed to load bottles' }, 500);
    }

    const bottleById = new Map((bottleRows ?? []).map((b) => [b.id, b]));
    const bottleLines: BottleLine[] = [];
    let bottleSubtotalCents = 0;

    for (const bottleReq of bottleRequests) {
      const bottle = bottleById.get(bottleReq.bottle_id);
      if (!bottle || bottle.venue_id !== venue.id || !bottle.is_available || bottle.is_sold_out) {
        return json({ error: 'One of the selected bottles is no longer available' }, 400);
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
          return json({ error: `Not enough "${bottle.name}" left in stock` }, 409);
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
          booking_id,
          bottle_id: b.bottle_id,
          bottle_name: b.name,
          size: b.size,
          unit_price_cents: b.unit_price_cents,
          quantity: b.quantity,
          line_total_cents: b.line_total_cents,
          payment_status: 'due_at_venue',
          is_addon: true,
          added_by: userData.user.id,
        })),
      );
      if (insertError) {
        console.error('add-table-booking-bottles: due_at_venue insert failed', insertError);
        return json({ error: 'Failed to add bottles' }, 500);
      }

      const totals = await recomputeTableBookingTotals(supabase, booking_id);
      const { error: updateError } = await supabase
        .from('site_table_bookings')
        .update({
          bottle_subtotal_cents: totals.bottleSubtotalCents,
          tax_cents: totals.taxCents,
          bottlesup_fee_cents: totals.bottlesupFeeCents,
          amount_total_cents: totals.amountTotalCents,
        })
        .eq('id', booking_id);
      if (updateError) {
        console.error('add-table-booking-bottles: totals update failed', updateError);
        return json({ error: 'Failed to add bottles' }, 500);
      }

      await supabase.from('audit_log').insert({
        actor_email: userData.user.email,
        actor_id: userData.user.id,
        action: 'table_booking.customer_added_bottles',
        entity_type: 'site_table_bookings',
        entity_id: booking_id,
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
        console.error('add-table-booking-bottles: email send failed', email.error);
      }

      return json({ success: true, mode: 'due_at_venue' });
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
      return json({ error: 'Stripe is not configured' }, 500);
    }
    const stripe = new Stripe(stripeSecretKey, { apiVersion: '2024-06-20' });

    const taxCents = Math.round((bottleSubtotalCents * (venue.tax_rate_bps ?? 0)) / 10000);
    const bottlesUpFeeCents = Math.round((bottleSubtotalCents * bottlesupFeeBps) / 10000);

    const origin = req.headers.get('origin') ?? '';
    const allowedOrigins = (Deno.env.get('ALLOWED_ORIGIN') ?? '').split(',').map((o: string) => o.trim());
    const siteUrl = allowedOrigins.includes(origin) || isPreviewOrLocalOrigin(origin)
      ? origin
      : (Deno.env.get('SITE_URL') ?? 'http://localhost:5173');

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
      metadata: { booking_id, kind: 'bottle_addon' },
      success_url: `${siteUrl}/bookings/table/${booking_id}?addon_session_id={CHECKOUT_SESSION_ID}`,
      cancel_url: `${siteUrl}/bookings/table/${booking_id}`,
    });

    const { error: insertError } = await supabase.from('site_table_booking_bottles').insert(
      bottleLines.map((b) => ({
        booking_id,
        bottle_id: b.bottle_id,
        bottle_name: b.name,
        size: b.size,
        unit_price_cents: b.unit_price_cents,
        quantity: b.quantity,
        line_total_cents: b.line_total_cents,
        payment_status: 'pending_payment',
        is_addon: true,
        added_by: userData.user.id,
        stripe_checkout_session_id: session.id,
      })),
    );
    if (insertError) {
      console.error('add-table-booking-bottles: pending insert failed', insertError);
      return json({ error: 'Failed to start checkout' }, 500);
    }

    return json({ success: true, mode: 'pay_ahead', url: session.url });
  } catch (error) {
    console.error('add-table-booking-bottles error:', error);
    return json({ error: 'Internal server error' }, 500);
  }
});
