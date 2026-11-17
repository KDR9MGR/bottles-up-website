import { createClient } from 'npm:@supabase/supabase-js@2';
import { runReportJobs } from '../_shared/reportJob.ts';
import { sendReportEmail } from '../_shared/reportEmailSender.ts';

// Sends the reports that were queued when a night was closed (database: 20261126100000_auto_report_jobs.sql). Run it on a schedule (every few minutes) with the SERVICE ROLE key as the bearer
// token: it is not for browsers and takes no input. Which reports, for whom and to which addresses is decided by the database; this only makes the PDF and sends it. Switching it on is a
// separate, deliberate step (deploy, add the schedule): until then every queued report waits. See _shared/reportJob.ts.

function sameSecret(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

Deno.serve(async (req: Request) => {
  const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });

  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405);

  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  const supplied = /^Bearer\s+(\S+)$/i.exec(req.headers.get('Authorization') ?? '')?.[1];
  if (!serviceKey || !supplied || !sameSecret(supplied, serviceKey)) return json({ error: 'Unauthorized' }, 401);

  try {
    const service = createClient(Deno.env.get('SUPABASE_URL')!, serviceKey);
    const summary = await runReportJobs({
      rpc: (fn, args) => service.rpc(fn, args),
      send: sendReportEmail,
      emailConfigured: () => !!Deno.env.get('RESEND_API_KEY'),
      now: () => new Date(),
    });
    return json(summary);
  } catch (error) {
    console.error('run-report-jobs error:', error);
    return json({ error: 'Internal server error' }, 500);
  }
});
