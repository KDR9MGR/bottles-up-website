import { createClient } from 'npm:@supabase/supabase-js@2';
import QRCode from 'npm:qrcode@1.5.3';
import { corsHeadersFor, handleOptions, isPreviewOrLocalOrigin } from '../_shared/cors.ts';
import { generateConfirmationCode, sendTableBookingEmail, formatTimeSlot } from '../_shared/tableBookingEmail.ts';
import { computeArrivalDate } from '../_shared/bookingNight.ts';

// Bottle Payment Options section 8: "for customers without reservations,
// staff creates a Walk-In Table Tab, assigns the table and follows the same
// ordering and payment process." Staff-only (never a public endpoint - a
// walk-in only makes sense when a real person is physically seating someone).
// No Stripe involved at all: the deposit is settled the same way club
// payments already are (section 5), same reasoning as staff-added bottles -
// staff is a person physically completing the sale, not a checkout flow.
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

    const anonClient = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: userData, error: userError } = await anonClient.auth.getUser();
    if (userError || !userData.user) {
      return json({ error: 'Unauthorized' }, 401);
    }

    const supabase = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    );

    const [{ data: admin }, { data: doorStaff }] = await Promise.all([
      supabase.from('cms_admins').select('id').eq('id', userData.user.id).maybeSingle(),
      supabase.from('door_staff').select('id').eq('id', userData.user.id).maybeSingle(),
    ]);
    if (!admin && !doorStaff) {
      return json({ error: 'Forbidden' }, 403);
    }

    const { data: tableType, error: tableTypeError } = await supabase
      .from('site_table_types')
      .select('*, venue:site_venues!inner(id, name, status)')
      .eq('id', table_type_id)
      .eq('venue_id', venue_id)
      .single();

    if (tableTypeError || !tableType) {
      return json({ error: 'Table not found' }, 404);
    }
    if (guests > tableType.max_guests) {
      return json({ error: `This table seats up to ${tableType.max_guests} guests` }, 400);
    }

    const { data: timeSlot, error: timeSlotError } = await supabase
      .from('site_venue_time_slots')
      .select('id, start_time')
      .eq('id', time_slot_id)
      .eq('venue_id', venue_id)
      .single();
    if (timeSlotError || !timeSlot) {
      return json({ error: 'Time slot not found' }, 404);
    }

    // Same "which calendar day does this slot's guest actually arrive on" logic
    // as the real checkout flow - see create-table-booking-checkout for why.
    const arrivalDate = computeArrivalDate(booking_date, timeSlot.start_time);

    let depositCents: number;
    let bookedHours: number | null = null;
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
    } else {
      depositCents = tableType.deposit_cents;
    }

    // Same best-effort capacity check as a normal checkout - a walk-in still
    // shouldn't oversell a table type past its configured inventory.
    const { count: paidCount } = await supabase
      .from('site_table_bookings')
      .select('id', { count: 'exact', head: true })
      .eq('table_type_id', table_type_id)
      .eq('time_slot_id', time_slot_id)
      .eq('booking_date', arrivalDate)
      .eq('status', 'paid');
    if ((paidCount ?? 0) >= tableType.inventory_count) {
      return json({ error: 'No tables of this type left for that date and time' }, 409);
    }

    const confirmationCode = generateConfirmationCode();

    const { data: booking, error: bookingError } = await supabase
      .from('site_table_bookings')
      .insert({
        venue_id,
        table_type_id,
        time_slot_id,
        booking_date: arrivalDate,
        customer_name,
        customer_email,
        customer_phone: customer_phone ?? null,
        guest_count: guests,
        hours: bookedHours,
        deposit_cents: depositCents,
        bottle_subtotal_cents: 0,
        tax_cents: 0,
        bottlesup_fee_cents: 0,
        amount_total_cents: depositCents,
        amount_paid_cents: 0,
        currency: tableType.currency,
        status: 'paid',
        bottle_payment_choice: 'pay_at_club',
        confirmation_code: confirmationCode,
        confirmation_sent_at: new Date().toISOString(),
        checked_in_at: new Date().toISOString(),
        checked_in_by: userData.user.id,
      })
      .select('id')
      .single();

    if (bookingError || !booking) {
      console.error('create-walkin-table-booking: insert failed', bookingError);
      return json({ error: 'Failed to create walk-in' }, 500);
    }

    await supabase.from('audit_log').insert({
      actor_id: userData.user.id,
      actor_email: userData.user.email ?? 'unknown',
      action: 'table_booking.walkin_created',
      entity_type: 'site_table_bookings',
      entity_id: booking.id,
      details: { venue_id, table_type_id, deposit_cents: depositCents, confirmation_code: confirmationCode },
    });

    const origin = req.headers.get('origin') ?? '';
    const allowedOrigins = (Deno.env.get('ALLOWED_ORIGIN') ?? '').split(',').map((o: string) => o.trim());
    const siteUrl = allowedOrigins.includes(origin) || isPreviewOrLocalOrigin(origin)
      ? origin
      : (Deno.env.get('SITE_URL') ?? 'https://bottlesupapp.com');

    const venue = tableType.venue as { name: string };
    const qrDataUrl = await QRCode.toDataURL(confirmationCode, { width: 400, margin: 1 });

    const email = await sendTableBookingEmail({
      toEmail: customer_email,
      toName: customer_name,
      venueName: venue.name,
      tableTypeName: tableType.name,
      bookingDate: arrivalDate,
      startTime: timeSlot.start_time,
      timeSlotLabel: formatTimeSlot(timeSlot.start_time),
      guestCount: guests,
      depositCents,
      bottleSubtotalCents: 0,
      taxCents: 0,
      bottlesupFeeCents: 0,
      totalCents: depositCents,
      paidNowCents: 0,
      dueAtVenueCents: depositCents,
      bottles: [],
      currency: tableType.currency,
      hours: bookedHours,
      confirmationCode,
      qrDataUrl,
      orderMoreUrl: `${siteUrl}/order/${confirmationCode}`,
    }).catch((err) => {
      console.error('create-walkin-table-booking: email send threw', err);
      return { sent: false, error: 'threw' };
    });
    if (!email.sent) {
      console.error('create-walkin-table-booking: email send failed', email.error);
    }

    return json({ success: true, booking_id: booking.id, confirmation_code: confirmationCode });
  } catch (error) {
    console.error('create-walkin-table-booking error:', error);
    return json({ error: 'Internal server error' }, 500);
  }
});
