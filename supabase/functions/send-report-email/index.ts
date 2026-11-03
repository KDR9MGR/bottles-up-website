import { createClient } from 'npm:@supabase/supabase-js@2';
import { corsHeadersFor, handleOptions } from '../_shared/cors.ts';
import { sendReport } from '../_shared/reportEmail.ts';
import { sendReportEmail } from '../_shared/reportEmailSender.ts';

// E-mails a report PDF the app has built to the people configured to receive that kind of report. The caller must be signed in; the database decides whether they may send THIS report and
// which addresses it goes to (the request carries none). The result of every address is recorded for the log and for "send again". See _shared/reportEmail.ts.
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
    console.error('send-report-email: service key is not configured');
    return json({ error: 'Could not send the report.' }, 500);
  }
  const service = createClient(url, serviceKey);

  const result = await sendReport(body, {
    senderEmail: userData.user.email ?? null,
    rpcUser: (fn, args) => userClient.rpc(fn, args),
    rpcService: (fn, args) => service.rpc(fn, args),
    send: sendReportEmail,
  });
  return json(result.body, result.status);
});
