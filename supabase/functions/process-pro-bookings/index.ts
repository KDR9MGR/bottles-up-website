import { createClient } from 'npm:@supabase/supabase-js@2';
import Stripe from 'npm:stripe@17';
import { pickStripeKey, type DbLike, type StripeLike } from '../_shared/splitPayments.ts';
import { refundDuePayments } from '../_shared/proPayments.ts';

// The marketplace's housekeeping, and the refunds that wait: unpaid acceptances lapse, a balance not paid by its date cancels the booking, closed accounts are dealt with, work done
// and not disputed is confirmed after a few days (market_housekeeping), then every payment that is due back is paid back through Stripe. Safe to run as often as you like.
// Run it every ten minutes with the SERVICE ROLE key as the bearer token (not for browsers, takes no input). Until it is scheduled nothing lapses on its own and refunds from a decided
// dispute wait; nothing is lost.
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
    const { data: housekeeping, error } = await supabase.rpc('market_housekeeping');
    if (error) {
      console.error('process-pro-bookings: market_housekeeping failed', error.message);
      return json({ error: 'Internal server error' }, 500);
    }
    const { data: content } = await supabase.from('site_content').select('payments_mode').eq('id', 1).maybeSingle();
    const stripeSecretKey = pickStripeKey(content?.payments_mode, (k) => Deno.env.get(k));
    if (!stripeSecretKey) return json({ housekeeping, refunded: 0, failed: 0, refunds: 'Payments are not set up yet.' });
    const stripe = new Stripe(stripeSecretKey, { apiVersion: '2024-06-20', httpClient: Stripe.createFetchHttpClient() });
    const done = await refundDuePayments(supabase as unknown as DbLike, stripe as unknown as StripeLike, {});
    return json({ housekeeping, ...done });
  } catch (error) {
    console.error('process-pro-bookings error:', error);
    return json({ error: 'Internal server error' }, 500);
  }
});
