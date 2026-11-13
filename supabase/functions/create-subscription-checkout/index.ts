import { createClient } from 'npm:@supabase/supabase-js@2';
import Stripe from 'npm:stripe@17';
import { corsHeadersFor, handleOptions, isPreviewOrLocalOrigin } from '../_shared/cors.ts';
import { pickStripeKey } from '../_shared/splitPayments.ts';
import { parsePlan, parseUuid, refusalSentence, subscriptionSessionParams, type SubBegin } from '../_shared/billing.ts';

// The owner of a professional's own profile subscribes it. The caller's own login is what the database checks (sub_begin: they own the profile, it has no live subscription) and the amount
// is the database's, never the app's. The subscription becomes live when Stripe says so (the webhook), not here. Needs the subscriptions switch on.
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
      return json({ error: 'Choose a profile and a plan.' }, 400);
    }
    const profile = parseUuid(body, 'profile_id', 'Choose a profile.');
    if (!profile.ok) return json({ error: profile.error }, 400);
    const plan = parsePlan(body);
    if (!plan) return json({ error: 'Choose monthly or yearly.' }, 400);

    const callerClient = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: userData, error: userError } = await callerClient.auth.getUser();
    if (userError || !userData?.user?.email) return json({ error: 'Sign in first.' }, 401);

    const { data: begin, error: beginError } = await callerClient.rpc('sub_begin', { p_profile: profile.id, p_plan: plan });
    if (beginError) {
      const said = refusalSentence(beginError);
      if (said) return json({ error: said }, 409);
      console.error('create-subscription-checkout: sub_begin failed', beginError.message);
      return json({ error: 'Internal server error' }, 500);
    }
    const b = begin as SubBegin;

    const supabase = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
    const { data: content } = await supabase.from('site_content').select('payments_mode').eq('id', 1).maybeSingle();
    const stripeSecretKey = pickStripeKey(content?.payments_mode, (k) => Deno.env.get(k));
    if (!stripeSecretKey) return json({ error: 'Payments are not set up yet.' }, 503);
    const stripe = new Stripe(stripeSecretKey, { apiVersion: '2024-06-20', httpClient: Stripe.createFetchHttpClient() });

    const origin = req.headers.get('origin') ?? '';
    const allowedOrigins = (Deno.env.get('ALLOWED_ORIGIN') ?? '').split(',').map((o: string) => o.trim()).filter(Boolean);
    const siteUrl = origin !== '' && (allowedOrigins.includes(origin) || isPreviewOrLocalOrigin(origin)) ? origin : (Deno.env.get('SITE_URL') || 'http://localhost:5173');

    const session = await stripe.checkout.sessions.create(subscriptionSessionParams(b, userData.user.email, siteUrl) as unknown as Stripe.Checkout.SessionCreateParams);
    if (!session.url) {
      console.error('create-subscription-checkout: Stripe gave no page for', session.id);
      return json({ error: 'Internal server error' }, 500);
    }
    const { error: attachError } = await supabase.rpc('sub_attach', { p_sub: b.subscription_id, p_session: session.id });
    if (attachError) {
      console.error('create-subscription-checkout: sub_attach failed', attachError.message);
      return json({ error: 'Internal server error' }, 500);
    }
    return json({ url: session.url, session_id: session.id, amount_cents: b.amount_cents, plan: b.plan });
  } catch (error) {
    console.error('create-subscription-checkout error:', error);
    return json({ error: 'Internal server error' }, 500);
  }
});
