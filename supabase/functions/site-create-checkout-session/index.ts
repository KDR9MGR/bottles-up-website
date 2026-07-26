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
    const { event_id, tier_id, quantity, customer_name, customer_email, customer_phone } = await req.json();

    if (!event_id || !tier_id || !customer_name || !customer_email) {
      return json({ error: 'Missing required fields' }, 400);
    }
    const qty = Number(quantity);
    if (!Number.isInteger(qty) || qty < 1 || qty > 10) {
      return json({ error: 'Invalid quantity' }, 400);
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

    // Re-read the tier + event server-side. The client never gets to say what the price is.
    const { data: tier, error: tierError } = await supabase
      .from('site_ticket_tiers')
      .select('*, events:site_events!inner(id, title, status)')
      .eq('id', tier_id)
      .eq('event_id', event_id)
      .single();

    if (tierError || !tier) {
      return json({ error: 'Ticket tier not found' }, 404);
    }
    if (tier.events.status !== 'published') {
      return json({ error: 'This event is not currently on sale' }, 400);
    }
    // Best-effort capacity check against tickets already confirmed paid. Not airtight under
    // heavy concurrent checkouts (sold_count only increments on webhook fulfillment, not at
    // checkout-creation time), but sufficient at this venue's scale - documented, not silently assumed safe.
    if (tier.sold_count + qty > tier.capacity) {
      return json({ error: 'Not enough tickets left in this tier' }, 409);
    }

    const amountTotalCents = tier.price_cents * qty;

    const { data: order, error: orderError } = await supabase
      .from('site_orders')
      .insert({
        event_id,
        tier_id,
        customer_name,
        customer_email,
        customer_phone: customer_phone ?? null,
        quantity: qty,
        amount_total_cents: amountTotalCents,
        currency: tier.currency,
        status: 'pending',
      })
      .select('id')
      .single();

    if (orderError || !order) {
      console.error('order insert error:', orderError);
      return json({ error: 'Failed to start order' }, 500);
    }

    // Send the buyer back to wherever they started checkout (localhost in dev, the real
    // domain in prod) - but only if that origin is on the CORS allow-list, so a forged
    // Origin header can't redirect customers to an arbitrary site. SITE_URL is the fallback.
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
            currency: tier.currency,
            product_data: { name: `${tier.events.title} - ${tier.name}` },
            unit_amount: tier.price_cents,
          },
          quantity: qty,
        },
      ],
      // Keep the checkout in the tier's own currency (CAD) - without this, Stripe's
      // Adaptive Pricing shows buyers a "choose a currency" step with a converted price.
      adaptive_pricing: { enabled: false },
      metadata: { order_id: order.id },
      success_url: `${siteUrl}/booking/success?session_id={CHECKOUT_SESSION_ID}`,
      cancel_url: `${siteUrl}/booking/cancel`,
    });

    await supabase.from('site_orders').update({ stripe_checkout_session_id: session.id }).eq('id', order.id);

    return json({ url: session.url });
  } catch (error) {
    console.error('site-create-checkout-session error:', error);
    return json({ error: 'Internal server error' }, 500);
  }
});
