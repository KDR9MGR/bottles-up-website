// Sends the guest messages the app has queued (table seated, wait estimate, VIP invitation) and deletes expired chats.
//
// Run it on a schedule (every few minutes) with the SERVICE ROLE key as the bearer token: it is not for browsers and takes no input.
// Switching it on is a separate, deliberate step (deploy, set RESEND_API_KEY if it is not already set, add the schedule): until then every
// guest message stays "Queued, not sent yet" in the app. Rules and wording: _shared/outbox.ts. Concurrency and retry limits: the database
// (outbox_claim / outbox_finish, 20261019100000_outbox_claim.sql).
import { createClient } from 'npm:@supabase/supabase-js@2';
import { loadFacts, runOutbox } from '../_shared/outbox.ts';
import { outboxEmailConfigured, sendOutboxEmail } from '../_shared/outboxEmail.ts';

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
    const supabase = createClient(Deno.env.get('SUPABASE_URL')!, serviceKey);
    const summary = await runOutbox({
      configured: outboxEmailConfigured,
      claim: async (limit) => {
        const { data, error } = await supabase.rpc('outbox_claim', { p_limit: limit });
        if (error) throw new Error('outbox_claim failed');
        return data ?? [];
      },
      loadFacts: (msg) => loadFacts(supabase, msg),
      send: sendOutboxEmail,
      finish: async (id, result, error) => {
        const { error: rpcError } = await supabase.rpc('outbox_finish', { p_id: id, p_result: result, p_error: error });
        if (rpcError) throw new Error('outbox_finish failed');
      },
      purgeChat: async () => {
        const { data, error } = await supabase.rpc('chat_purge_expired');
        if (error) throw new Error('chat_purge_expired failed');
        return typeof data === 'number' ? data : 0;
      },
      now: () => Date.now(),
      siteUrl: Deno.env.get('SITE_URL') ?? 'https://bottlesupapp.com',
    });
    return json(summary);
  } catch (error) {
    console.error('process-outbox error:', error);
    return json({ error: 'Internal server error' }, 500);
  }
});
