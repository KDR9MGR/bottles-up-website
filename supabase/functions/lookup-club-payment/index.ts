import { createClient } from 'npm:@supabase/supabase-js@2';
import { corsHeadersFor, handleOptions } from '../_shared/cors.ts';

// Public, unauthenticated lookup by confirm_token - same "token is the
// capability" reasoning as site-booking-status's session_id lookup. Powers
// both the standalone /club-payment/confirm/:token page (emailed link, no
// account needed) and the in-app dashboard banner (which already knows the
// token from its own authenticated read of the booking's club payments).
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
    const { token } = await req.json();
    if (!token || typeof token !== 'string') {
      return json({ error: 'token is required' }, 400);
    }

    const supabase = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    );

    const { data: payment, error } = await supabase
      .from('site_table_booking_club_payments')
      .select(
        'id, billed_amount_cents, amount_paid_cents, payment_method, recorded_at, ' +
          'customer_confirmation_status, customer_confirmed_at, dispute_reason, ' +
          'booking:site_table_bookings(customer_name, confirmation_code, currency, ' +
          'table_type:site_table_types(name), venue:site_venues(name))',
      )
      .eq('confirm_token', token)
      .maybeSingle();

    if (error || !payment) {
      return json({ found: false });
    }

    const booking = payment.booking as unknown as {
      customer_name: string;
      confirmation_code: string;
      currency: string;
      table_type: { name: string };
      venue: { name: string };
    };

    return json({
      found: true,
      paymentId: payment.id,
      billedAmountCents: payment.billed_amount_cents,
      amountPaidCents: payment.amount_paid_cents,
      paymentMethod: payment.payment_method,
      recordedAt: payment.recorded_at,
      status: payment.customer_confirmation_status,
      confirmedAt: payment.customer_confirmed_at,
      disputeReason: payment.dispute_reason,
      customerName: booking.customer_name,
      confirmationCode: booking.confirmation_code,
      currency: booking.currency,
      tableTypeName: booking.table_type.name,
      venueName: booking.venue.name,
    });
  } catch (error) {
    console.error('lookup-club-payment error:', error);
    return json({ error: 'Internal server error' }, 500);
  }
});
