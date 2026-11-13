import { describe, expect, it } from 'vitest';
import {
  APP_NAME,
  completeReset,
  didFail,
  isMobileBrowser,
  newPasswordProblem,
  openAppUrl,
  openInAppUrl,
  parseResetLink,
  type AuthLikeError,
  type RecoveryAuth,
  type ResetLink,
} from './passwordReset';

const HASH = 'a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c';

describe('parseResetLink', () => {
  it('reads the token link our e-mail builds, and the app it came from', () => {
    expect(parseResetLink(`?token_hash=${HASH}&type=recovery&app=business`, '')).toEqual({ kind: 'token', tokenHash: HASH, app: 'business' });
    expect(parseResetLink(`?token_hash=${HASH}&type=recovery&app=user`, '')).toEqual({ kind: 'token', tokenHash: HASH, app: 'user' });
  });

  it('treats a missing or unknown app as the website', () => {
    expect(parseResetLink(`?token_hash=${HASH}&type=recovery`, '')).toMatchObject({ kind: 'token', app: 'web' });
    expect(parseResetLink(`?token_hash=${HASH}&type=recovery&app=admin`, '')).toMatchObject({ app: 'web' });
  });

  it('needs type=recovery: a sign-up or magic-link token is not a password reset', () => {
    expect(parseResetLink(`?token_hash=${HASH}&type=signup`, '').kind).toBe('missing');
    expect(parseResetLink(`?token_hash=${HASH}&type=magiclink`, '').kind).toBe('missing');
    expect(parseResetLink(`?token_hash=${HASH}`, '').kind).toBe('missing');
  });

  it('refuses a token that is not the shape of one of ours', () => {
    expect(parseResetLink('?token_hash=short&type=recovery', '').kind).toBe('missing');
    expect(parseResetLink(`?token_hash=${encodeURIComponent('abc def ghi jkl')}&type=recovery`, '').kind).toBe('missing');
    expect(parseResetLink(`?token_hash=${encodeURIComponent('<script>alert(1)</script>')}&type=recovery`, '').kind).toBe('missing');
    expect(parseResetLink(`?token_hash=${'a'.repeat(300)}&type=recovery`, '').kind).toBe('missing');
  });

  it('recognises the session link Supabase\'s stock template builds', () => {
    expect(parseResetLink('?app=user', '#access_token=abc.def.ghi&refresh_token=xyz&type=recovery')).toEqual({ kind: 'session', app: 'user' });
    expect(parseResetLink('', 'access_token=abc&type=recovery')).toEqual({ kind: 'session', app: 'web' });
  });

  it('a session link of another type is not a reset', () => {
    expect(parseResetLink('', '#access_token=abc&type=signup').kind).toBe('missing');
    expect(parseResetLink('', '#access_token=abc').kind).toBe('missing');
  });

  it('reports a refused link, whichever way Supabase says so', () => {
    expect(parseResetLink('', '#error=access_denied&error_code=otp_expired&error_description=Email+link+is+invalid+or+has+expired').kind).toBe('failed');
    expect(parseResetLink('?error=access_denied', '').kind).toBe('failed');
    expect(parseResetLink('?error_code=otp_expired', '').kind).toBe('failed');
  });

  it('an error wins over a token in the same address', () => {
    expect(parseResetLink(`?token_hash=${HASH}&type=recovery`, '#error=access_denied').kind).toBe('failed');
  });

  it('an empty address is missing, and keeps the app', () => {
    expect(parseResetLink('', '')).toEqual({ kind: 'missing', app: 'web' });
    expect(parseResetLink('?app=business', '')).toEqual({ kind: 'missing', app: 'business' });
  });
});

describe('openInAppUrl', () => {
  it('opens the customer app on its own scheme, carrying the token', () => {
    expect(openInAppUrl({ kind: 'token', tokenHash: HASH, app: 'user' })).toBe(`bottlesup://reset-password?token_hash=${HASH}&type=recovery`);
  });

  it('opens the business app by a path, because that app routes by path', () => {
    expect(openInAppUrl({ kind: 'token', tokenHash: HASH, app: 'business' })).toBe(`bottlesupbusiness://app/reset-password?token_hash=${HASH}&type=recovery`);
  });

  it('has nothing to open for the website, or when there is no token to hand over', () => {
    expect(openInAppUrl({ kind: 'token', tokenHash: HASH, app: 'web' })).toBeNull();
    expect(openInAppUrl({ kind: 'session', app: 'user' })).toBeNull();
    expect(openInAppUrl({ kind: 'missing', app: 'user' })).toBeNull();
    expect(openInAppUrl({ kind: 'failed', app: 'business' })).toBeNull();
  });

  it('encodes the token', () => {
    expect(openInAppUrl({ kind: 'token', tokenHash: 'ab_cd-ef123456', app: 'user' })).toContain('token_hash=ab_cd-ef123456&');
  });
});

