import { beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';

vi.mock('npm:@supabase/supabase-js@2', () => ({ createClient: vi.fn() }));
vi.mock('../../supabase/functions/_shared/teamInvitationEmail.ts', () => ({
  sendTeamInvitationEmail: vi.fn(async () => ({ sent: true })),
}));
import { createClient } from 'npm:@supabase/supabase-js@2';
import { sendTeamInvitationEmail } from '../../supabase/functions/_shared/teamInvitationEmail.ts';

const ID = '11111111-2222-3333-4444-555555555555';
const TOKEN = 'b'.repeat(64);
const RESERVED = {
  invitee_email: 'newdoor@club.example', role: 'door', org_name: 'Club Co', venue_name: 'Club A', event_title: null,
  shift_name: null, access_start_at: null, access_end_at: null, expires_at: '2026-10-20T15:00:00Z', inviter_name: 'Olivia',
};

let env: Record<string, string | undefined> = {};
let handler: (req: Request) => Promise<Response>;
let getUser: ReturnType<typeof vi.fn>;
let rpc: ReturnType<typeof vi.fn>;

beforeAll(async () => {
  (globalThis as any).Deno = {
    serve: (h: (req: Request) => Promise<Response>) => { handler = h; },
    env: { get: (k: string) => env[k] },
  };
  await import('../../supabase/functions/send-team-invitation/index.ts');
});

beforeEach(() => {
  vi.clearAllMocks();
  vi.spyOn(console, 'error').mockImplementation(() => {});
  env = { SUPABASE_URL: 'http://db.test', SUPABASE_ANON_KEY: 'anon-key', SUPABASE_SERVICE_ROLE_KEY: 'service-key' };
  getUser = vi.fn(async () => ({ data: { user: { id: 'u1' } }, error: null }));
  rpc = vi.fn(async () => ({ data: [RESERVED], error: null }));
  (createClient as any).mockReturnValue({ auth: { getUser }, rpc });
});

const post = (body: unknown, headers: Record<string, string> = { Authorization: 'Bearer user-jwt' }) =>
  handler(new Request('https://fn.test/send-team-invitation', { method: 'POST', headers: { 'Content-Type': 'application/json', ...headers }, body: typeof body === 'string' ? body : JSON.stringify(body) }));

describe('the endpoint', () => {
  it('answers a browser preflight', async () => {
    const res = await handler(new Request('https://fn.test/x', { method: 'OPTIONS', headers: { origin: 'https://www.bottlesupapp.com' } }));
    expect(res.status).toBe(200);
    expect(res.headers.get('Access-Control-Allow-Origin')).toBe('https://www.bottlesupapp.com');
  });

  it('only accepts POST', async () => {
    expect((await handler(new Request('https://fn.test/x', { method: 'GET' }))).status).toBe(405);
  });

  it('refuses a request with no sign-in, before doing anything', async () => {
    const res = await post({ invitation_id: ID, token: TOKEN }, {});
    expect(res.status).toBe(401);
    expect(createClient).not.toHaveBeenCalled();
    expect(rpc).not.toHaveBeenCalled();
  });

  it('refuses a sign-in the auth service rejects', async () => {
    getUser.mockResolvedValue({ data: { user: null }, error: { message: 'bad jwt' } });
    const res = await post({ invitation_id: ID, token: TOKEN });
    expect(res.status).toBe(401);
    expect(rpc).not.toHaveBeenCalled();
    expect(sendTeamInvitationEmail).not.toHaveBeenCalled();
  });

  it('rejects a body that is not JSON', async () => {
    expect((await post('{not json')).status).toBe(400);
  });

  it('acts as the CALLER with the public key, never with the service key', async () => {
    await post({ invitation_id: ID, token: TOKEN });
    expect(createClient).toHaveBeenCalledTimes(1);
    const [url, key, options] = (createClient as any).mock.calls[0];
    expect(url).toBe('http://db.test');
    expect(key).toBe('anon-key');
    expect(options.global.headers.Authorization).toBe('Bearer user-jwt');
    expect(JSON.stringify((createClient as any).mock.calls)).not.toContain('service-key');
  });

  it('sends the invitation and reports who it went to', async () => {
    const res = await post({ invitation_id: ID, token: TOKEN });
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ sent: true, to: 'newdoor@club.example' });
    expect(sendTeamInvitationEmail).toHaveBeenCalledTimes(1);
  });
});

describe('where the link points', () => {
  const linkFor = async (headers: Record<string, string>) => {
    await post({ invitation_id: ID, token: TOKEN }, { Authorization: 'Bearer user-jwt', ...headers });
    const calls = (sendTeamInvitationEmail as any).mock.calls;
    return calls[calls.length - 1][2] as string;
  };

  it('follows the site the request came from when it is a known one', async () => {
    expect(await linkFor({ origin: 'https://www.bottlesupapp.com' })).toContain('href="https://www.bottlesupapp.com/accept-invite?token=');
    expect(await linkFor({ origin: 'http://localhost:8080' })).toContain('href="http://localhost:8080/accept-invite?token=');
  });

  it('ignores an unknown origin and uses the configured site address', async () => {
    env.SITE_URL = 'https://staging.bottlesupapp.com';
    const html = await linkFor({ origin: 'https://evil.example' });
    expect(html).toContain('href="https://staging.bottlesupapp.com/accept-invite?token=');
    expect(html).not.toContain('evil.example');
  });

  it('falls back to the public site when nothing is configured', async () => {
    expect(await linkFor({ origin: 'https://evil.example' })).toContain('href="https://www.bottlesupapp.com/accept-invite?token=');
  });

  it('builds a full address even with no Origin header and no ALLOWED_ORIGIN (the empty-origin trap)', async () => {
    const html = await linkFor({});
    expect(html).toMatch(/href="https:\/\/[^"]+\/accept-invite\?token=/);
    expect(html).not.toContain('href="/accept-invite');
  });
});
