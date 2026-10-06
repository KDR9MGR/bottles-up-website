import { createClient } from 'npm:@supabase/supabase-js@2';
import { corsHeadersFor, handleOptions, isPreviewOrLocalOrigin } from '../_shared/cors.ts';
import { sendTeamInvitation } from '../_shared/teamInvitation.ts';
import { sendTeamInvitationEmail } from '../_shared/teamInvitationEmail.ts';

// Emails a team invitation link to the address stored on the invitation. It runs as the CALLER (their own
// session, no service key): the database function it calls decides whether they may send it. See _shared/teamInvitation.ts.
Deno.serve(async (req: Request) => {
  const preflight = handleOptions(req);
  if (preflight) return preflight;

  const cors = corsHeadersFor(req);
  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405);

  const authHeader = req.headers.get('Authorization');
  if (!authHeader) return json({ error: 'Unauthorized' }, 401);

  const client = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, {
    global: { headers: { Authorization: authHeader } },
  });
  const { data: userData, error: userError } = await client.auth.getUser();
  if (userError || !userData.user) return json({ error: 'Unauthorized' }, 401);

  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return json({ error: 'Invalid request' }, 400);
  }

  const origin = req.headers.get('origin') ?? '';
  // filter(Boolean): an unset ALLOWED_ORIGIN must not "allow" the empty origin of a request that sent none.
  const allowedOrigins = (Deno.env.get('ALLOWED_ORIGIN') ?? '').split(',').map((o: string) => o.trim()).filter(Boolean);
  const siteUrl = origin !== '' && (allowedOrigins.includes(origin) || isPreviewOrLocalOrigin(origin))
    ? origin
    : (Deno.env.get('SITE_URL') ?? 'https://www.bottlesupapp.com');

  const result = await sendTeamInvitation(body, {
    rpc: (fn, args) => client.rpc(fn, args),
    send: sendTeamInvitationEmail,
    siteUrl,
  });
  return json(result.body, result.status);
});
