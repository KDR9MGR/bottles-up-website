import { createClient } from 'npm:@supabase/supabase-js@2';
import Stripe from 'npm:stripe@17';
import { fulfillTicketOrder, fulfillTableBooking } from '../_shared/fulfillment.ts';

const cryptoProvider = Stripe.createSubtleCryptoProvider();

Deno.serve(async (req: Request) => {
  if (req.method !== 'POST') {
    return new Response('Method not allowed', { status: 405 });
  }

  const signature = req.headers.get('stripe-signature');
  const body = await req.text();

  const stripeSecretKey =
    Deno.env.get('STRIPE_SECRET_KEY_LIVE') ??
    Deno.env.get('STRIPE_SECRET_KEY_TEST') ??
    Deno.env.get('STRIPE_SECRET_KEY') ??
    Deno.env.get('test_SK');

  if (!stripeSecretKey) {
    return new Response('Stripe is not configured', { status: 500 });
  }

  const stripe = new Stripe(stripeSecretKey, {
    apiVersion: '2024-06-20',
    httpClient: Stripe.createFetchHttpClient(),
  });

  const webhookSecrets = [
    Deno.env.get('STRIPE_WEBHOOK_SECRET_TEST'),
    Deno.env.get('STRIPE_WEBHOOK_SECRET_LIVE'),
    Deno.env.get('STRIPE_WEBHOOK_SECRET'),
  ].filter((s): s is string => !!s);

  let event: Stripe.Event;
  try {
    let lastError: unknown;
    let verified: Stripe.Event | null = null;

    for (const secret of webhookSecrets) {
      try {
        verified = await stripe.webhooks.constructEventAsync(body, signature!, secret, undefined, cryptoProvider);
        break;
      } catch (err) {
        lastError = err;
      }
    }

    if (!verified) {
      throw lastError ?? new Error('Webhook signature verification failed');
    }

    event = verified;
  } catch (err) {
    console.error('Webhook signature verification failed:', err);
    return new Response('Invalid signature', { status: 400 });
  }

  const supabase = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  );

  if (event.type === 'checkout.session.completed') {
    const session = event.data.object as Stripe.Checkout.Session;
    const orderId = session.metadata?.order_id;
    const bookingId = session.metadata?.booking_id;
    const paymentIntentId =
      (typeof session.payment_intent === 'string' ? session.payment_intent : session.payment_intent?.id) ?? null;

    if (!orderId && !bookingId) {
      console.error('checkout.session.completed with no order_id/booking_id metadata:', session.id);
      return new Response('ok', { status: 200 });
    }

    if (bookingId) {
      await fulfillTableBooking(supabase, bookingId, paymentIntentId);
    } else if (orderId) {
      await fulfillTicketOrder(supabase, orderId, paymentIntentId);
    }
  }

  return new Response('ok', { status: 200 });
});
