import { createClient } from 'npm:@supabase/supabase-js@2';
import bcrypt from 'npm:bcryptjs@2.4.3';
import { corsHeadersFor, handleOptions } from '../_shared/cors.ts';

// Admin-only: hashes and stores a tier's access code. The plaintext is never
// persisted, so the CMS form always shows this field blank - "leave blank to
// keep the existing code" - there's nothing to redisplay after the fact.
Deno.serve(async (req: Request) => {
  const preflight = handleOptions(req);
  if (preflight) return preflight;

  const cors = corsHeadersFor(req);
  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

  if (req.method !== 'POST') {
    return json({ error: 'Method not allowed' }, 405);
  }

  const authHeader = req.headers.get('Authorization');
  if (!authHeader) {
    return json({ error: 'Unauthorized' }, 401);
  }

  const anonClient = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, {
    global: { headers: { Authorization: authHeader } },
  });
  const { data: userData, error: userError } = await anonClient.auth.getUser();
  if (userError || !userData.user) {
    return json({ error: 'Unauthorized' }, 401);
  }

  const supabase = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);

  const { data: admin } = await supabase
    .from('cms_admins')
    .select('id')
    .eq('id', userData.user.id)
    .maybeSingle();
  if (!admin) {
    return json({ error: 'Forbidden' }, 403);
  }

  try {
    const { tier_id, code } = await req.json();
    if (typeof tier_id !== 'string' || !tier_id) {
      return json({ error: 'tier_id is required' }, 400);
    }
    if (typeof code !== 'string' || !code.trim()) {
      return json({ error: 'code is required' }, 400);
    }

    const codeHash = bcrypt.hashSync(code.trim(), 10);

    const { error } = await supabase
      .from('ticket_tier_access_codes')
      .upsert({ tier_id, code_hash: codeHash, updated_at: new Date().toISOString() }, { onConflict: 'tier_id' });

    if (error) {
      console.error('set-tier-access-code upsert error:', error);
      return json({ error: 'Failed to save access code' }, 500);
    }

    return json({ success: true });
  } catch (error) {
    console.error('set-tier-access-code error:', error);
    return json({ error: 'Internal server error' }, 500);
  }
});
