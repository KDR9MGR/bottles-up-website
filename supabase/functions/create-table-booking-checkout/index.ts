import { createClient } from 'npm:@supabase/supabase-js@2';
import Stripe from 'npm:stripe@17';
import { corsHeadersFor, handleOptions, isPreviewOrLocalOrigin } from '../_shared/cors.ts';
import { validatePromoCode } from '../_shared/promoCode.ts';

Deno.serve(async (req: Request) => {
  const preflight = handleOptions(req);
  if (preflight) return preflight;

  const cors = corsHeadersFor(req);
  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

  if (req.method !== 'POST') {
    return json({ error: 'Method not allowed' }, 405);
  }

  try {
    const {
      venue_id,
      table_type_id,
      time_slot_id,
      booking_date,
      guest_count,
      hours,
      customer_name,
      customer_email,
      customer_phone,
      bottles: requestedBottles,
      promo_code,
    } = await req.json();

    if (!venue_id || !table_type_id || !time_slot_id || !booking_date || !customer_name || !customer_email) {
      return json({ error: 'Missing required fields' }, 400);
    }
    const guests = Number(guest_count);
    if (!Number.isInteger(guests) || guests < 1) {
      return json({ error: 'Invalid guest count' }, 400);
    }
    if (!/^\d{4}-\d{2}-\d{2}$/.test(booking_date)) {
      return json({ error: 'Invalid booking date' }, 400);
    }

    // Bottles are optional - a plain table-only booking is still valid. When present,
    // only { bottle_id, quantity } is trusted from the client; name/price are always
    // re-read from the DB below, same as the table type itself.
    const bottleRequests: { bottle_id: string; quantity: number }[] = [];
    if (requestedBottles !== undefined) {
      if (!Array.isArray(requestedBottles)) {
        return json({ error: 'Invalid bottles' }, 400);
      }
      for (const b of requestedBottles) {
        const qty = Number(b?.quantity);
        if (typeof b?.bottle_id !== 'string' || !b.bottle_id || !Number.isInteger(qty) || qty < 1) {
          return json({ error: 'Invalid bottle selection' }, 400);
        }
        bottleRequests.push({ bottle_id: b.bottle_id, quantity: qty });
      }
    }

    const supabase = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    );

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

    const stripe = new Stripe(stripeSecretKey, {
      apiVersion: '2024-06-20',
    });

    // Re-read the table type + venue + time slot server-side. The client never gets to
    // say what the price is, or invent a slot/date the venue doesn't actually offer.
    // site_venue_time_slots and site_table_types are siblings under site_venues (no FK
    // between them), so they can't be embedded together in one PostgREST query - fetch
    // the time slot separately and cross-check venue_id in application code instead.
    const { data: tableType, error: tableTypeError } = await supabase
      .from('site_table_types')
      .select('*, venue:site_venues!inner(id, name, status, booking_start_date, booking_end_date, tax_rate_bps)')
      .eq('id', table_type_id)
      .eq('venue_id', venue_id)
      .single();

    if (tableTypeError || !tableType) {
      return json({ error: 'Table not found' }, 404);
    }
    if (tableType.venue.status !== 'published') {
      return json({ error: 'This venue is not currently taking bookings' }, 400);
    }
    if (guests > tableType.max_guests) {
      return json({ error: `This table seats up to ${tableType.max_guests} guests` }, 400);
    }

    // Venue-level booking window - bookings are only accepted for dates inside it,
    // when the venue has one configured.
    if (tableType.venue.booking_start_date && booking_date < tableType.venue.booking_start_date) {
      return json({ error: 'This venue is not yet taking bookings for that date' }, 400);
    }
    if (tableType.venue.booking_end_date && booking_date > tableType.venue.booking_end_date) {
      return json({ error: 'This venue is no longer taking bookings for that date' }, 400);
    }

    const { data: timeSlot, error: timeSlotError } = await supabase
      .from('site_venue_time_slots')
      .select('id, day_of_week, venue_id')
      .eq('id', time_slot_id)
      .eq('venue_id', venue_id)
      .single();

    if (timeSlotError || !timeSlot) {
      return json({ error: 'Time slot not found' }, 404);
    }

    // The requested date must actually fall on the day of week this slot is offered.
    const requestedDayOfWeek = new Date(`${booking_date}T00:00:00Z`).getUTCDay();
    if (requestedDayOfWeek !== timeSlot.day_of_week) {
      return json({ error: 'This time slot is not offered on the selected date' }, 400);
    }

    // Hourly-priced tables: the customer picks how many hours, total scales with it.
    // Flat-priced tables charge the fixed deposit, exactly as before.
    let depositCents: number;
    let bookedHours: number | null = null;
    let productLabel: string;

    if (tableType.pricing_mode === 'hourly') {
      const requestedHours = Number(hours);
      const minHours = tableType.min_hours ?? 1;
      if (!Number.isInteger(requestedHours) || requestedHours < minHours) {
        return json({ error: `This table requires a minimum of ${minHours} hour(s)` }, 400);
      }
      if (!tableType.hourly_rate_cents) {
        return json({ error: 'This table is not configured for booking yet' }, 500);
      }
      depositCents = tableType.hourly_rate_cents * requestedHours;
      bookedHours = requestedHours;
      productLabel = `${tableType.venue.name} - ${tableType.name} table (${requestedHours} hour${requestedHours === 1 ? '' : 's'})`;
    } else {
      depositCents = tableType.deposit_cents;
      productLabel = `${tableType.venue.name} - ${tableType.name} table (deposit)`;
    }

    // Best-effort capacity check against bookings already confirmed paid for this exact
    // table type + slot + date. Not airtight under heavy concurrent checkouts (same
    // documented trade-off as ticket sales), but sufficient at this venue's scale.
    const { count: paidCount } = await supabase
      .from('site_table_bookings')
      .select('id', { count: 'exact', head: true })
      .eq('table_type_id', table_type_id)
      .eq('time_slot_id', time_slot_id)
      .eq('booking_date', booking_date)
      .eq('status', 'paid');

    if ((paidCount ?? 0) >= tableType.inventory_count) {
      return json({ error: 'No tables of this type left for that date and time' }, 409);
    }

    // Bottles: re-read from the DB (never trust client-supplied prices), scoped to this
    // venue, and must currently be orderable. Best-effort stock check against already-paid
    // orders for bottles that track stock_quantity - same trade-off as the table capacity
    // check above.
    type BottleLine = { bottle_id: string; name: string; size: string | null; unit_price_cents: number; quantity: number; line_total_cents: number };
    const bottleLines: BottleLine[] = [];
    let bottleSubtotalCents = 0;

    if (bottleRequests.length > 0) {
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

      for (const bottleReq of bottleRequests) {
        const bottle = bottleById.get(bottleReq.bottle_id);
        if (!bottle || bottle.venue_id !== venue_id || !bottle.is_available || bottle.is_sold_out) {
          return json({ error: 'One of the selected bottles is no longer available' }, 400);
        }

        if (bottle.stock_quantity !== null) {
          const { data: paidLines } = await supabase
            .from('site_table_booking_bottles')
            .select('quantity, booking:site_table_bookings!inner(status)')
            .eq('bottle_id', bottle.id)
            .eq('booking.status', 'paid');
          const soldSoFar = (paidLines ?? []).reduce((sum: number, l: { quantity: number }) => sum + l.quantity, 0);
          if (soldSoFar + bottleReq.quantity > bottle.stock_quantity) {
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
    }

    const preTaxSubtotalCents = depositCents + bottleSubtotalCents;

    // Re-validate the promo code from scratch against this exact order - the client
    // never gets to say what the discount is, only which code it wants applied.
    let promoCodeId: string | null = null;
    let discountCents = 0;
    if (typeof promo_code === 'string' && promo_code.trim()) {
      const promoResult = await validatePromoCode(supabase, {
        code: promo_code,
        appliesTo: 'tables',
        venueId: venue_id,
        subtotalCents: preTaxSubtotalCents,
      });
      if (!promoResult.valid) {
        return json({ error: promoResult.message }, 400);
      }
      promoCodeId = promoResult.promoCodeId!;
      discountCents = promoResult.discountCents!;
    }

    const discountedSubtotalCents = preTaxSubtotalCents - discountCents;
    const taxRateBps = tableType.venue.tax_rate_bps ?? 0;
    const taxCents = Math.round((discountedSubtotalCents * taxRateBps) / 10000);
    const bottlesUpFeeCents = Math.round((discountedSubtotalCents * bottlesupFeeBps) / 10000);
    const totalCents = discountedSubtotalCents + taxCents + bottlesUpFeeCents;

    const { data: booking, error: bookingError } = await supabase
      .from('site_table_bookings')
      .insert({
        venue_id,
        table_type_id,
        time_slot_id,
        booking_date,
        customer_name,
        customer_email,
        customer_phone: customer_phone ?? null,
        guest_count: guests,
        hours: bookedHours,
        deposit_cents: depositCents,
        bottle_subtotal_cents: bottleSubtotalCents,
        tax_cents: taxCents,
        bottlesup_fee_cents: bottlesUpFeeCents,
        amount_total_cents: totalCents,
        currency: tableType.currency,
        status: 'pending',
        promo_code_id: promoCodeId,
        discount_cents: discountCents,
      })
      .select('id')
      .single();

    if (bookingError || !booking) {
      console.error('booking insert error:', bookingError);
      return json({ error: 'Failed to start booking' }, 500);
    }

    if (bottleLines.length > 0) {
      const { error: lineItemsError } = await supabase.from('site_table_booking_bottles').insert(
        bottleLines.map((b) => ({
          booking_id: booking.id,
          bottle_id: b.bottle_id,
          bottle_name: b.name,
          size: b.size,
          unit_price_cents: b.unit_price_cents,
          quantity: b.quantity,
          line_total_cents: b.line_total_cents,
        })),
      );
      if (lineItemsError) {
        console.error('booking bottle line items insert error:', lineItemsError);
        return json({ error: 'Failed to start booking' }, 500);
      }
    }

    const origin = req.headers.get('origin') ?? '';
    const allowedOrigins = (Deno.env.get('ALLOWED_ORIGIN') ?? '').split(',').map((o: string) => o.trim());
    const siteUrl = allowedOrigins.includes(origin) || isPreviewOrLocalOrigin(origin)
      ? origin
      : (Deno.env.get('SITE_URL') ?? 'http://localhost:5173');

    const lineItems: Stripe.Checkout.SessionCreateParams.LineItem[] = [
      {
        price_data: {
          currency: tableType.currency,
          product_data: { name: productLabel },
          unit_amount: depositCents,
        },
        quantity: 1,
      },
      ...bottleLines.map((b) => ({
        price_data: {
          currency: tableType.currency,
          product_data: { name: b.size ? `${b.name} (${b.size})` : b.name },
          unit_amount: b.unit_price_cents,
        },
        quantity: b.quantity,
      })),
    ];

    const taxAndFeeCents = taxCents + bottlesUpFeeCents;
    if (taxAndFeeCents > 0) {
      lineItems.push({
        price_data: {
          currency: tableType.currency,
          product_data: { name: 'Taxes & fees' },
          unit_amount: taxAndFeeCents,
        },
        quantity: 1,
      });
    }

    // Line items above stay at full price - the discount is applied as a
    // session-level Stripe coupon instead of hand-editing line amounts, so
    // Stripe's own checkout summary shows it as a clearly labeled line item.
    // It's created fresh per checkout ("once") rather than reused, since the
    // amount is specific to this order's subtotal.
    let discounts: Stripe.Checkout.SessionCreateParams.Discount[] | undefined;
    if (discountCents > 0) {
      const coupon = await stripe.coupons.create({
        amount_off: discountCents,
        currency: tableType.currency,
        duration: 'once',
        name: 'Promo code',
      });
      discounts = [{ coupon: coupon.id }];
    }

    const session = await stripe.checkout.sessions.create({
      mode: 'payment',
      customer_email,
      line_items: lineItems,
      ...(discounts ? { discounts } : {}),
      adaptive_pricing: { enabled: false },
      metadata: { booking_id: booking.id },
      success_url: `${siteUrl}/booking/success?session_id={CHECKOUT_SESSION_ID}`,
      cancel_url: `${siteUrl}/booking/cancel`,
    });

    await supabase.from('site_table_bookings').update({ stripe_checkout_session_id: session.id }).eq('id', booking.id);

    return json({ url: session.url });
  } catch (error) {
    console.error('create-table-booking-checkout error:', error);
    return json({ error: 'Internal server error' }, 500);
  }
});
