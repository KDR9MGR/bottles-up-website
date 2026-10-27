import { createClient } from 'npm:@supabase/supabase-js@2';
import Stripe from 'npm:stripe@17';
import { corsHeadersFor, handleOptions } from '../_shared/cors.ts';
import { parseId, pickStripeKey, type DbLike, type StripeLike } from '../_shared/splitPayments.ts';
import { fulfillProPayment, refusalSentence } from '../_shared/proPayments.ts';

// Where a booking's payment stands, for the app while the payment page is open. The caller's own login proves the booking is theirs (pro_booking_get). If a payment page is open and
// the website has not heard from Stripe yet, it asks Stripe itself and does the webhook's job (the database applies a session once, so asking again and again is safe).
// Answers {status: 'paid' | 'pending' | 'none', booking}: 'paid' once a payment has been counted, 'pending' while a page is open and unpaid, 'none' when no page is open.
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
    if (userError || !userData?.user) return json({ error: 'Sign in first.' }, 401);

    const reread = async () => {
      const { data, error } = await callerClient.rpc('pro_booking_get', { p_booking: parsed.id });
      return { data, error };
    };
    const first = await reread();
    if (first.error) {
      const said = refusalSentence(first.error);
      if (said) return json({ error: said }, 409);
      console.error('confirm-pro-payment: pro_booking_get failed', first.error.message);
      return json({ error: 'Internal server error' }, 500);
    }

    const supabase = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
    const { data: page } = await supabase
      .from('site_pro_payments')
      .select('stripe_session_id, status')
      .eq('booking', parsed.id)
      .eq('status', 'pending')
      .order('created_at', { ascending: false })
      .limit(1)
      .maybeSingle();
    const sessionId = page?.stripe_session_id as string | undefined;
    if (!sessionId) {
      // Nothing is waiting. If the booking has been paid something, that is what the person wants to hear.
      const paid = ((first.data ?? {}) as { paid_cents?: number }).paid_cents ?? 0;
      return json({ status: paid > 0 ? 'paid' : 'none', booking: first.data });
    }

    const { data: content } = await supabase.from('site_content').select('payments_mode').eq('id', 1).maybeSingle();
    const stripeSecretKey = pickStripeKey(content?.payments_mode, (k) => Deno.env.get(k));
    if (!stripeSecretKey) return json({ status: 'pending', booking: first.data });

    try {
      const stripe = new Stripe(stripeSecretKey, { apiVersion: '2024-06-20', httpClient: Stripe.createFetchHttpClient() });
      const session = await stripe.checkout.sessions.retrieve(sessionId);
      if (session.payment_status === 'paid') {
        const intent = (typeof session.payment_intent === 'string' ? session.payment_intent : session.payment_intent?.id) ?? null;
        const done = await fulfillProPayment(supabase as unknown as DbLike, stripe as unknown as StripeLike, sessionId, intent, session.amount_total ?? 0);
        if (done.result === 'applied' || done.result === 'already' || done.result === 'refund') {
          const again = await reread();
          return json({ status: 'paid', booking: again.data ?? first.data });
        }
      }
    } catch (err) {
      console.error('confirm-pro-payment: Stripe check failed', sessionId, (err as { code?: string })?.code ?? 'no code');
    }
    return json({ status: 'pending', booking: first.data });
  } catch (error) {
    console.error('confirm-pro-payment error:', error);
    return json({ error: 'Internal server error' }, 500);
  }
});
