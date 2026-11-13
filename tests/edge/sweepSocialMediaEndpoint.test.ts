import { beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';

vi.mock('npm:@supabase/supabase-js@2', () => ({ createClient: vi.fn() }));
import { createClient } from 'npm:@supabase/supabase-js@2';

let env: Record<string, string | undefined> = {};
let handler: (req: Request) => Promise<Response>;
let rpc: ReturnType<typeof vi.fn>;
let remove: ReturnType<typeof vi.fn>;

beforeAll(async () => {
  (globalThis as any).Deno = {
    serve: (h: (req: Request) => Promise<Response>) => { handler = h; },
    env: { get: (k: string) => env[k] },
  };
  await import('../../supabase/functions/sweep-social-media/index.ts');
});

beforeEach(() => {
  vi.clearAllMocks();
  vi.spyOn(console, 'error').mockImplementation(() => {});
  env = { SUPABASE_URL: 'http://db.test', SUPABASE_SERVICE_ROLE_KEY: 'service-key' };
  rpc = vi.fn(async () => ({ data: [{ name: 'p1/a.jpg' }, { name: 'p2/b.mp4' }], error: null }));
  remove = vi.fn(async () => ({ error: null }));
  (createClient as any).mockReturnValue({ rpc, storage: { from: vi.fn(() => ({ remove })) } });
});

const call = (headers: Record<string, string> = { Authorization: 'Bearer service-key' }, method = 'POST') => handler(new Request('https://fn.test/sweep', { method, headers }));

describe('the sweep', () => {
  it('only a POST with the service key; no one else, and nothing is touched for them', async () => {
    expect((await call({}, 'GET')).status).toBe(405);
    expect((await call({})).status).toBe(401);
    expect((await call({ Authorization: 'Bearer user-jwt' })).status).toBe(401);
    expect((await call({ Authorization: 'service-key' })).status).toBe(401);
    expect((await call({ Authorization: 'Bearer service-keyx' })).status).toBe(401);
    expect(createClient).not.toHaveBeenCalled();
    expect(remove).not.toHaveBeenCalled();
  });

  it('removes the files the database lists, and says how many', async () => {
    const res = await call();
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ found: 2, removed: 2 });
    expect(rpc).toHaveBeenCalledWith('social_media_orphans');
    expect(remove).toHaveBeenCalledWith(['p1/a.jpg', 'p2/b.mp4']);
  });

  it('nothing to sweep is nothing removed, and no storage call', async () => {
    rpc.mockResolvedValue({ data: [], error: null });
    expect(await (await call()).json()).toEqual({ found: 0, removed: 0 });
    rpc.mockResolvedValue({ data: null, error: null });
    expect(await (await call()).json()).toEqual({ found: 0, removed: 0 });
    expect(remove).not.toHaveBeenCalled();
  });

  it('ignores a row without a usable name', async () => {
    rpc.mockResolvedValue({ data: [{ name: '' }, { name: null }, {}, { name: 'p1/ok.jpg' }], error: null });
    expect(await (await call()).json()).toEqual({ found: 1, removed: 1 });
  });

  it('a batch the storage refuses is left for the next run', async () => {
    remove.mockResolvedValue({ error: { message: 'refused' } });
    expect(await (await call()).json()).toEqual({ found: 2, removed: 0 });
  });

  it('when the database cannot be asked it says so without detail', async () => {
    rpc.mockResolvedValue({ data: null, error: { message: 'secret internals' } });
    const res = await call();
    expect(res.status).toBe(500);
    expect(await res.json()).toEqual({ error: 'Internal server error' });
  });
});
