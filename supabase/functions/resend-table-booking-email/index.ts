import { createClient } from 'npm:@supabase/supabase-js@2';
import QRCode from 'npm:qrcode@1.5.3';
import { sendTableBookingEmail, formatTimeSlot } from '../_shared/tableBookingEmail.ts';
import { corsHeadersFor, handleOptions } from '../_shared/cors.ts';

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

  const { data: admin } = await supabase
    .from('cms_admins')
    .select('id')
    .eq('id', userData.user.id)
    .maybeSingle();
  if (!admin) {
    return json({ error: 'Forbidden' }, 403);
  }

  try {
    const { booking_id } = await req.json();
    if (!booking_id) return json({ error: 'booking_id is required' }, 400);

    const { data: booking, error: bookingError } = await supabase
      .from('site_table_bookings')
      .select('*, table_type:site_table_types(*), venue:site_venues(*), time_slot:site_venue_time_slots(*)')
      .eq('id', booking_id)
      .single();

    if (bookingError || !booking) return json({ error: 'Booking not found' }, 404);
    if (booking.status !== 'paid' || !booking.confirmation_code) {
      return json({ error: 'Booking has no confirmation to resend (not paid yet)' }, 400);
    }

    const qrDataUrl = await QRCode.toDataURL(booking.confirmation_code, { width: 400, margin: 1 });
    const tableType = booking.table_type as { name: string };
    const venue = booking.venue as { name: string };
    const timeSlot = booking.time_slot as { start_time: string };

    const result = await sendTableBookingEmail({
      toEmail: booking.customer_email,
      toName: booking.customer_name,
      venueName: venue.name,
      tableTypeName: tableType.name,
      bookingDate: booking.booking_date,
      timeSlotLabel: formatTimeSlot(timeSlot.start_time),
      guestCount: booking.guest_count,
      depositCents: booking.amount_total_cents,
      currency: booking.currency,
      confirmationCode: booking.confirmation_code,
      qrDataUrl,
    });

    if (!result.sent) {
      return json({ error: result.error ?? 'Email provider failed to send' }, 500);
    }

    await supabase.from('site_table_bookings').update({ confirmation_sent_at: new Date().toISOString() }).eq('id', booking_id);

    await supabase.from('audit_log').insert({
      actor_id: userData.user.id,
      actor_email: userData.user.email ?? 'unknown',
      action: 'table_booking.resent',
      entity_type: 'site_table_bookings',
      entity_id: booking_id,
      details: { confirmation_code: booking.confirmation_code },
    });

    return json({ success: true });
  } catch (error) {
    console.error('resend-table-booking-email error:', error);
    return json({ error: 'Internal server error' }, 500);
  }
});
