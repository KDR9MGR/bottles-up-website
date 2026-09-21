import { createClient } from 'npm:@supabase/supabase-js@2';
import Stripe from 'npm:stripe@17';
import { corsHeadersFor, handleOptions } from '../_shared/cors.ts';
import { fulfillBottleAddon } from '../_shared/fulfillment.ts';

// Public, unauthenticated lookup by Stripe checkout session id - same reasoning as
// site-booking-status: the session id is the capability, unguessable and known
// only to the customer who was just redirected here after paying for an addon.
// Self-heals when the webhook hasn't fired yet, exactly like site-booking-status
// does for the original checkout - safe to call repeatedly, fulfillment is
// idempotent.
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
    const { session_id } = await req.json();
    if (!session_id || typeof session_id !== 'string') {
      return json({ error: 'session_id is required' }, 400);
    }

    const supabase = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    );

    const { data: lines, error: linesError } = await supabase
      .from('site_table_booking_bottles')
      .select('booking_id, payment_status')
      .eq('stripe_checkout_session_id', session_id);

    if (linesError || !lines || lines.length === 0) {
      return json({ status: 'not_found' });
    }

    const bookingId = lines[0].booking_id;

    if (lines.every((l: { payment_status: string }) => l.payment_status === 'paid')) {
      return json({ status: 'paid', booking_id: bookingId });
    }

    const stripeSecretKey = session_id.startsWith('cs_live_')
      ? (Deno.env.get('STRIPE_SECRET_KEY_LIVE') ?? Deno.env.get('STRIPE_SECRET_KEY'))
      : (Deno.env.get('STRIPE_SECRET_KEY_TEST') ?? Deno.env.get('test_SK') ?? Deno.env.get('STRIPE_SECRET_KEY'));
    if (!stripeSecretKey) {
      return json({ status: 'pending' });
    }

    try {
      const stripe = new Stripe(stripeSecretKey, {
        apiVersion: '2024-06-20',
        httpClient: Stripe.createFetchHttpClient(),
      });
      const session = await stripe.checkout.sessions.retrieve(session_id);
      if (session.payment_status === 'paid') {
        await fulfillBottleAddon(supabase, bookingId, session_id, session.amount_total ?? 0);
        return json({ status: 'paid', booking_id: bookingId });
      }
    } catch (err) {
      console.error('confirm-bottle-addon: Stripe verification failed', session_id, err);
    }

    return json({ status: 'pending', booking_id: bookingId });
  } catch (error) {
    console.error('confirm-bottle-addon error:', error);
    return json({ error: 'Internal server error' }, 500);
  }
});