describe('openAppUrl and app names', () => {
  it('has a plain way into each app', () => {
    expect(openAppUrl('user')).toBe('bottlesup://auth-callback');
    expect(openAppUrl('business')).toBe('bottlesupbusiness://app/login');
    expect(openAppUrl('web')).toBeNull();
  });

  it('names the app the way the person knows it', () => {
    expect(APP_NAME).toEqual({ user: 'BottlesUp', business: 'BottlesUp Business', web: 'BottlesUp' });
  });
});

describe('isMobileBrowser', () => {
  it('knows phones and tablets', () => {
    expect(isMobileBrowser('Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15')).toBe(true);
    expect(isMobileBrowser('Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 Chrome/120 Mobile')).toBe(true);
    expect(isMobileBrowser('Mozilla/5.0 (iPad; CPU OS 17_0 like Mac OS X)')).toBe(true);
  });

  it('does not take a computer for a phone', () => {
    expect(isMobileBrowser('Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Safari/605.1.15')).toBe(false);
    expect(isMobileBrowser('Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/120')).toBe(false);
    expect(isMobileBrowser('')).toBe(false);
  });
});

describe('newPasswordProblem', () => {
  it('accepts 8 to 72 bytes that match', () => {
    expect(newPasswordProblem('abcdefgh', 'abcdefgh')).toBeNull();
    expect(newPasswordProblem('a'.repeat(72), 'a'.repeat(72))).toBeNull();
  });

  it('refuses 7 characters, accepts exactly 8', () => {
    expect(newPasswordProblem('abcdefg', 'abcdefg')).toBe('Use at least 8 characters.');
    expect(newPasswordProblem('abcdefgh', 'abcdefgh')).toBeNull();
  });

  it('refuses more than 72 bytes, counting bytes and not characters', () => {
    expect(newPasswordProblem('a'.repeat(73), 'a'.repeat(73))).toMatch(/too long/);
    // 37 two-byte characters are 74 bytes, though only 37 characters.
    expect(newPasswordProblem('é'.repeat(37), 'é'.repeat(37))).toMatch(/too long/);
    expect(newPasswordProblem('é'.repeat(36), 'é'.repeat(36))).toBeNull();
  });

  it('checks the length before the match, so the first thing said is the first thing to fix', () => {
    expect(newPasswordProblem('short', 'different')).toBe('Use at least 8 characters.');
  });

  it('refuses two different passwords', () => {
    expect(newPasswordProblem('abcdefgh', 'abcdefgH')).toBe('The two passwords do not match.');
    expect(newPasswordProblem('abcdefgh', '')).toBe('The two passwords do not match.');
  });
});

// A scripted stand-in for supabase.auth that records what was asked of it, in order.
function fakeAuth(script: {
  verify?: AuthLikeError | null;
  session?: boolean;
  update?: AuthLikeError | null;
  signOutThrows?: boolean;
}) {
  const calls: string[] = [];
  const auth: RecoveryAuth = {
    async verifyOtp(params) {
      calls.push(`verify:${params.token_hash}:${params.type}`);
      return { error: script.verify ?? null };
    },
    async hasSession() {
      calls.push('hasSession');
      return script.session ?? false;
    },
    async updatePassword(password) {
      calls.push(`update:${password}`);
      return { error: script.update ?? null };
    },
    async signOutHere() {
      calls.push('signOut');
      if (script.signOutThrows) throw new Error('storage unavailable');
    },
  };
  return { auth, calls };
}

const TOKEN_LINK: ResetLink = { kind: 'token', tokenHash: HASH, app: 'user' };
const SESSION_LINK: ResetLink = { kind: 'session', app: 'web' };

