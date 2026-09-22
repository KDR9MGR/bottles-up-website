import { createClient } from 'npm:@supabase/supabase-js@2';
import { corsHeadersFor, handleOptions } from '../_shared/cors.ts';
import { cancelBottleLine } from '../_shared/bottleCancellation.ts';

// Bottle Payment Options section 9: "Cancellations - Preserve the cancelled
// items and reason. Paid items require the applicable refund process."
// Cancelling a whole booking cascades to every one of its still-active
// bottle lines via the same cancelBottleLine() helper used for a single-line
// cancellation, so the two never disagree about what "cancelled" means.
// pending_payment lines are left alone - an in-flight Stripe checkout isn't
// a committed order yet, and will simply expire unused on Stripe's side.
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
    const { booking_id, reason } = await req.json();
    if (!booking_id || typeof booking_id !== 'string') {
      return json({ error: 'booking_id is required' }, 400);
    }
    if (!reason || typeof reason !== 'string' || !reason.trim()) {
      return json({ error: 'A reason is required' }, 400);
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
      supabase.from('cms_admins').select('id, email').eq('id', userData.user.id).maybeSingle(),
      supabase.from('door_staff').select('id, email').eq('id', userData.user.id).maybeSingle(),
    ]);
    if (!admin && !doorStaff) {
      return json({ error: 'Forbidden' }, 403);
    }
    const actorEmail = admin?.email ?? doorStaff?.email ?? 'unknown';

    const { data: booking, error: bookingError } = await supabase
      .from('site_table_bookings')
      .select('id, status, amount_paid_cents')
      .eq('id', booking_id)
      .maybeSingle();
    if (bookingError || !booking) {
      return json({ error: 'Booking not found' }, 404);
    }
    if (booking.status === 'cancelled') {
      return json({ error: 'This booking is already cancelled' }, 400);
    }

    const { data: activeLines } = await supabase
      .from('site_table_booking_bottles')
      .select('id')
      .eq('booking_id', booking_id)
      .is('cancelled_at', null)
      .neq('payment_status', 'pending_payment');

    let anyPaidCancelled = false;
    for (const line of activeLines ?? []) {
      const result = await cancelBottleLine(supabase, {
        bottleLineId: line.id,
        reason: reason.trim(),
        actorId: userData.user.id,
        actorEmail,
      });
      if (result.success && result.wasPaid) anyPaidCancelled = true;
    }

    const { error: updateError } = await supabase
      .from('site_table_bookings')
      .update({
        status: 'cancelled',
        cancelled_at: new Date().toISOString(),
        cancelled_by: userData.user.id,
        cancellation_reason: reason.trim(),
      })
      .eq('id', booking_id);
    if (updateError) {
      console.error('cancel-table-booking: update failed', updateError);
      return json({ error: 'Failed to cancel this booking' }, 500);
    }

    await supabase.from('audit_log').insert({
      actor_id: userData.user.id,
      actor_email: actorEmail,
      action: 'table_booking.cancelled',
      entity_type: 'site_table_bookings',
      entity_id: booking_id,
      details: { reason: reason.trim(), had_paid_items: anyPaidCancelled || booking.amount_paid_cents > 0 },
    });

    return json({
      success: true,
      refund_suggested: anyPaidCancelled || booking.amount_paid_cents > 0,
    });
  } catch (error) {
    console.error('cancel-table-booking error:', error);
    return json({ error: 'Internal server error' }, 500);
  }
});
