import { createClient } from 'npm:@supabase/supabase-js@2';
import Stripe from 'npm:stripe@17';
import { corsHeadersFor, handleOptions } from '../_shared/cors.ts';
import { parseId, pickStripeKey, type DbLike, type StripeLike } from '../_shared/splitPayments.ts';
import { refundDuePayments, refusalSentence } from '../_shared/proPayments.ts';

// The customer or the professional cancels a booking. The database decides who may and what is paid back or kept (pro_booking_cancel, with the caller's own login); then this pays back
// what is due through Stripe right away. If Stripe cannot be reached the booking is still cancelled and process-pro-bookings pays back at its next run.
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
    const reason = typeof (body as { reason?: unknown }).reason === 'string' ? ((body as { reason: string }).reason as string).trim().slice(0, 300) : '';

    const callerClient = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: userData, error: userError } = await callerClient.auth.getUser();
    if (userError || !userData?.user) return json({ error: 'Sign in first.' }, 401);

    const { data: booking, error: cancelError } = await callerClient.rpc('pro_booking_cancel', { p_booking: parsed.id, p_reason: reason });
    if (cancelError) {
      const said = refusalSentence(cancelError);
      if (said) return json({ error: said }, 409);
      console.error('cancel-pro-booking: pro_booking_cancel failed', cancelError.message);
      return json({ error: 'Internal server error' }, 500);
    }

    let refunded = 0;
    let failed = 0;
    try {
      const supabase = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
      const { data: content } = await supabase.from('site_content').select('payments_mode').eq('id', 1).maybeSingle();
      const stripeSecretKey = pickStripeKey(content?.payments_mode, (k) => Deno.env.get(k));
      if (stripeSecretKey) {
        const stripe = new Stripe(stripeSecretKey, { apiVersion: '2024-06-20', httpClient: Stripe.createFetchHttpClient() });
        ({ refunded, failed } = await refundDuePayments(supabase as unknown as DbLike, stripe as unknown as StripeLike, { bookingId: parsed.id }));
      }
    } catch (err) {
      console.error('cancel-pro-booking: refunds did not run', (err as { code?: string })?.code ?? 'no code');
    }
    return json({ booking, refunded, failed });
  } catch (error) {
    console.error('cancel-pro-booking error:', error);
    return json({ error: 'Internal server error' }, 500);
  }
});
