// A visitor who arrives through a venue or event booking link keeps that destination
// through sign-up and log-in (client brief, section 1). The destination travels in a
// `next` query parameter, which anyone can edit, so it is only ever honoured when it is a
// path on this same site. Anything else (another domain, a scheme, a protocol-relative
// URL) is dropped, which is what prevents `?next=https://evil.example` open redirects.

const MAX_LENGTH = 500;

// Pages that exist to sign someone in or up. Sending a freshly signed-in person back to
// one of them would loop, so they are never a valid destination.
const AUTH_PAGES = ['/login', '/signup', '/auth', '/home'];

/** Returns `raw` if it is a safe same-site path, otherwise `fallback`. */
export function sanitizeNext(raw: string | null | undefined, fallback = '/'): string {
  if (typeof raw !== 'string') return fallback;
  const value = raw.trim();
  if (value === '' || value.length > MAX_LENGTH) return fallback;
  // Must be a path: starts with exactly one slash. The leading-slash rule and the origin check
  // further down overlap on purpose ("//host" is caught by both): defense in depth, not dead code.
  if (!value.startsWith('/') || value.startsWith('//')) return fallback;
  // No backslashes (browsers treat "/\host" like "//host"), and no control characters or
  // whitespace that could be used to smuggle a different URL past the checks above.
  for (const ch of value) {
    const code = ch.charCodeAt(0);
    if (code <= 0x1f || code === 0x7f || ch === '\\' || /\s/.test(ch)) return fallback;
  }
  // Resolve against a throwaway origin: a safe path must stay on that origin.
  try {
    const base = 'https://site.invalid';
    const url = new URL(value, base);
    if (url.origin !== base) return fallback;
    const path = url.pathname.toLowerCase();
    if (AUTH_PAGES.some((p) => path === p || path.startsWith(`${p}/`))) return fallback;
  } catch {
    return fallback;
  }
  return value;
}

/** `/login?next=%2Fvenues%2Fxno`, or just `/login` when there is nothing worth keeping. */
export function withNext(path: string, next: string | null | undefined): string {
  const safe = sanitizeNext(next, '');
  if (!safe || safe === '/') return path;
  return `${path}${path.includes('?') ? '&' : '?'}next=${encodeURIComponent(safe)}`;
}

/** The page the visitor is on right now, as a `next` value for the log-in / sign-up links. */
export function currentPathAsNext(location: { pathname: string; search?: string; hash?: string }): string {
  return sanitizeNext(`${location.pathname}${location.search ?? ''}${location.hash ?? ''}`, '');
}
