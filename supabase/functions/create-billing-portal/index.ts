import { createClient } from 'npm:@supabase/supabase-js@2';
import Stripe from 'npm:stripe@17';
import { corsHeadersFor, handleOptions, isPreviewOrLocalOrigin } from '../_shared/cors.ts';
import { pickStripeKey } from '../_shared/splitPayments.ts';
import { parseUuid, refusalSentence } from '../_shared/billing.ts';

// The owner of a subscribed profile opens Stripe's billing page (to change the card, see invoices or cancel). The database says whether the caller owns the profile and which Stripe
// customer it has (sub_customer); nothing is changed here, Stripe's own messages tell the website what happened.
Deno.serve(async (req: Request) => {
  const preflight = handleOptions(req);
  if (preflight) return preflight;

  const cors = corsHeadersFor(req);
  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405);

  const authHeader = req.headers.get('Authorization');
  if (!authHeader) return json({ error: 'Sign in first.' }, 401);

  try {
    let body: unknown;
    try {
      body = await req.json();
    } catch {
      return json({ error: 'Choose a profile.' }, 400);
    }
    const profile = parseUuid(body, 'profile_id', 'Choose a profile.');
    if (!profile.ok) return json({ error: profile.error }, 400);

    const callerClient = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: userData, error: userError } = await callerClient.auth.getUser();
    if (userError || !userData?.user) return json({ error: 'Sign in first.' }, 401);

    const { data: customer, error: customerError } = await callerClient.rpc('sub_customer', { p_profile: profile.id });
    if (customerError) {
      const said = refusalSentence(customerError);
      if (said) return json({ error: said }, 409);
      console.error('create-billing-portal: sub_customer failed', customerError.message);
      return json({ error: 'Internal server error' }, 500);
    }
    if (typeof customer !== 'string' || !customer.startsWith('cus_')) return json({ error: 'This profile has no subscription to manage.' }, 409);

    const supabase = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
    const { data: content } = await supabase.from('site_content').select('payments_mode').eq('id', 1).maybeSingle();
    const stripeSecretKey = pickStripeKey(content?.payments_mode, (k) => Deno.env.get(k));
    if (!stripeSecretKey) return json({ error: 'Payments are not set up yet.' }, 503);
    const stripe = new Stripe(stripeSecretKey, { apiVersion: '2024-06-20', httpClient: Stripe.createFetchHttpClient() });

    const origin = req.headers.get('origin') ?? '';
    const allowedOrigins = (Deno.env.get('ALLOWED_ORIGIN') ?? '').split(',').map((o: string) => o.trim()).filter(Boolean);
    const siteUrl = origin !== '' && (allowedOrigins.includes(origin) || isPreviewOrLocalOrigin(origin)) ? origin : (Deno.env.get('SITE_URL') || 'http://localhost:5173');

    const portal = await stripe.billingPortal.sessions.create({ customer, return_url: `${siteUrl}/pay/subscription-thanks?portal=1` });
    return json({ url: portal.url });
  } catch (error) {
    console.error('create-billing-portal error:', error);
    return json({ error: 'Internal server error' }, 500);
  }
});
