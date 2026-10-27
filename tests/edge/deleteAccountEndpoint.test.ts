import { beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';

vi.mock('npm:@supabase/supabase-js@2', () => ({ createClient: vi.fn() }));
import { createClient } from 'npm:@supabase/supabase-js@2';

let env: Record<string, string | undefined> = {};
let handler: (req: Request) => Promise<Response>;
let order: string[];
let removed: string[][];
let listings: Record<string, string[]>;
let profilesOfUser: { id: string }[] | null;
let deleteUserError: unknown;
let removeError: unknown;

beforeAll(async () => {
  (globalThis as any).Deno = {
    serve: (h: (req: Request) => Promise<Response>) => { handler = h; },
    env: { get: (k: string) => env[k] },
  };
  await import('../../supabase/functions/delete-account/index.ts');
});

beforeEach(() => {
  vi.clearAllMocks();
  vi.spyOn(console, 'error').mockImplementation(() => {});
  env = { SUPABASE_URL: 'http://db.test', SUPABASE_ANON_KEY: 'anon-key', SUPABASE_SERVICE_ROLE_KEY: 'service-key' };
  order = [];
  removed = [];
  listings = { pa: ['1.jpg', '2.mp4'], pb: ['3.jpg'] };
  profilesOfUser = [{ id: 'pa' }, { id: 'pb' }];
  deleteUserError = null;
  removeError = null;
  const caller = { auth: { getUser: vi.fn(async () => ({ data: { user: { id: 'u1' } }, error: null })) } };
  const admin = {
    from: (table: string) => ({
      select: () => ({ eq: async (col: string, val: string) => { order.push(`select ${table} where ${col}=${val}`); return { data: profilesOfUser, error: null }; } }),
      delete: () => ({ eq: async () => { order.push(`delete ${table}`); return { error: null }; } }),
    }),
    auth: { admin: { deleteUser: vi.fn(async () => { order.push('delete sign-in'); return { error: deleteUserError }; }) } },
    storage: {
      from: (bucket: string) => ({
        list: async (folder: string) => ({ data: (listings[folder] ?? []).map((name) => ({ name })), error: null }),
        remove: async (paths: string[]) => {
          order.push(`remove files from ${bucket}`);
          if (removeError) throw removeError;
          removed.push(paths);
          for (const p of paths) { const [f, n] = p.split('/'); listings[f] = (listings[f] ?? []).filter((x) => x !== n); }
          return { error: null };
        },
      }),
    },
  };
  (createClient as any).mockImplementation((_url: string, key: string) => (key === 'service-key' ? admin : caller));
});

const post = (headers: Record<string, string> = { Authorization: 'Bearer user-jwt' }) => handler(new Request('https://fn.test/delete-account', { method: 'POST', headers }));

describe('deleting an account', () => {
  it('needs a POST and a sign-in', async () => {
    expect((await handler(new Request('https://fn.test/x', { method: 'GET' }))).status).toBe(405);
    expect((await post({})).status).toBe(401);
  });

  it('removes the person\'s files from every one of their profiles\' folders, after the account is gone', async () => {
    const res = await post();
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ success: true });
    expect(removed.flat().sort()).toEqual(['pa/1.jpg', 'pa/2.mp4', 'pb/3.jpg']);
    const signIn = order.indexOf('delete sign-in');
    expect(signIn).toBeGreaterThan(-1);
    expect(order.indexOf('remove files from social-media')).toBeGreaterThan(signIn);
    expect(order[0]).toBe('select site_profiles where user_id=u1');
  });

  it('asks for the profiles by the caller\'s own id from their sign-in, never one from the request', async () => {
    await handler(new Request('https://fn.test/delete-account', { method: 'POST', headers: { Authorization: 'Bearer user-jwt' }, body: JSON.stringify({ user_id: 'someone-else' }) }));
    expect(order[0]).toBe('select site_profiles where user_id=u1');
    expect(order.join('|')).not.toContain('someone-else');
  });

  it('a person with no profiles has no files to remove, and still goes', async () => {
    profilesOfUser = [];
    expect((await post()).status).toBe(200);
    expect(order).not.toContain('remove files from social-media');
    profilesOfUser = null;
    expect((await post()).status).toBe(200);
  });

  it('keeps the files when the account could not be deleted', async () => {
    deleteUserError = { message: 'cannot' };
    const res = await post();
    expect(res.status).toBe(500);
    expect(removed).toEqual([]);
    expect(order).not.toContain('remove files from social-media');
  });

  it('a failure removing files does not make the deletion look like it failed', async () => {
    removeError = new Error('storage down');
    const res = await post();
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ success: true });
  });
});
