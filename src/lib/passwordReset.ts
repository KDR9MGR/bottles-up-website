// The "choose a new password" page, as plain functions so every rule can be tested without a browser.
//
// A reset e-mail leads here in one of three shapes:
//   1. ?token_hash=...&type=recovery&app=user|business    the link in our own e-mail template (supabase/email-templates/recovery.html).
//      Nothing is spent by opening it: the one-time token is only used when the person submits a new password, so a mail
//      scanner that opens the link cannot burn it.
//   2. #access_token=...&refresh_token=...&type=recovery   what Supabase's stock template builds. supabase-js reads the session
//      out of the address by itself; this page only has to notice that it did.
//   3. #error=access_denied&error_code=otp_expired&...      Supabase refused the link (it expired, or was already used).
// `app` says which app asked for the reset, so the page can name it and offer to open it.

export type ResetApp = 'user' | 'business' | 'web';

export type ResetLink =
  | { kind: 'token'; tokenHash: string; app: ResetApp }
  | { kind: 'session'; app: ResetApp }
  | { kind: 'failed'; app: ResetApp }
  | { kind: 'missing'; app: ResetApp };

// Supabase token hashes are hexadecimal; anything outside this shape is not one of ours, so it is never sent anywhere.
const TOKEN_HASH = /^[A-Za-z0-9_-]{8,256}$/;

function appFrom(raw: string | null): ResetApp {
  return raw === 'user' || raw === 'business' ? raw : 'web';
}

export function parseResetLink(search: string, hash: string): ResetLink {
  const query = new URLSearchParams(search);
  const fragment = new URLSearchParams(hash.startsWith('#') ? hash.slice(1) : hash);
  const app = appFrom(query.get('app') ?? fragment.get('app'));

  if (fragment.get('error') || query.get('error') || fragment.get('error_code') || query.get('error_code')) return { kind: 'failed', app };

  const tokenHash = query.get('token_hash');
  if (tokenHash && query.get('type') === 'recovery' && TOKEN_HASH.test(tokenHash)) return { kind: 'token', tokenHash, app };

  if (fragment.get('access_token') && fragment.get('type') === 'recovery') return { kind: 'session', app };

  return { kind: 'missing', app };
}

export const APP_NAME: Record<ResetApp, string> = {
  user: 'BottlesUp',
  business: 'BottlesUp Business',
  web: 'BottlesUp',
};

/** The address that opens the app on the phone, carrying the same one-time token. Null when there is no app to open. */
export function openInAppUrl(link: ResetLink): string | null {
  if (link.kind !== 'token') return null;
  const query = `token_hash=${encodeURIComponent(link.tokenHash)}&type=recovery`;
  if (link.app === 'user') return `bottlesup://reset-password?${query}`;
  // The business app routes by path, so the address carries one.
  if (link.app === 'business') return `bottlesupbusiness://app/reset-password?${query}`;
  return null;
}

/** Opens the app without a token, for the "all done" screen. */
export function openAppUrl(app: ResetApp): string | null {
  if (app === 'user') return 'bottlesup://auth-callback';
  if (app === 'business') return 'bottlesupbusiness://app/login';
  return null;
}

export function isMobileBrowser(userAgent: string): boolean {
  return /iPhone|iPad|iPod|Android/i.test(userAgent);
}

export const MIN_PASSWORD_LENGTH = 8;
// Supabase hashes passwords with bcrypt, which only reads the first 72 bytes and refuses more.
export const MAX_PASSWORD_BYTES = 72;

/** A sentence for the person, or null when the new password is acceptable. */
export function newPasswordProblem(password: string, confirm: string): string | null {
  if (password.length < MIN_PASSWORD_LENGTH) return `Use at least ${MIN_PASSWORD_LENGTH} characters.`;
  if (new TextEncoder().encode(password).length > MAX_PASSWORD_BYTES) return 'That password is too long. Use 72 characters or fewer.';
  if (password !== confirm) return 'The two passwords do not match.';
  return null;
}

// The few pieces of an auth error this module looks at. supabase-js errors have all of them.
export interface AuthLikeError {
  message: string;
  code?: string;
  status?: number;
  name?: string;
}

export interface RecoveryAuth {
  verifyOtp(params: { token_hash: string; type: 'recovery' }): Promise<{ error: AuthLikeError | null }>;
  hasSession(): Promise<boolean>;
  updatePassword(password: string): Promise<{ error: AuthLikeError | null }>;
  signOutHere(): Promise<void>;
}

export type ResetFailure = 'link_unusable' | 'same_password' | 'weak_password' | 'network' | 'failed';

// sessionOpened: the token was spent and the person is signed in to the reset, so the retry must continue from that session.
export interface ResetFailed {
  ok: false;
  reason: ResetFailure;
  message: string;
  canRetry: boolean;
  sessionOpened: boolean;
}

export type ResetResult = { ok: true } | ResetFailed;

// The project does not compile with strictNullChecks, where checking `ok` alone would not narrow the union.
export function didFail(result: ResetResult): result is ResetFailed {
  return !result.ok;
}

const MESSAGES: Record<ResetFailure, string> = {
  link_unusable: 'This link has expired or was already used. Ask for a new one from the app.',
  same_password: 'Your new password must be different from your old one.',
  weak_password: 'That password is too easy to guess. Try a longer one, with letters and numbers.',
  network: 'We could not reach BottlesUp. Check your connection and try again.',
  failed: 'We could not update your password. Please try again.',
};

function failure(reason: ResetFailure, sessionOpened = false): ResetFailed {
  // Only a dead link cannot be tried again: for everything else the person just resubmits.
  return { ok: false, reason, message: MESSAGES[reason], canRetry: reason !== 'link_unusable', sessionOpened };
}

function isNetworkError(error: AuthLikeError): boolean {
  return error.name === 'AuthRetryableFetchError' || error.status === 0;
}

function classifyVerify(error: AuthLikeError): ResetFailed {
  if (isNetworkError(error)) return failure('network');
  return failure('link_unusable');
}

function classifyUpdate(error: AuthLikeError, sessionOpened: boolean): ResetFailed {
  if (isNetworkError(error)) return failure('network', sessionOpened);
  if (error.code === 'same_password') return failure('same_password', sessionOpened);
  if (error.code === 'weak_password') return failure('weak_password', sessionOpened);
  if (error.code === 'session_not_found' || error.code === 'session_expired' || error.status === 401 || error.status === 403) return failure('link_unusable');
  return failure('failed', sessionOpened);
}

/**
 * Turn the link into a session, set the new password, and end the session again. The one-time token is spent by verifyOtp, so when
 * the new password is then refused (too weak, same as before) the session is kept: the caller switches to a `session` link and the
 * person simply types another password instead of asking for a new e-mail.
 */
export async function completeReset(auth: RecoveryAuth, link: ResetLink, password: string): Promise<ResetResult> {
  if (link.kind === 'token') {
    const { error } = await auth.verifyOtp({ token_hash: link.tokenHash, type: 'recovery' });
    if (error) return classifyVerify(error);
  } else if (link.kind === 'session') {
    if (!(await auth.hasSession())) return failure('link_unusable');
  } else {
    return failure('link_unusable');
  }

  const { error } = await auth.updatePassword(password);
  if (error) return classifyUpdate(error, true);

  // Done: nobody should stay signed in on this browser because they reset a password.
  try {
    await auth.signOutHere();
  } catch {
    // The password is already changed; failing to clear the local session must not turn that into an error.
  }
  return { ok: true };
}
