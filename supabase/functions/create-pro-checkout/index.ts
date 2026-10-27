import { createClient } from 'npm:@supabase/supabase-js@2';
import Stripe from 'npm:stripe@17';
import { corsHeadersFor, handleOptions, isPreviewOrLocalOrigin } from '../_shared/cors.ts';
import { parseId, pickStripeKey } from '../_shared/splitPayments.ts';
import { PRO_SESSION_MINUTES, proSessionParams, refusalSentence, type ProBegin } from '../_shared/proPayments.ts';

// The customer pays the deposit (or the whole price) of a professional's booking, or the balance later. The caller's own login is what the database checks (pro_payment_begin: it is their
// booking, it can be paid now, and how much); the amount is the database's, never the app's. A payment page opened in the last half hour is handed back so nobody pays twice.
// The money is recorded by the Stripe webhook (or confirm-pro-payment), not here. Needs the marketplace switch on.
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
      return json({ error: 'Choose a booking.' }, 400);
    }
    const parsed = parseId(body, 'booking_id');
    if (!parsed.ok) return json({ error: parsed.error }, 400);

    const callerClient = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: userData, error: userError } = await callerClient.auth.getUser();
    if (userError || !userData?.user?.email) return json({ error: 'Sign in first.' }, 401);

    const { data: begin, error: beginError } = await callerClient.rpc('pro_payment_begin', { p_booking: parsed.id });
    if (beginError) {
      const said = refusalSentence(beginError);
      if (said) return json({ error: said }, 409);
      console.error('create-pro-checkout: pro_payment_begin failed', beginError.message);
      return json({ error: 'Internal server error' }, 500);
    }
    const b = begin as ProBegin;

    const supabase = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
    const { data: content } = await supabase.from('site_content').select('payments_mode').eq('id', 1).maybeSingle();
    const stripeSecretKey = pickStripeKey(content?.payments_mode, (k) => Deno.env.get(k));
    if (!stripeSecretKey) return json({ error: 'Payments are not set up yet.' }, 503);
    const stripe = new Stripe(stripeSecretKey, { apiVersion: '2024-06-20', httpClient: Stripe.createFetchHttpClient() });

    if (b.pending_session) {
      try {
        const open = await stripe.checkout.sessions.retrieve(b.pending_session);
        if (open.status === 'open' && open.url) return json({ url: open.url, session_id: open.id, kind: b.kind, amount_cents: b.amount_cents });
      } catch (err) {
        console.error('create-pro-checkout: could not look at the open page', b.pending_session, (err as { code?: string })?.code ?? 'no code');
      }
    }

    const origin = req.headers.get('origin') ?? '';
    const allowedOrigins = (Deno.env.get('ALLOWED_ORIGIN') ?? '').split(',').map((o: string) => o.trim()).filter(Boolean);
    const siteUrl = origin !== '' && (allowedOrigins.includes(origin) || isPreviewOrLocalOrigin(origin)) ? origin : (Deno.env.get('SITE_URL') || 'http://localhost:5173');

    const now = Date.now();
    const session = await stripe.checkout.sessions.create(proSessionParams(b, userData.user.email, siteUrl, now) as unknown as Stripe.Checkout.SessionCreateParams);
    if (!session.url) {
      console.error('create-pro-checkout: Stripe gave no page for', session.id);
      return json({ error: 'Internal server error' }, 500);
    }
    const { error: attachError } = await supabase.rpc('pro_payment_attach', {
      p_payment: b.payment_id,
      p_session: session.id,
      p_until: new Date(now + PRO_SESSION_MINUTES * 60 * 1000).toISOString(),
    });
    if (attachError) {
      console.error('create-pro-checkout: pro_payment_attach failed', attachError.message);
      return json({ error: 'Internal server error' }, 500);
    }
    return json({ url: session.url, session_id: session.id, kind: b.kind, amount_cents: b.amount_cents });
  } catch (error) {
    console.error('create-pro-checkout error:', error);
    return json({ error: 'Internal server error' }, 500);
  }
});
