import { createClient } from 'npm:@supabase/supabase-js@2';
import { corsHeadersFor, handleOptions } from '../_shared/cors.ts';
import { handleClaim, sha256Hex } from '../_shared/compClaim.ts';

// The public door of the complimentary claim page: view the offer behind a link, or say where you are. Nobody is signed in; the database functions behind it can be called by the service role
// only, so this function counts the visit, checks the shape of the request and returns only what the page shows. See _shared/compClaim.ts.
Deno.serve(async (req: Request) => {
  const preflight = handleOptions(req);
  if (preflight) return preflight;

  const cors = corsHeadersFor(req);
  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json', 'Cache-Control': 'no-store' } });

  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405);

  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return json({ error: 'Invalid request.' }, 400);
  }

  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!serviceKey) {
    console.error('comp-claim: service key is not configured');
    return json({ error: 'Something went wrong. Try again.' }, 500);
  }
  const service = createClient(Deno.env.get('SUPABASE_URL')!, serviceKey);

  // The visitor's address is hashed before it is used as a key and is never stored or logged.
  const forwarded = req.headers.get('x-forwarded-for')?.split(',')[0]?.trim() || req.headers.get('cf-connecting-ip') || 'unknown';
  const result = await handleClaim(body, {
    rpcService: (fn, args) => service.rpc(fn, args),
    visitor: (await sha256Hex(`bottlesup-claim:${forwarded}`)).slice(0, 32),
  });
  return json(result.body, result.status);
});
