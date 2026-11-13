import { createClient } from 'npm:@supabase/supabase-js@2';
import { MAX_PER_RUN, removePaths } from '../_shared/socialMedia.ts';

// Removes the files in the private social-media bucket that no post uses (an upload whose post was never made, or whose account was deleted and whose folder was not emptied),
// once they are more than a day old: the database lists them (social_media_orphans) and cannot delete a file itself.
//
// Run it once a day with the SERVICE ROLE key as the bearer token: it is not for browsers and takes no input. Until it is scheduled nothing is removed; the files only cost space.
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
    const { data, error } = await supabase.rpc('social_media_orphans');
    if (error) throw new Error('social_media_orphans failed');
    const names = ((data ?? []) as { name: string }[]).map((r) => r.name).filter((n) => typeof n === 'string' && n !== '').slice(0, MAX_PER_RUN);
    const removed = await removePaths(supabase.storage.from('social-media'), names);
    return json({ found: names.length, removed });
  } catch (error) {
    console.error('sweep-social-media error:', error);
    return json({ error: 'Internal server error' }, 500);
  }
});
