import { beforeEach, describe, expect, it, vi } from 'vitest';
import { maskEmail, sendInvitationCode, type Deps } from '../../supabase/functions/_shared/invitationCode.ts';
import { buildCodeEmail, CODE_SUBJECT } from '../../supabase/functions/_shared/invitationCodeTemplate.ts';

const TOKEN = 'a'.repeat(64);

const issued = {
  invitee_email: 'newdoor@club.example', code: '482913', code_expires_at: '2026-10-20T15:10:00Z', role: 'door', org_name: 'Club Co', venue_name: 'Club A',
  event_title: null, shift_name: 'Friday late', access_start_at: null, access_end_at: '2026-10-21T08:00:00Z',
};

let rpcService: ReturnType<typeof vi.fn>;
let send: ReturnType<typeof vi.fn>;
const deps = (over: Partial<Deps> = {}): Deps => ({ callerEmail: 'newdoor@club.example', rpcService: rpcService as Deps['rpcService'], send: send as Deps['send'], ...over });

beforeEach(() => {
  vi.restoreAllMocks();
  vi.spyOn(console, 'error').mockImplementation(() => {});
  rpcService = vi.fn(async () => ({ data: [issued], error: null }));
  send = vi.fn(async () => ({ sent: true }));
});

describe('who may ask', () => {
  it('needs a signed-in caller with an address, before anything else', async () => {
    const out = await sendInvitationCode({ token: TOKEN }, deps({ callerEmail: null }));
    expect(out.status).toBe(401);
    expect(rpcService).not.toHaveBeenCalled();
    expect(send).not.toHaveBeenCalled();
  });

  it('asks the database for the caller\'s address, never one from the request', async () => {
    await sendInvitationCode({ token: TOKEN, email: 'someone.else@example.com', p_email: 'x@y.z' }, deps());
    expect(rpcService).toHaveBeenCalledWith('issue_invitation_code', { p_token: TOKEN, p_email: 'newdoor@club.example' });
  });
});

describe('request validation', () => {
  it.each([
    ['nothing', undefined],
    ['not an object', 'x'],
    ['no token', {}],
    ['a token that is too short', { token: 'abc' }],
    ['a token that is absurdly long', { token: 'a'.repeat(500) }],
    ['a number', { token: 5 }],
  ])('rejects %s without touching the database or sending anything', async (_n, body) => {
    const out = await sendInvitationCode(body, deps());
    expect(out.status).toBe(400);
    expect(rpcService).not.toHaveBeenCalled();
    expect(send).not.toHaveBeenCalled();
  });
});

describe('the code', () => {
  it('goes to the address the database returned, by e-mail, and nowhere else', async () => {
    const out = await sendInvitationCode({ token: TOKEN }, deps());
    expect(out.status).toBe(200);
    expect(send).toHaveBeenCalledTimes(1);
    expect(send.mock.calls[0][0]).toBe('newdoor@club.example');
    expect(send.mock.calls[0][1]).toBe(CODE_SUBJECT);
    expect(send.mock.calls[0][2]).toContain('482913');
    expect(send.mock.calls[0][3]).toContain('482913');
  });

  it('is NEVER in what is answered, whatever happens', async () => {
    const ok = await sendInvitationCode({ token: TOKEN }, deps());
    expect(JSON.stringify(ok)).not.toContain('482913');
    send.mockResolvedValue({ sent: false, reason: 'not_configured' });
    const notSent = await sendInvitationCode({ token: TOKEN }, deps());
    expect(JSON.stringify(notSent)).not.toContain('482913');
    send.mockRejectedValue(new Error('482913 leaked in an error'));
    await expect(sendInvitationCode({ token: TOKEN }, deps())).rejects.toThrow();
  });

  it('says where to look without giving the whole address away', async () => {
    const out = await sendInvitationCode({ token: TOKEN }, deps());
    expect(out.body).toEqual({ sent: true, to_hint: 'n***@club.example' });
  });

  it('says plainly when the mail could not be sent, with a reason and no code', async () => {
    send.mockResolvedValue({ sent: false, reason: 'not_configured' });
    expect((await sendInvitationCode({ token: TOKEN }, deps())).body).toEqual({ sent: false, reason: 'not_configured' });
    send.mockResolvedValue({ sent: false });
    expect((await sendInvitationCode({ token: TOKEN }, deps())).body).toEqual({ sent: false, reason: 'send_failed' });
  });

  it.each([
    ['five digits', '48291'],
    ['seven digits', '4829131'],
    ['letters', '48a913'],
    ['a code with spaces', '482 913'],
    ['nothing', ''],
  ])('is refused if the database returned %s: nothing is sent', async (_n, code) => {
    rpcService.mockResolvedValue({ data: [{ ...issued, code }], error: null });
    const out = await sendInvitationCode({ token: TOKEN }, deps());
    expect(out.status).toBe(500);
    expect(send).not.toHaveBeenCalled();
  });

  it.each(['invitee_email', 'role', 'org_name', 'code_expires_at'])('is refused if the database left out %s', async (field) => {
    rpcService.mockResolvedValue({ data: [{ ...issued, [field]: null }], error: null });
    expect((await sendInvitationCode({ token: TOKEN }, deps())).status).toBe(500);
    expect(send).not.toHaveBeenCalled();
  });

  it('is refused if the database returned nothing', async () => {
    rpcService.mockResolvedValue({ data: [], error: null });
    expect((await sendInvitationCode({ token: TOKEN }, deps())).status).toBe(500);
    expect(send).not.toHaveBeenCalled();
  });
});

