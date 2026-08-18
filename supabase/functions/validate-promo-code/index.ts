import { createClient } from 'npm:@supabase/supabase-js@2';
import { corsHeadersFor, handleOptions } from '../_shared/cors.ts';
import { validatePromoCode } from '../_shared/promoCode.ts';

// Public preview endpoint the checkout dialogs call when a customer types a
// promo code, so they see the discount before starting Stripe checkout. Does
// NOT increment used_count - that only happens once payment actually
// completes, via fulfillment.ts. The checkout-creation functions re-run this
// same validation from scratch and never trust the discount this returns.
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
    const { code, applies_to, venue_id, subtotal_cents } = await req.json();

    if (typeof code !== 'string' || !code.trim()) {
      return json({ valid: false, message: 'Enter a promo code' });
    }
    if (applies_to !== 'tickets' && applies_to !== 'tables') {
      return json({ error: 'Invalid applies_to' }, 400);
    }
    const subtotal = Number(subtotal_cents);
    if (!Number.isFinite(subtotal) || subtotal < 0) {
      return json({ error: 'Invalid subtotal' }, 400);
    }

    const supabase = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    );

    const result = await validatePromoCode(supabase, {
      code,
      appliesTo: applies_to,
      venueId: typeof venue_id === 'string' ? venue_id : null,
      subtotalCents: subtotal,
    });

    return json(result);
  } catch (error) {
    console.error('validate-promo-code error:', error);
    return json({ error: 'Internal server error' }, 500);
  }
});
