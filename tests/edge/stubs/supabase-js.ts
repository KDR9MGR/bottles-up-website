// Stand-in for `npm:@supabase/supabase-js@2` inside edge-function tests.
// Tests never talk to a real database: they hand the code an in-memory fake
// (see fakeDb.ts) or just check which client object was passed along.
export function createClient(url: string, key: string) {
  return { __stubClient: true, url, key };
}
