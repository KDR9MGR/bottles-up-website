import { createClient } from 'npm:@supabase/supabase-js@2';
import { corsHeadersFor, handleOptions } from '../_shared/cors.ts';
import { validateTierAccessCode } from '../_shared/tierAccessCode.ts';

// Public preview endpoint a visitor's browser calls when they type an access
// code into a gated ticket tier, so the price/purchase option can unlock
// before checkout. site-create-checkout-session re-runs this same check from
// scratch and never trusts that the client already validated a code.
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
    const { tier_id, code } = await req.json();
    if (typeof tier_id !== 'string' || !tier_id) {
      return json({ error: 'tier_id is required' }, 400);
    }

    const supabase = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);

    const { data: tier } = await supabase
      .from('site_ticket_tiers')
      .select('id, price_cents, currency, requires_access_code, events:site_events!inner(status)')
      .eq('id', tier_id)
      .single();

    if (!tier || (tier.events as unknown as { status: string }).status !== 'published') {
      return json({ valid: false, message: 'Ticket type not found' });
    }
    if (!tier.requires_access_code) {
      return json({ valid: false, message: 'This ticket type does not require an access code' });
    }

    const result = await validateTierAccessCode(supabase, tier_id, code);
    if (!result.valid) {
      return json(result);
    }

    return json({ valid: true, message: result.message, price_cents: tier.price_cents, currency: tier.currency });
  } catch (error) {
    console.error('validate-tier-access-code error:', error);
    return json({ error: 'Internal server error' }, 500);
  }
});
