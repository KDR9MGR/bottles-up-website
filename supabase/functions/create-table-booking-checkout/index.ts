import { createClient } from 'npm:@supabase/supabase-js@2';
import Stripe from 'npm:stripe@17';
import { corsHeadersFor, handleOptions, isPreviewOrLocalOrigin } from '../_shared/cors.ts';

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

    const supabase = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    );

    const { data: content } = await supabase
      .from('site_content')
      .select('payments_mode')
      .eq('id', 1)
      .maybeSingle();
    const paymentsMode = content?.payments_mode === 'live' ? 'live' : 'test';

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
      .select('*, venue:site_venues!inner(id, name, status, booking_start_date, booking_end_date)')
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
    let amountCents: number;
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
      amountCents = tableType.hourly_rate_cents * requestedHours;
      bookedHours = requestedHours;
      productLabel = `${tableType.venue.name} - ${tableType.name} table (${requestedHours} hour${requestedHours === 1 ? '' : 's'})`;
    } else {
      amountCents = tableType.deposit_cents;
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
        amount_total_cents: amountCents,
        currency: tableType.currency,
        status: 'pending',
      })
      .select('id')
      .single();

    if (bookingError || !booking) {
      console.error('booking insert error:', bookingError);
      return json({ error: 'Failed to start booking' }, 500);
    }

    const origin = req.headers.get('origin') ?? '';
    const allowedOrigins = (Deno.env.get('ALLOWED_ORIGIN') ?? '').split(',').map((o: string) => o.trim());
    const siteUrl = allowedOrigins.includes(origin) || isPreviewOrLocalOrigin(origin)
      ? origin
      : (Deno.env.get('SITE_URL') ?? 'http://localhost:5173');

    const session = await stripe.checkout.sessions.create({
      mode: 'payment',
      customer_email,
      line_items: [
        {
          price_data: {
            currency: tableType.currency,
            product_data: { name: productLabel },
            unit_amount: amountCents,
          },
          quantity: 1,
        },
      ],
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
