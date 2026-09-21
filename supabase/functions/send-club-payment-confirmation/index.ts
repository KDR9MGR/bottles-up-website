import { createClient } from 'npm:@supabase/supabase-js@2';
import { corsHeadersFor, handleOptions, isPreviewOrLocalOrigin } from '../_shared/cors.ts';
import { sendClubPaymentConfirmationEmail } from '../_shared/clubPaymentEmail.ts';

// Called by the staff client (door check-in or CMS) right after
// record_club_payment() succeeds - section 6 of Bottle Payment Options.
// Authenticated the same way as add-table-booking-bottles/resend-table-
// booking-email: caller must be signed in, and here specifically an admin or
// door staffer (only they can ever have just recorded a payment).
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
    const { payment_id } = await req.json();
    if (!payment_id || typeof payment_id !== 'string') {
      return json({ error: 'payment_id is required' }, 400);
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

    const [{ data: admin }, { data: staff }] = await Promise.all([
      supabase.from('cms_admins').select('id').eq('id', userData.user.id).maybeSingle(),
      supabase.from('door_staff').select('id').eq('id', userData.user.id).maybeSingle(),
    ]);
    if (!admin && !staff) {
      return json({ error: 'Forbidden' }, 403);
    }

    const { data: payment, error: paymentError } = await supabase
      .from('site_table_booking_club_payments')
      .select(
        'id, confirm_token, billed_amount_cents, amount_paid_cents, payment_method, ' +
          'booking:site_table_bookings(customer_name, customer_email, confirmation_code, currency, ' +
          'table_type:site_table_types(name), venue:site_venues(name))',
      )
      .eq('id', payment_id)
      .single();

    if (paymentError || !payment) {
      return json({ error: 'Payment record not found' }, 404);
    }

    const booking = payment.booking as unknown as {
      customer_name: string;
      customer_email: string;
      confirmation_code: string;
      currency: string;
      table_type: { name: string };
      venue: { name: string };
    };

    const origin = req.headers.get('origin') ?? '';
    const allowedOrigins = (Deno.env.get('ALLOWED_ORIGIN') ?? '').split(',').map((o: string) => o.trim());
    const siteUrl = allowedOrigins.includes(origin) || isPreviewOrLocalOrigin(origin)
      ? origin
      : (Deno.env.get('SITE_URL') ?? 'http://localhost:5173');

    const email = await sendClubPaymentConfirmationEmail({
      toEmail: booking.customer_email,
      toName: booking.customer_name,
      venueName: booking.venue.name,
      tableTypeName: booking.table_type.name,
      confirmationCode: booking.confirmation_code,
      billedAmountCents: payment.billed_amount_cents,
      amountPaidCents: payment.amount_paid_cents,
      paymentMethod: payment.payment_method,
      currency: booking.currency,
      confirmUrl: `${siteUrl}/club-payment/confirm/${payment.confirm_token}`,
    });

    if (!email.sent) {
      return json({ error: email.error ?? 'Email provider failed to send' }, 500);
    }

    await supabase
      .from('site_table_booking_club_payments')
      .update({ customer_notified_at: new Date().toISOString() })
      .eq('id', payment_id);

    return json({ success: true });
  } catch (error) {
    console.error('send-club-payment-confirmation error:', error);
    return json({ error: 'Internal server error' }, 500);
  }
});
