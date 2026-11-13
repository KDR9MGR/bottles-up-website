import { createClient } from 'npm:@supabase/supabase-js@2';
import Stripe from 'npm:stripe@17';
import { corsHeadersFor, handleOptions, isPreviewOrLocalOrigin } from '../_shared/cors.ts';
import { SESSION_MINUTES, parseId, pickStripeKey, refusalSentence, sessionParams, type BeginResult } from '../_shared/splitPayments.ts';

// A friend pays their share of a table. The caller's own login is what the database checks (split_share_begin: it is their request, the split is open, the deadline has not passed,
// the table still owes at least this much); the amount is the share's, never the app's. If a payment page was started in the last half hour it is handed back so nobody pays twice.
// Needs the split_payments switch on. The money is recorded by the Stripe webhook (or confirm-split-share), not here.
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
      return json({ error: 'Choose a request to pay.' }, 400);
    }
    const parsed = parseId(body, 'share_id');
    if (!parsed.ok) return json({ error: parsed.error }, 400);

    const callerClient = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: userData, error: userError } = await callerClient.auth.getUser();
    if (userError || !userData?.user?.email) return json({ error: 'Sign in first.' }, 401);

    const { data: begin, error: beginError } = await callerClient.rpc('split_share_begin', { p_share: parsed.id });
    if (beginError) {
      const said = refusalSentence(beginError);
      if (said) return json({ error: said }, 409);
      console.error('create-split-checkout: split_share_begin failed', beginError.message);
      return json({ error: 'Internal server error' }, 500);
    }
    const b = begin as BeginResult;

    const supabase = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
    const { data: content } = await supabase.from('site_content').select('payments_mode').eq('id', 1).maybeSingle();
    const stripeSecretKey = pickStripeKey(content?.payments_mode, (k) => Deno.env.get(k));
    if (!stripeSecretKey) return json({ error: 'Payments are not set up yet.' }, 503);
    const stripe = new Stripe(stripeSecretKey, { apiVersion: '2024-06-20', httpClient: Stripe.createFetchHttpClient() });

    // A page that was started less than half an hour ago and is still open: reuse it.
    if (b.pending_session) {
      try {
        const open = await stripe.checkout.sessions.retrieve(b.pending_session);
        if (open.status === 'open' && open.url) return json({ url: open.url, session_id: open.id });
      } catch (err) {
        console.error('create-split-checkout: could not look at the open page', b.pending_session, (err as { code?: string })?.code ?? 'no code');
      }
    }

    const origin = req.headers.get('origin') ?? '';
    // The app sends no Origin, so this is the website's own address then; a made-up Origin is never trusted as a place to send someone after paying.
    const allowedOrigins = (Deno.env.get('ALLOWED_ORIGIN') ?? '').split(',').map((o: string) => o.trim()).filter(Boolean);
    const siteUrl = origin !== '' && (allowedOrigins.includes(origin) || isPreviewOrLocalOrigin(origin)) ? origin : (Deno.env.get('SITE_URL') || 'http://localhost:5173');

    const now = Date.now();
    const session = await stripe.checkout.sessions.create(sessionParams(b, userData.user.email, siteUrl, now) as unknown as Stripe.Checkout.SessionCreateParams);
    if (!session.url) {
      console.error('create-split-checkout: Stripe gave no page for', session.id);
      return json({ error: 'Internal server error' }, 500);
    }
    const { error: attachError } = await supabase.rpc('split_share_attach', {
      p_share: b.id,
      p_session: session.id,
      p_until: new Date(now + SESSION_MINUTES * 60 * 1000).toISOString(),
    });
    if (attachError) {
      console.error('create-split-checkout: split_share_attach failed', attachError.message);
      return json({ error: 'Internal server error' }, 500);
    }
    return json({ url: session.url, session_id: session.id });
  } catch (error) {
    console.error('create-split-checkout error:', error);
    return json({ error: 'Internal server error' }, 500);
  }
});
