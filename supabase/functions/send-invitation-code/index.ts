import { createClient } from 'npm:@supabase/supabase-js@2';
import { corsHeadersFor, handleOptions } from '../_shared/cors.ts';
import { sendInvitationCode } from '../_shared/invitationCode.ts';
import { sendTeamInvitationEmail } from '../_shared/teamInvitationEmail.ts';

// E-mails the 6-digit code that confirms a temporary-staff invitation, to the address on the invitation. The caller must be signed in with that address (checked here from their
// own session and again in the database). The code is made with the service role, which only this function holds, and is never returned: it reaches the invitee by e-mail only.
// See _shared/invitationCode.ts.
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
    console.error('send-invitation-code: service key is not configured');
    return json({ error: 'Could not send the code.' }, 500);
  }
  const service = createClient(url, serviceKey);

  const result = await sendInvitationCode(body, {
    callerEmail: userData.user.email ?? null,
    rpcService: (fn, args) => service.rpc(fn, args),
    send: sendTeamInvitationEmail,
  });
  return json(result.body, result.status);
});
