import { createClient } from 'npm:@supabase/supabase-js@2';
import Stripe from 'npm:stripe@17';
import { corsHeadersFor, handleOptions, isPreviewOrLocalOrigin } from '../_shared/cors.ts';
import { pickStripeKey } from '../_shared/splitPayments.ts';
import { parseCents, parseNote, parseUuid, refusalSentence, tipSessionParams, TIP_SESSION_MINUTES, type TipBegin } from '../_shared/billing.ts';

// Someone tips a creator's profile. The caller's own login is what the database checks (tip_begin: the profile can be tipped, the amount is in range, not their own); the money is recorded
// by the Stripe webhook, not here. Needs the creator_earnings switch on.
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
      return json({ error: 'Choose a profile and an amount.' }, 400);
    }
    const creator = parseUuid(body, 'creator_id', 'Choose a profile.');
    if (!creator.ok) return json({ error: creator.error }, 400);
    const amount = parseCents(body, 'amount_cents');
    if (amount === null) return json({ error: 'Choose an amount.' }, 400);

    const callerClient = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: userData, error: userError } = await callerClient.auth.getUser();
    if (userError || !userData?.user?.email) return json({ error: 'Sign in first.' }, 401);

    const { data: begin, error: beginError } = await callerClient.rpc('tip_begin', { p_creator: creator.id, p_amount_cents: amount, p_message: parseNote(body) });
    if (beginError) {
      const said = refusalSentence(beginError);
      if (said) return json({ error: said }, 409);
      console.error('create-tip-checkout: tip_begin failed', beginError.message);
      return json({ error: 'Internal server error' }, 500);
    }
    const b = begin as TipBegin;

    const supabase = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
    const { data: content } = await supabase.from('site_content').select('payments_mode').eq('id', 1).maybeSingle();
    const stripeSecretKey = pickStripeKey(content?.payments_mode, (k) => Deno.env.get(k));
    if (!stripeSecretKey) return json({ error: 'Payments are not set up yet.' }, 503);
    const stripe = new Stripe(stripeSecretKey, { apiVersion: '2024-06-20', httpClient: Stripe.createFetchHttpClient() });

    const origin = req.headers.get('origin') ?? '';
    const allowedOrigins = (Deno.env.get('ALLOWED_ORIGIN') ?? '').split(',').map((o: string) => o.trim()).filter(Boolean);
    const siteUrl = origin !== '' && (allowedOrigins.includes(origin) || isPreviewOrLocalOrigin(origin)) ? origin : (Deno.env.get('SITE_URL') || 'http://localhost:5173');

    const now = Date.now();
    const session = await stripe.checkout.sessions.create(tipSessionParams(b, userData.user.email, siteUrl, now) as unknown as Stripe.Checkout.SessionCreateParams);
    if (!session.url) {
      console.error('create-tip-checkout: Stripe gave no page for', session.id);
      return json({ error: 'Internal server error' }, 500);
    }
    const { error: attachError } = await supabase.rpc('tip_attach', { p_tip: b.tip_id, p_session: session.id });
    if (attachError) {
      console.error('create-tip-checkout: tip_attach failed', attachError.message);
      return json({ error: 'Internal server error' }, 500);
    }
    void TIP_SESSION_MINUTES;
    return json({ url: session.url, session_id: session.id, amount_cents: b.amount_cents });
  } catch (error) {
    console.error('create-tip-checkout error:', error);
    return json({ error: 'Internal server error' }, 500);
  }
});
