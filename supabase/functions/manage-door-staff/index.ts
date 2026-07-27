import { createClient } from 'npm:@supabase/supabase-js@2';
import { corsHeadersFor, handleOptions } from '../_shared/cors.ts';

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

// Adds a door_staff row for the given email. Resolves (or creates, via
// generateLink) the matching auth.users id without emailing anything - this
// project shares its Supabase auth.users with the BottlesUp mobile app, so the
// email may already belong to an existing account. The actual sign-in email is
// sent later, on demand, when the person requests a magic link at /door/login.
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

  const supabase = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  );

  const { data: admin } = await supabase
    .from('cms_admins')
    .select('id')
    .eq('id', userData.user.id)
    .maybeSingle();
  if (!admin) {
    return json({ error: 'Forbidden' }, 403);
  }

  try {
    const { email } = await req.json();
    if (!email || typeof email !== 'string' || !EMAIL_RE.test(email)) {
      return json({ error: 'Valid email is required' }, 400);
    }

    const { data: linkData, error: linkError } = await supabase.auth.admin.generateLink({
      type: 'magiclink',
      email,
    });
    if (linkError || !linkData?.user) {
      console.error('generateLink error:', linkError);
      return json({ error: linkError?.message ?? 'Could not resolve a user for that email' }, 500);
    }

    const { error: insertError } = await supabase
      .from('door_staff')
      .upsert({ id: linkData.user.id, email }, { onConflict: 'id' });

    if (insertError) {
      console.error('door_staff insert error:', insertError);
      return json({ error: 'Failed to add door staff' }, 500);
    }

    await supabase.from('audit_log').insert({
      actor_id: userData.user.id,
      actor_email: userData.user.email ?? 'unknown',
      action: 'door_staff.added',
      entity_type: 'door_staff',
      entity_id: linkData.user.id,
      details: { email },
    });

    return json({ success: true });
  } catch (error) {
    console.error('manage-door-staff error:', error);
    return json({ error: 'Internal server error' }, 500);
  }
});
