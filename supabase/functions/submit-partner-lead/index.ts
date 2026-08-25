import { createClient } from 'npm:@supabase/supabase-js@2';
import { corsHeadersFor, handleOptions } from '../_shared/cors.ts';

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

Deno.serve(async (req: Request) => {
  const preflight = handleOptions(req);
  if (preflight) return preflight;

  const cors = corsHeadersFor(req);
  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

  if (req.method !== 'POST') {
    return json({ error: 'Method not allowed' }, 405);
  }

  try {
    const { email, venue_name } = await req.json();

    if (!email || typeof email !== 'string' || !EMAIL_RE.test(email)) {
      return json({ error: 'A valid work email is required' }, 400);
    }

    const supabase = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);

    const { error } = await supabase.from('partner_leads').insert({
      email: email.toLowerCase(),
      venue_name: typeof venue_name === 'string' && venue_name.trim() ? venue_name.trim() : null,
    });

    if (error) {
      console.error('partner_leads insert error:', error);
      return json({ error: 'Failed to submit request' }, 500);
    }

    return json({ success: true });
  } catch (error) {
    console.error('submit-partner-lead error:', error);
    return json({ error: 'Internal server error' }, 500);
  }
});
