import { beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';

vi.mock('npm:@supabase/supabase-js@2', () => ({ createClient: vi.fn() }));
vi.mock('../../supabase/functions/_shared/teamInvitationEmail.ts', () => ({
  sendTeamInvitationEmail: vi.fn(async () => ({ sent: true })),
}));
import { createClient } from 'npm:@supabase/supabase-js@2';
import { sendTeamInvitationEmail } from '../../supabase/functions/_shared/teamInvitationEmail.ts';

const TOKEN = 'b'.repeat(64);
const ISSUED = {
  invitee_email: 'temp@club.example', code: '123456', code_expires_at: '2026-10-20T15:10:00Z', role: 'server', org_name: 'Club Co', venue_name: 'Club A',
  event_title: null, shift_name: null, access_start_at: null, access_end_at: '2026-10-21T08:00:00Z',
};

let env: Record<string, string | undefined> = {};
let handler: (req: Request) => Promise<Response>;
let getUser: ReturnType<typeof vi.fn>;
let serviceRpc: ReturnType<typeof vi.fn>;
let userRpc: ReturnType<typeof vi.fn>;

beforeAll(async () => {
  (globalThis as any).Deno = {
    serve: (h: (req: Request) => Promise<Response>) => { handler = h; },
    env: { get: (k: string) => env[k] },
  };
  await import('../../supabase/functions/send-invitation-code/index.ts');
});

beforeEach(() => {
  vi.clearAllMocks();
  vi.spyOn(console, 'error').mockImplementation(() => {});
  env = { SUPABASE_URL: 'http://db.test', SUPABASE_ANON_KEY: 'anon-key', SUPABASE_SERVICE_ROLE_KEY: 'service-key' };
  getUser = vi.fn(async () => ({ data: { user: { id: 'u1', email: 'temp@club.example' } }, error: null }));
  serviceRpc = vi.fn(async () => ({ data: [ISSUED], error: null }));
  userRpc = vi.fn(async () => ({ data: null, error: null }));
  // The person's own client (anon key + their token) and the service client (service key): told apart by the key.
  (createClient as any).mockImplementation((_url: string, key: string) => (key === 'service-key' ? { rpc: serviceRpc } : { auth: { getUser }, rpc: userRpc }));
});

const post = (body: unknown, headers: Record<string, string> = { Authorization: 'Bearer user-jwt' }) =>
  handler(new Request('https://fn.test/send-invitation-code', { method: 'POST', headers: { 'Content-Type': 'application/json', ...headers }, body: typeof body === 'string' ? body : JSON.stringify(body) }));

describe('the endpoint', () => {
  it('answers a browser preflight', async () => {
    const res = await handler(new Request('https://fn.test/x', { method: 'OPTIONS', headers: { origin: 'https://www.bottlesupapp.com' } }));
    expect(res.status).toBe(200);
  });

  it('only accepts POST', async () => {
    expect((await handler(new Request('https://fn.test/x', { method: 'GET' }))).status).toBe(405);
  });

  it('refuses a request with no sign-in, before doing anything', async () => {
    const res = await post({ token: TOKEN }, {});
    expect(res.status).toBe(401);
    expect(createClient).not.toHaveBeenCalled();
    expect(serviceRpc).not.toHaveBeenCalled();
  });

  it('refuses a sign-in the auth service rejects, and never makes a code', async () => {
    getUser.mockResolvedValue({ data: { user: null }, error: { message: 'bad jwt' } });
    expect((await post({ token: TOKEN })).status).toBe(401);
    expect(serviceRpc).not.toHaveBeenCalled();
    expect(sendTeamInvitationEmail).not.toHaveBeenCalled();
  });

  it('rejects a body that is not JSON', async () => {
    expect((await post('{not json')).status).toBe(400);
    expect(serviceRpc).not.toHaveBeenCalled();
  });

  it('makes the code with the SERVICE key for the address the person is signed in with, and e-mails it', async () => {
    const res = await post({ token: TOKEN, email: 'attacker@example.com' });
    expect(res.status).toBe(200);
    expect(serviceRpc).toHaveBeenCalledWith('issue_invitation_code', { p_token: TOKEN, p_email: 'temp@club.example' });
    expect(userRpc).not.toHaveBeenCalled();
    expect(sendTeamInvitationEmail).toHaveBeenCalledTimes(1);
    expect((sendTeamInvitationEmail as any).mock.calls[0][0]).toBe('temp@club.example');
  });

  it('never puts the code in the answer', async () => {
    const res = await post({ token: TOKEN });
    expect(JSON.stringify(await res.json())).not.toContain('123456');
  });

  it('does not make a code for a person whose session has no e-mail address', async () => {
    getUser.mockResolvedValue({ data: { user: { id: 'u2', email: null } }, error: null });
    const res = await post({ token: TOKEN });
    expect(res.status).toBe(401);
    expect(serviceRpc).not.toHaveBeenCalled();
  });

  it('without the service key configured, makes no code and says it could not', async () => {
    env.SUPABASE_SERVICE_ROLE_KEY = undefined;
    const res = await post({ token: TOKEN });
    expect(res.status).toBe(500);
    expect(serviceRpc).not.toHaveBeenCalled();
    expect(sendTeamInvitationEmail).not.toHaveBeenCalled();
  });

  it('passes on the database\'s refusals as plain statuses', async () => {
    serviceRpc.mockResolvedValue({ data: null, error: { message: 'please wait a minute before asking for another code' } });
    const res = await post({ token: TOKEN });
    expect(res.status).toBe(429);
    expect(sendTeamInvitationEmail).not.toHaveBeenCalled();
  });
});
