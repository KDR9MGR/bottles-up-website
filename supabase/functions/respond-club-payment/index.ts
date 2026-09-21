import { createClient } from 'npm:@supabase/supabase-js@2';
import { corsHeadersFor, handleOptions } from '../_shared/cors.ts';
import { sendClubPaymentDisputeNotificationEmail } from '../_shared/clubPaymentEmail.ts';

// Public, unauthenticated - the confirm_token is the capability (same
// reasoning as lookup-club-payment). The one and only place a club payment's
// customer_confirmation_status ever changes, whether the customer got here
// from the emailed link or the in-app dashboard banner, so there's exactly
// one code path to reason about. Only ever transitions out of 'pending' -
// once answered, the record is locked (re-litigating a decision goes through
// staff/manager channels, not by revisiting the same link).
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
    const { token, action, reason, evidence_base64, evidence_filename } = await req.json();

    if (!token || typeof token !== 'string') {
      return json({ error: 'token is required' }, 400);
    }
    if (action !== 'confirm' && action !== 'dispute') {
      return json({ error: 'Invalid action' }, 400);
    }
    if (action === 'dispute' && (typeof reason !== 'string' || !reason.trim())) {
      return json({ error: 'A reason is required to report an issue' }, 400);
    }

    const supabase = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    );

    const { data: payment, error: paymentError } = await supabase
      .from('site_table_booking_club_payments')
      .select(
        'id, customer_confirmation_status, billed_amount_cents, amount_paid_cents, payment_method, ' +
          'booking:site_table_bookings(customer_name, customer_email, confirmation_code, currency, ' +
          'table_type:site_table_types(name), venue:site_venues(name))',
      )
      .eq('confirm_token', token)
      .maybeSingle();

    if (paymentError || !payment) {
      return json({ error: 'Payment record not found' }, 404);
    }
    if (payment.customer_confirmation_status !== 'pending') {
      return json({ success: false, error: 'already_responded', status: payment.customer_confirmation_status });
    }

    const booking = payment.booking as unknown as {
      customer_name: string;
      customer_email: string;
      confirmation_code: string;
      currency: string;
      table_type: { name: string };
      venue: { name: string };
    };

    if (action === 'confirm') {
      const { error: updateError } = await supabase
        .from('site_table_booking_club_payments')
        .update({ customer_confirmation_status: 'confirmed', customer_confirmed_at: new Date().toISOString() })
        .eq('id', payment.id);
      if (updateError) {
        console.error('respond-club-payment: confirm update failed', updateError);
        return json({ error: 'Failed to record your response' }, 500);
      }

      await supabase.from('audit_log').insert({
        actor_email: booking.customer_email,
        action: 'table_booking.club_payment_confirmed',
        entity_type: 'site_table_booking_club_payments',
        entity_id: payment.id,
      });

      return json({ success: true, status: 'confirmed' });
    }

    // Dispute: upload evidence (if any) before flipping status, so a storage
    // failure never leaves the record silently missing its attachment.
    let evidencePath: string | null = null;
    if (typeof evidence_base64 === 'string' && evidence_base64) {
      try {
        const bytes = Uint8Array.from(atob(evidence_base64), (c) => c.charCodeAt(0));
        const ext = (typeof evidence_filename === 'string' && evidence_filename.split('.').pop()) || 'jpg';
        const path = `disputes/${payment.id}/${crypto.randomUUID()}.${ext}`;
        const { error: uploadError } = await supabase.storage
          .from('club-payment-receipts')
          .upload(path, bytes, { contentType: `image/${ext === 'jpg' ? 'jpeg' : ext}` });
        if (uploadError) {
          console.error('respond-club-payment: evidence upload failed', uploadError);
        } else {
          evidencePath = path;
        }
      } catch (err) {
        console.error('respond-club-payment: evidence decode failed', err);
      }
    }

    const { error: updateError } = await supabase
      .from('site_table_booking_club_payments')
      .update({
        customer_confirmation_status: 'disputed',
        dispute_reason: reason.trim(),
        dispute_evidence_path: evidencePath,
      })
      .eq('id', payment.id);
    if (updateError) {
      console.error('respond-club-payment: dispute update failed', updateError);
      return json({ error: 'Failed to record your response' }, 500);
    }

    await supabase.from('audit_log').insert({
      actor_email: booking.customer_email,
      action: 'table_booking.club_payment_disputed',
      entity_type: 'site_table_booking_club_payments',
      entity_id: payment.id,
      details: { reason: reason.trim(), has_evidence: !!evidencePath },
    });

    const { data: content } = await supabase.from('site_content').select('contact_email').eq('id', 1).maybeSingle();
    if (content?.contact_email) {
      const notifyEmail = await sendClubPaymentDisputeNotificationEmail({
        toEmail: content.contact_email,
        venueName: booking.venue.name,
        tableTypeName: booking.table_type.name,
        confirmationCode: booking.confirmation_code,
        customerName: booking.customer_name,
        customerEmail: booking.customer_email,
        billedAmountCents: payment.billed_amount_cents,
        amountPaidCents: payment.amount_paid_cents,
        paymentMethod: payment.payment_method,
        currency: booking.currency,
        disputeReason: reason.trim(),
        hasEvidence: !!evidencePath,
      });
      if (!notifyEmail.sent) {
        console.error('respond-club-payment: manager notification email failed', notifyEmail.error);
      }
    }

    return json({ success: true, status: 'disputed' });
  } catch (error) {
    console.error('respond-club-payment error:', error);
    return json({ error: 'Internal server error' }, 500);
  }
});
