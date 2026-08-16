import { createClient } from 'npm:@supabase/supabase-js@2';
import { corsHeadersFor, handleOptions } from '../_shared/cors.ts';

// Deletes the caller's own account - and only their own. The caller's JWT is
// resolved to a user id via a client scoped to their Authorization header
// (never trust a user id passed in the request body), then the profile row
// and auth user are removed with the service role key, which is the only
// credential permitted to call auth.admin.deleteUser.
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
    return json({ error: 'Missing Authorization header' }, 401);
  }

  const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY')!;

  const callerClient = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: authHeader } },
  });

  const { data: userData, error: userError } = await callerClient.auth.getUser();
  if (userError || !userData?.user) {
    return json({ error: 'Invalid or expired session' }, 401);
  }
  const userId = userData.user.id;

  const admin = createClient(supabaseUrl, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);

  // Best-effort: the profile row has no FK/cascade back to auth.users, so it
  // would otherwise be orphaned after the auth user is gone.
  const { error: profileError } = await admin.from('profiles').delete().eq('id', userId);
  if (profileError) {
    console.error('delete-account: failed to delete profile row', userId, profileError);
  }

  const { error: deleteError } = await admin.auth.admin.deleteUser(userId);
  if (deleteError) {
    console.error('delete-account: failed to delete auth user', userId, deleteError);
    return json({ error: 'Failed to delete account' }, 500);
  }

  return json({ success: true });
});
