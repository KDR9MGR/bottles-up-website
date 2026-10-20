import { createClient } from 'npm:@supabase/supabase-js@2';
import Stripe from 'npm:stripe@17';
import { corsHeadersFor, handleOptions } from '../_shared/cors.ts';

// Bottle Payment Options section 9: "Refunds - Refund online payments through
// the payment provider. For club payments, the venue processes the refund
// first, then staff records the amount, breakdown and receipt." Manager-only
// (is_cms_admin) - refunds move money back out, more sensitive than
// recording a club payment, so gated tighter than the door-staff-inclusive
// actions elsewhere in this feature.
//
// Two ways in:
//   * with `request_id`: an approved online refund REQUEST (decided by the club's manager in the app, 20261023100000_refund_policy_and_requests.sql). The database claims
//     it (refund_request_begin: one caller only, so the money is returned once), the amount and reason come from the request, Stripe gets the request id as its
//     idempotency key (a retry after a lost answer cannot return it twice), and the request ends as completed (refund_request_finish) or failed with the note.
//   * without it: the original ad hoc refund by a BottlesUp admin, exactly as before.
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
    const body = await req.json();
    const { booking_id, refund_type, bottle_line_id, pos_reference, receipt_photo_path } = body;
    const requestId = typeof body.request_id === 'string' && body.request_id.trim() !== '' ? body.request_id.trim() : null;

    if (!booking_id || typeof booking_id !== 'string') {
      return json({ error: 'booking_id is required' }, 400);
    }
    if (refund_type !== 'online' && refund_type !== 'club') {
      return json({ error: 'refund_type must be online or club' }, 400);
    }
    if (requestId && refund_type !== 'online') {
      return json({ error: 'A refund request is returned online here; record a refund made at the club in the app' }, 400);
    }
    let amountCents = Number(body.amount_cents);
    let reason: unknown = body.reason;
    if (!requestId) {
      // For a request the amount and the reason come from the request itself, once it is claimed below.
      if (!Number.isInteger(amountCents) || amountCents <= 0) {
        return json({ error: 'amount_cents must be a positive integer' }, 400);
      }
      if (!reason || typeof reason !== 'string' || !reason.trim()) {
        return json({ error: 'A reason is required' }, 400);
      }
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

    const { data: admin } = await supabase.from('cms_admins').select('id, email').eq('id', userData.user.id).maybeSingle();
    if (!admin) {
      return json({ error: 'Forbidden - refunds require a manager' }, 403);
    }

    const { data: booking, error: bookingError } = await supabase
      .from('site_table_bookings')
      .select('id, amount_paid_cents, stripe_payment_intent_id')
      .eq('id', booking_id)
      .maybeSingle();
    if (bookingError || !booking) {
      return json({ error: 'Booking not found' }, 404);
    }
    // From here on, a request that was claimed MUST end as completed or failed, so it is never left claimed by a call that stopped half way.
    const failRequest = async (note: string) => {
      if (requestId) await supabase.rpc('refund_request_finish', { p_request: requestId, p_refund_id: null, p_ok: false, p_note: note });
    };
    if (requestId) {
      const { data: claimed, error: claimError } = await supabase.rpc('refund_request_begin', { p_request: requestId });
      if (claimError || !claimed) {
        return json({ error: claimError?.message ?? 'This refund request cannot be processed' }, 409);
      }
      if (claimed.booking_id !== booking_id) {
        await failRequest('The call named a different booking than the request.');
        return json({ error: 'The refund request belongs to a different booking' }, 400);
      }
      amountCents = Number(claimed.amount_cents);
      reason = claimed.reason;
    }
    if (amountCents > booking.amount_paid_cents) {
      await failRequest('The refund is more than the booking has taken in.');
      return json({ error: 'Refund amount cannot exceed what has been paid' }, 400);
    }

    let stripeRefundId: string | null = null;

    if (refund_type === 'online') {
      let paymentIntentId = booking.stripe_payment_intent_id as string | null;
      let stripeSessionIdForKeyLookup: string | null = null;

      if (bottle_line_id) {
        const { data: line } = await supabase
          .from('site_table_booking_bottles')
          .select('stripe_checkout_session_id')
          .eq('id', bottle_line_id)
          .eq('booking_id', booking_id)
          .maybeSingle();
        stripeSessionIdForKeyLookup = line?.stripe_checkout_session_id ?? null;
      }

      const { data: content } = await supabase.from('site_content').select('payments_mode').eq('id', 1).maybeSingle();
      const paymentsMode = content?.payments_mode === 'live' ? 'live' : 'test';
      const stripeSecretKey =
        paymentsMode === 'live'
          ? (Deno.env.get('STRIPE_SECRET_KEY_LIVE') ?? Deno.env.get('STRIPE_SECRET_KEY'))
          : (Deno.env.get('STRIPE_SECRET_KEY_TEST') ?? Deno.env.get('test_SK') ?? Deno.env.get('STRIPE_SECRET_KEY'));
      if (!stripeSecretKey) {
        await failRequest('Stripe is not configured.');
        return json({ error: 'Stripe is not configured' }, 500);
      }
      const stripe = new Stripe(stripeSecretKey, { apiVersion: '2024-06-20', httpClient: Stripe.createFetchHttpClient() });

      if (stripeSessionIdForKeyLookup) {
        const session = await stripe.checkout.sessions.retrieve(stripeSessionIdForKeyLookup);
        paymentIntentId = (typeof session.payment_intent === 'string' ? session.payment_intent : session.payment_intent?.id) ?? null;
      }

      if (!paymentIntentId) {
        await failRequest('There is no online payment on this booking to refund against.');
        return json({ error: 'No online payment found to refund against' }, 400);
      }

      try {
        const refund = await stripe.refunds.create(
          { payment_intent: paymentIntentId, amount: amountCents },
          requestId ? { idempotencyKey: `refund-request-${requestId}` } : undefined,
        );
        stripeRefundId = refund.id;
      } catch (err) {
        console.error('refund-table-booking-payment: Stripe refund failed', err);
        const message = err instanceof Error ? err.message : 'Stripe refund failed';
        await failRequest(`Stripe: ${message}`);
        return json({ error: message }, 502);
      }
    }

    const { data: refundRow, error: insertError } = await supabase
      .from('site_table_booking_refunds')
      .insert({
        booking_id,
        bottle_line_id: bottle_line_id ?? null,
        refund_type,
        amount_cents: amountCents,
        reason: String(reason).trim(),
        stripe_refund_id: stripeRefundId,
        pos_reference: pos_reference ?? null,
        receipt_photo_path: receipt_photo_path ?? null,
        recorded_by: userData.user.id,
      })
      .select('id')
      .single();
    if (insertError || !refundRow) {
      // The money HAS been returned (online) at this point, so a request is NOT marked failed: it stays "processing" for a person to put right.
      console.error('refund-table-booking-payment: insert failed', insertError, { requestId, stripeRefundId });
      return json({ error: 'The money was returned but the refund could not be recorded. Do not return it again.', request_id: requestId, stripe_refund_id: stripeRefundId }, 500);
    }

    const newAmountPaidCents = Math.max(booking.amount_paid_cents - amountCents, 0);
    const { error: updateError } = await supabase
      .from('site_table_bookings')
      .update({ amount_paid_cents: newAmountPaidCents })
      .eq('id', booking_id);
    if (updateError) {
      console.error('refund-table-booking-payment: amount_paid_cents update failed', updateError);
      return json({ error: 'Refund recorded but failed to update the booking balance' }, 500);
    }
    if (requestId) {
      await supabase.rpc('refund_request_finish', { p_request: requestId, p_refund_id: refundRow.id, p_ok: true, p_note: null });
    }

    await supabase.from('audit_log').insert({
      actor_id: userData.user.id,
      actor_email: admin.email,
      action: 'table_booking.refund_recorded',
      entity_type: 'site_table_bookings',
      entity_id: booking_id,
      details: {
        refund_id: refundRow.id,
        refund_type,
        amount_cents: amountCents,
        reason: String(reason).trim(),
        stripe_refund_id: stripeRefundId,
        request_id: requestId,
        new_amount_paid_cents: newAmountPaidCents,
      },
    });

    return json({ success: true, refund_id: refundRow.id, new_amount_paid_cents: newAmountPaidCents });
  } catch (error) {
    console.error('refund-table-booking-payment error:', error);
    return json({ error: 'Internal server error' }, 500);
  }
});