describe('completeReset', () => {
  it('verifies the token, sets the password, then ends the session, in that order', async () => {
    const { auth, calls } = fakeAuth({});
    expect(await completeReset(auth, TOKEN_LINK, 'new-password-1')).toEqual({ ok: true });
    expect(calls).toEqual([`verify:${HASH}:recovery`, 'update:new-password-1', 'signOut']);
  });

  it('with a session link it does not verify anything, only checks the session is there', async () => {
    const { auth, calls } = fakeAuth({ session: true });
    expect(await completeReset(auth, SESSION_LINK, 'new-password-1')).toEqual({ ok: true });
    expect(calls).toEqual(['hasSession', 'update:new-password-1', 'signOut']);
  });

  it('a session link with no session behind it is a dead link, and changes nothing', async () => {
    const { auth, calls } = fakeAuth({ session: false });
    const result = await completeReset(auth, SESSION_LINK, 'new-password-1');
    expect(result).toMatchObject({ ok: false, reason: 'link_unusable', canRetry: false, sessionOpened: false });
    expect(calls).toEqual(['hasSession']);
  });

  it('a link that is missing or failed never reaches the server', async () => {
    for (const link of [{ kind: 'missing', app: 'web' }, { kind: 'failed', app: 'web' }] as ResetLink[]) {
      const { auth, calls } = fakeAuth({ session: true });
      expect(await completeReset(auth, link, 'new-password-1')).toMatchObject({ ok: false, reason: 'link_unusable' });
      expect(calls).toEqual([]);
    }
  });

  it('an expired or used token stops before the password is touched', async () => {
    const { auth, calls } = fakeAuth({ verify: { message: 'Email link is invalid or has expired', code: 'otp_expired', status: 403 } });
    const result = await completeReset(auth, TOKEN_LINK, 'new-password-1');
    expect(result).toMatchObject({ ok: false, reason: 'link_unusable', canRetry: false, sessionOpened: false });
    expect(calls).toEqual([`verify:${HASH}:recovery`]);
  });

  it('losing the connection while verifying can be tried again with the same link', async () => {
    const { auth } = fakeAuth({ verify: { message: 'fetch failed', name: 'AuthRetryableFetchError', status: 0 } });
    expect(await completeReset(auth, TOKEN_LINK, 'new-password-1')).toMatchObject({ ok: false, reason: 'network', canRetry: true, sessionOpened: false });
  });

  it('a refused new password keeps the session so the person can type another, and does not sign out', async () => {
    const { auth, calls } = fakeAuth({ update: { message: 'New password should be different', code: 'same_password', status: 422 } });
    const result = await completeReset(auth, TOKEN_LINK, 'old-password');
    expect(result).toMatchObject({ ok: false, reason: 'same_password', canRetry: true, sessionOpened: true });
    expect(calls).toEqual([`verify:${HASH}:recovery`, 'update:old-password']);
  });

  it('says a weak password is weak', async () => {
    const { auth } = fakeAuth({ update: { message: 'Password is known to be weak', code: 'weak_password', status: 422 } });
    const result = await completeReset(auth, TOKEN_LINK, 'password');
    expect(result).toMatchObject({ ok: false, reason: 'weak_password', canRetry: true, sessionOpened: true });
    expect((result as { message: string }).message).toMatch(/too easy to guess/);
  });

  it('a session that died before the password was set is a dead link', async () => {
    for (const update of [{ message: 'x', code: 'session_not_found' }, { message: 'x', code: 'session_expired' }, { message: 'x', status: 401 }, { message: 'x', status: 403 }]) {
      const { auth } = fakeAuth({ update });
      expect(await completeReset(auth, TOKEN_LINK, 'new-password-1')).toMatchObject({ ok: false, reason: 'link_unusable', canRetry: false, sessionOpened: false });
    }
  });

  it('losing the connection while saving keeps the session for another try', async () => {
    const { auth } = fakeAuth({ session: true, update: { message: 'fetch failed', name: 'AuthRetryableFetchError', status: 0 } });
    expect(await completeReset(auth, SESSION_LINK, 'new-password-1')).toMatchObject({ ok: false, reason: 'network', canRetry: true, sessionOpened: true });
  });

  it('any other server error is a plain failure that can be tried again', async () => {
    const { auth } = fakeAuth({ update: { message: 'boom', status: 500 } });
    expect(await completeReset(auth, TOKEN_LINK, 'new-password-1')).toMatchObject({ ok: false, reason: 'failed', canRetry: true, sessionOpened: true });
  });

  it('a failure to clear the local session after success is not reported as a failure', async () => {
    const { auth, calls } = fakeAuth({ signOutThrows: true });
    expect(await completeReset(auth, TOKEN_LINK, 'new-password-1')).toEqual({ ok: true });
    expect(calls).toContain('signOut');
  });

  it('didFail tells a failure from a success', async () => {
    expect(didFail({ ok: true })).toBe(false);
    const { auth } = fakeAuth({ verify: { message: 'x', code: 'otp_expired' } });
    expect(didFail(await completeReset(auth, TOKEN_LINK, 'new-password-1'))).toBe(true);
  });

  it('never puts the password anywhere but the update call', async () => {
    const { auth, calls } = fakeAuth({});
    await completeReset(auth, TOKEN_LINK, 'S3cret-pass');
    expect(calls.filter((c) => c.includes('S3cret-pass'))).toEqual(['update:S3cret-pass']);
  });
});
