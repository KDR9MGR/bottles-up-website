import { createClient } from 'npm:@supabase/supabase-js@2';
import Stripe from 'npm:stripe@17';
import { pickStripeKey, refundDueShares, type DbLike, type StripeLike } from '../_shared/splitPayments.ts';

// Pays back every friend's share that is due: a split that was cancelled, a booking the venue cancelled or refunded, a host whose account is gone, money that could not be applied.
// Run it every few minutes with the SERVICE ROLE key as the bearer token (not for browsers, takes no input). Until it is scheduled only the refunds done at the moment of
// cancelling (cancel-split) and of a payment that could not be applied happen; the rest wait here, and nothing is lost.
function sameSecret(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

Deno.serve(async (req: Request) => {
  const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });

  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405);

  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  const supplied = /^Bearer\s+(\S+)$/i.exec(req.headers.get('Authorization') ?? '')?.[1];
  if (!serviceKey || !supplied || !sameSecret(supplied, serviceKey)) return json({ error: 'Unauthorized' }, 401);

  try {
    const supabase = createClient(Deno.env.get('SUPABASE_URL')!, serviceKey);
    const { data: content } = await supabase.from('site_content').select('payments_mode').eq('id', 1).maybeSingle();
    const stripeSecretKey = pickStripeKey(content?.payments_mode, (k) => Deno.env.get(k));
    if (!stripeSecretKey) return json({ error: 'Payments are not set up yet.' }, 503);
    const stripe = new Stripe(stripeSecretKey, { apiVersion: '2024-06-20', httpClient: Stripe.createFetchHttpClient() });
    return json(await refundDueShares(supabase as unknown as DbLike, stripe as unknown as StripeLike, {}));
  } catch (error) {
    console.error('process-split-refunds error:', error);
    return json({ error: 'Internal server error' }, 500);
  }
});
