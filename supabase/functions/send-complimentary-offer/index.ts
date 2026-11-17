import { createClient } from 'npm:@supabase/supabase-js@2';
import { corsHeadersFor, handleOptions } from '../_shared/cors.ts';
import { sendCompOffer } from '../_shared/compOffer.ts';
import { sendCompOfferEmail } from '../_shared/compOfferSender.ts';

// E-mails a complimentary offer's claim link to the person it is for. The caller must be signed in; the database decides whether they may send THIS offer now, and where it goes (the request
// carries only the offer's id). The one-use link is made here, with the service role, after that, and is never returned or logged. See _shared/compOffer.ts.
Deno.serve(async (req: Request) => {
  const preflight = handleOptions(req);
  if (preflight) return preflight;

  const cors = corsHeadersFor(req);
  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405);

  const authHeader = req.headers.get('Authorization');
  if (!authHeader) return json({ error: 'Unauthorized' }, 401);

  const url = Deno.env.get('SUPABASE_URL')!;
  const userClient = createClient(url, Deno.env.get('SUPABASE_ANON_KEY')!, { global: { headers: { Authorization: authHeader } } });
  const { data: userData, error: userError } = await userClient.auth.getUser();
  if (userError || !userData.user) return json({ error: 'Unauthorized' }, 401);

  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return json({ error: 'Invalid request' }, 400);
  }

  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!serviceKey) {
    console.error('send-complimentary-offer: service key is not configured');
    return json({ error: 'The link could not be sent.' }, 500);
  }
  const service = createClient(url, serviceKey);

  const result = await sendCompOffer(body, {
    rpcUser: (fn, args) => userClient.rpc(fn, args),
    rpcService: (fn, args) => service.rpc(fn, args),
    send: sendCompOfferEmail,
    siteUrl: Deno.env.get('SITE_URL') ?? 'https://bottlesupapp.com',
  });
  return json(result.body, result.status);
});
