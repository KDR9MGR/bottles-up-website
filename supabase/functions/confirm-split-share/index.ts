import { createClient } from 'npm:@supabase/supabase-js@2';
import Stripe from 'npm:stripe@17';
import { corsHeadersFor, handleOptions } from '../_shared/cors.ts';
import { fulfillSplitShare, parseId, pickStripeKey, refusalSentence, type DbLike, type StripeLike } from '../_shared/splitPayments.ts';

// Where a friend's payment stands. The app asks this while the payment page is open. The caller's own login proves the request is theirs (split_share_status); if the website has not
// heard from Stripe yet, it asks Stripe itself and does the webhook's job (the database applies a session once, so asking again and again is safe).
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
    if (userError || !userData?.user) return json({ error: 'Sign in first.' }, 401);

    const { data: status, error: statusError } = await callerClient.rpc('split_share_status', { p_share: parsed.id });
    if (statusError) {
      const said = refusalSentence(statusError);
      if (said) return json({ error: said }, 409);
      console.error('confirm-split-share: split_share_status failed', statusError.message);
      return json({ error: 'Internal server error' }, 500);
    }
    const state = (status as { state?: string }).state ?? 'unpaid';
    if (state === 'paid' || state === 'refunding' || state === 'refunded') return json({ status: 'paid' });
    if (state !== 'pending') return json({ status: state });

    // Pending: the page was opened. Ask Stripe whether it was paid.
    const supabase = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
    const { data: share } = await supabase.from('site_split_shares').select('stripe_session_id').eq('id', parsed.id).maybeSingle();
    const sessionId = share?.stripe_session_id as string | undefined;
    if (!sessionId) return json({ status: 'pending' });

    const { data: content } = await supabase.from('site_content').select('payments_mode').eq('id', 1).maybeSingle();
    const stripeSecretKey = pickStripeKey(content?.payments_mode, (k) => Deno.env.get(k));
    if (!stripeSecretKey) return json({ status: 'pending' });

    try {
      const stripe = new Stripe(stripeSecretKey, { apiVersion: '2024-06-20', httpClient: Stripe.createFetchHttpClient() });
      const session = await stripe.checkout.sessions.retrieve(sessionId);
      if (session.payment_status === 'paid') {
        const intent = (typeof session.payment_intent === 'string' ? session.payment_intent : session.payment_intent?.id) ?? null;
        const done = await fulfillSplitShare(supabase as unknown as DbLike, stripe as unknown as StripeLike, sessionId, intent, session.amount_total ?? 0);
        if (done.result === 'applied' || done.result === 'already' || done.result === 'refund') return json({ status: 'paid' });
      }
    } catch (err) {
      console.error('confirm-split-share: Stripe check failed', sessionId, (err as { code?: string })?.code ?? 'no code');
    }
    return json({ status: 'pending' });
  } catch (error) {
    console.error('confirm-split-share error:', error);
    return json({ error: 'Internal server error' }, 500);
  }
});