describe('what the database refuses', () => {
  it.each([
    ['please wait a minute before asking for another code', 429, /wait a minute/i],
    ['too many codes: try again in an hour', 429, /try again in an hour/i],
    ['this link does not need a code', 409, /does not need a code/i],
    ['invitation is not pending', 409, /already used, cancelled or has expired/i],
    ['not allowed', 403, /not sent to the address you are signed in with/i],
  ])('"%s" becomes %i with a plain sentence, and nothing is sent', async (message, status, sentence) => {
    rpcService.mockResolvedValue({ data: null, error: { message } });
    const out = await sendInvitationCode({ token: TOKEN }, deps());
    expect(out.status).toBe(status);
    expect(String(out.body.error)).toMatch(sentence);
    expect(send).not.toHaveBeenCalled();
  });

  it('hides anything it does not recognise behind a generic sentence', async () => {
    rpcService.mockResolvedValue({ data: null, error: { message: 'relation "site_invitation_codes" does not exist' } });
    const out = await sendInvitationCode({ token: TOKEN }, deps());
    expect(out).toEqual({ status: 500, body: { error: 'Could not send the code.' } });
    expect(JSON.stringify(out)).not.toContain('site_invitation_codes');
  });
});

describe('maskEmail', () => {
  it('keeps the first letter and the domain', () => {
    expect(maskEmail('temp@club.example')).toBe('t***@club.example');
    expect(maskEmail('x@y.z')).toBe('x***@y.z');
  });

  it('never returns an address it cannot read', () => {
    expect(maskEmail('not-an-address')).toBe('***');
  });
});

describe('the e-mail', () => {
  const ctx = { code: '482913', role: 'door', orgName: 'Club Co', venueName: 'Club A', eventTitle: null, shiftName: 'Friday late', accessStartAt: null, accessEndAt: '2026-10-21T08:00:00Z', codeExpiresAt: '2026-10-20T15:10:00Z' };

  it('has a fixed subject: no name can reach a mail header', () => {
    expect(buildCodeEmail(ctx).subject).toBe('Your BottlesUp Business code');
    expect(buildCodeEmail({ ...ctx, orgName: 'Club\r\nBcc: evil@example.com' }).subject).toBe('Your BottlesUp Business code');
  });

  it('shows the code, its life, the role and the place, in HTML and in plain text', () => {
    const { html, text } = buildCodeEmail(ctx);
    for (const body of [html, text]) {
      expect(body).toContain('482913');
      expect(body).toContain('Door Staff');
      expect(body).toContain('Club Co');
      expect(body).toContain('Club A');
      expect(body).toContain('Friday late');
      expect(body).toContain('10 minutes');
    }
    expect(html).toContain('Never share this code');
  });

  it('escapes everything typed by a person', () => {
    const { html } = buildCodeEmail({ ...ctx, orgName: '<script>alert(1)</script>', venueName: '"><img src=x onerror=alert(1)>', shiftName: "O'Neil & Co" });
    expect(html).not.toContain('<script>');
    expect(html).not.toContain('<img');
    expect(html).toContain('&lt;script&gt;');
    expect(html).toContain('O&#39;Neil &amp; Co');
  });

  it('leaves out the lines it has nothing for', () => {
    const { text } = buildCodeEmail({ ...ctx, venueName: null, shiftName: null, accessEndAt: null });
    expect(text).not.toContain('Where:');
    expect(text).not.toContain('Shift:');
    expect(text).not.toContain('Access:');
  });
});
