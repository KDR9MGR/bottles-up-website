import { beforeEach, describe, expect, it, vi } from 'vitest';
import { sendTeamInvitation, type Deps } from '../../supabase/functions/_shared/teamInvitation.ts';

const ID = '11111111-2222-3333-4444-555555555555';
const TOKEN = 'a'.repeat(64);

const reserved = {
  invitee_email: 'newdoor@club.example', role: 'door', org_name: 'Club Co', venue_name: 'Club A',
  event_title: null, shift_name: null, access_start_at: null, access_end_at: null,
  expires_at: '2026-10-20T15:00:00Z', inviter_name: 'Olivia Owner',
};

let rpc: ReturnType<typeof vi.fn>;
let send: ReturnType<typeof vi.fn>;
const deps = (over: Partial<Deps> = {}): Deps => ({ rpc: rpc as Deps['rpc'], send: send as Deps['send'], siteUrl: 'https://www.bottlesupapp.com', ...over });

beforeEach(() => {
  vi.restoreAllMocks();
  vi.spyOn(console, 'error').mockImplementation(() => {});
  rpc = vi.fn(async () => ({ data: [reserved], error: null }));
  send = vi.fn(async () => ({ sent: true }));
});

describe('request validation', () => {
  it.each([
    ['nothing', undefined],
    ['not an object', 'x'],
    ['no token', { invitation_id: ID }],
    ['no invitation', { token: TOKEN }],
    ['a malformed invitation id', { invitation_id: 'not-a-uuid', token: TOKEN }],
    ['a token that is too short', { invitation_id: ID, token: 'abc' }],
    ['a token that is absurdly long', { invitation_id: ID, token: 'a'.repeat(500) }],
    ['numbers', { invitation_id: 5, token: 5 }],
  ])('rejects %s without touching the database or sending anything', async (_n, body) => {
    const out = await sendTeamInvitation(body, deps());
    expect(out.status).toBe(400);
    expect(rpc).not.toHaveBeenCalled();
    expect(send).not.toHaveBeenCalled();
  });
});

describe('who it emails', () => {
  it('emails the address the database returned, and only that', async () => {
    const out = await sendTeamInvitation({ invitation_id: ID, token: TOKEN }, deps());
    expect(out).toEqual({ status: 200, body: { sent: true, to: 'newdoor@club.example' } });
    expect(send).toHaveBeenCalledTimes(1);
    expect(send.mock.calls[0][0]).toBe('newdoor@club.example');
  });

  it('ignores any address, subject or content supplied in the request', async () => {
    await sendTeamInvitation(
      { invitation_id: ID, token: TOKEN, email: 'victim@example.com', to: 'victim@example.com', subject: 'You won', html: '<b>hi</b>' },
      deps(),
    );
    expect(send.mock.calls[0][0]).toBe('newdoor@club.example');
    expect(send.mock.calls[0][1]).not.toContain('You won');
    expect(JSON.stringify(rpc.mock.calls)).not.toContain('victim@example.com');
  });

  it('asks the database as the caller, passing exactly the invitation and the link token', async () => {
    await sendTeamInvitation({ invitation_id: ID, token: TOKEN }, deps());
    expect(rpc).toHaveBeenCalledWith('reserve_invitation_email', { p_invitation: ID, p_token: TOKEN });
  });

  it('builds the link from the trusted site address, not from the request', async () => {
    await sendTeamInvitation({ invitation_id: ID, token: TOKEN, site_url: 'https://evil.example' }, deps());
    const html = send.mock.calls[0][2] as string;
    expect(html).toContain(`https://www.bottlesupapp.com/accept-invite?token=${TOKEN}`);
    expect(html).not.toContain('evil.example');
  });

  it('copes with a trailing slash on the site address', async () => {
    await sendTeamInvitation({ invitation_id: ID, token: TOKEN }, deps({ siteUrl: 'http://localhost:8080/' }));
    expect(send.mock.calls[0][2]).toContain('http://localhost:8080/accept-invite?token=');
  });
});

describe('when the database says no', () => {
  it.each([
    ['not allowed', 403],
    ['not authenticated', 403],
    ['please wait a minute before sending again', 429],
    ['email limit reached for this link', 429],
    ['invitation is not pending', 409],
  ])('"%s" becomes %i and nothing is sent', async (message, status) => {
    rpc.mockResolvedValue({ data: null, error: { message } });
    const out = await sendTeamInvitation({ invitation_id: ID, token: TOKEN }, deps());
    expect(out.status).toBe(status);
    expect(send).not.toHaveBeenCalled();
  });

  it('never leaks an unexpected database message', async () => {
    rpc.mockResolvedValue({ data: null, error: { message: 'relation "site_invitations" does not exist at character 14' } });
    const out = await sendTeamInvitation({ invitation_id: ID, token: TOKEN }, deps());
    expect(out.status).toBe(500);
    expect(JSON.stringify(out.body)).not.toContain('site_invitations');
  });

  it('treats an empty or incomplete answer as a failure, not a send', async () => {
    for (const data of [[], null, [{ ...reserved, invitee_email: null }], [{ ...reserved, org_name: '' }]]) {
      rpc.mockResolvedValue({ data, error: null });
      const out = await sendTeamInvitation({ invitation_id: ID, token: TOKEN }, deps());
      expect(out.status).toBe(500);
    }
    expect(send).not.toHaveBeenCalled();
  });
});

describe('when the email cannot be sent', () => {
  it('still succeeds, and says the email did not go (the screen then shows the link)', async () => {
    send.mockResolvedValue({ sent: false, reason: 'not_configured' });
    expect(await sendTeamInvitation({ invitation_id: ID, token: TOKEN }, deps())).toEqual({ status: 200, body: { sent: false, reason: 'not_configured' } });
    send.mockResolvedValue({ sent: false, reason: 'send_failed' });
    expect((await sendTeamInvitation({ invitation_id: ID, token: TOKEN }, deps())).body).toEqual({ sent: false, reason: 'send_failed' });
  });
});

describe('configuration and logging', () => {
  it.each(['', 'bottlesupapp.com', '/relative', 'javascript:alert(1)'])('refuses an unusable site address (%j) before using up a send', async (siteUrl) => {
    const out = await sendTeamInvitation({ invitation_id: ID, token: TOKEN }, deps({ siteUrl }));
    expect(out.status).toBe(500);
    expect(rpc).not.toHaveBeenCalled();
  });

  it('never writes the link token to the logs', async () => {
    const logs: string[] = [];
    vi.spyOn(console, 'error').mockImplementation((...a) => { logs.push(a.join(' ')); });
    vi.spyOn(console, 'warn').mockImplementation((...a) => { logs.push(a.join(' ')); });
    rpc.mockResolvedValue({ data: null, error: { message: `boom ${TOKEN}` } });
    await sendTeamInvitation({ invitation_id: ID, token: TOKEN }, deps());
    expect(logs.join('\n')).not.toContain(TOKEN);
  });
});
