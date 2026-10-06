import { describe, expect, it } from 'vitest';
import { currentPathAsNext, sanitizeNext, withNext } from './safeNext';

describe('sanitizeNext', () => {
  it('keeps a normal same-site path, query and hash', () => {
    expect(sanitizeNext('/venues/xno')).toBe('/venues/xno');
    expect(sanitizeNext('/events/42?ref=ig#tickets')).toBe('/events/42?ref=ig#tickets');
    expect(sanitizeNext('/tables/abc?date=2026-10-10')).toBe('/tables/abc?date=2026-10-10');
  });

  it('falls back when there is nothing usable', () => {
    expect(sanitizeNext(null)).toBe('/');
    expect(sanitizeNext(undefined)).toBe('/');
    expect(sanitizeNext('')).toBe('/');
    expect(sanitizeNext('   ')).toBe('/');
    expect(sanitizeNext(null, '')).toBe('');
  });

  it.each([
    ['another domain', 'https://evil.example/phish'],
    ['http scheme', 'http://evil.example'],
    ['protocol-relative', '//evil.example'],
    ['protocol-relative with path', '//evil.example/login'],
    ['backslash trick', '/\\evil.example'],
    ['double backslash', '\\\\evil.example'],
    ['javascript scheme', 'javascript:alert(1)'],
    ['data scheme', 'data:text/html,<script>alert(1)</script>'],
    ['no leading slash', 'venues/xno'],
    ['a bare host', 'evil.example'],
    ['tab inside', '/venues/\txno'],
    ['newline inside', '/venues/\nxno'],
    ['encoded-looking whitespace char', '/venues/xno\u0000'],
    ['space inside', '/venues/ xno'],
  ])('rejects %s', (_name, value) => {
    expect(sanitizeNext(value, '/safe')).toBe('/safe');
  });

  it('rejects absurdly long values', () => {
    expect(sanitizeNext('/' + 'a'.repeat(600), '/safe')).toBe('/safe');
    expect(sanitizeNext('/' + 'a'.repeat(499))).toBe('/' + 'a'.repeat(499));
  });

  it('never sends a signed-in person back to a sign-in page (no redirect loops)', () => {
    for (const p of ['/login', '/login?next=/x', '/signup', '/signup/personal', '/auth/callback', '/home', '/LOGIN']) {
      expect(sanitizeNext(p, '/safe')).toBe('/safe');
    }
  });

  it('does not mistake a venue whose slug merely starts with "login" for a sign-in page', () => {
    expect(sanitizeNext('/venues/login-lounge')).toBe('/venues/login-lounge');
    expect(sanitizeNext('/loginx')).toBe('/loginx');
  });
});

describe('withNext', () => {
  it('appends an encoded next parameter', () => {
    expect(withNext('/login', '/venues/xno')).toBe('/login?next=%2Fvenues%2Fxno');
    expect(withNext('/signup/personal', '/events/9?ref=ig')).toBe('/signup/personal?next=%2Fevents%2F9%3Fref%3Dig');
  });

  it('adds with & when the path already has a query', () => {
    expect(withNext('/signup?type=venue_owner', '/venues/xno')).toBe('/signup?type=venue_owner&next=%2Fvenues%2Fxno');
  });

  it('adds nothing for an unsafe, empty or root destination', () => {
    expect(withNext('/login', 'https://evil.example')).toBe('/login');
    expect(withNext('/login', null)).toBe('/login');
    expect(withNext('/login', '/')).toBe('/login');
    expect(withNext('/login', '/login')).toBe('/login');
  });

  it('round-trips through URLSearchParams', () => {
    const dest = '/venues/xno?table=gold&date=2026-10-10#book';
    const href = withNext('/login', dest);
    const parsed = new URL(href, 'https://site.invalid').searchParams.get('next');
    expect(sanitizeNext(parsed)).toBe(dest);
  });
});

describe('currentPathAsNext', () => {
  it('captures where the visitor is', () => {
    expect(currentPathAsNext({ pathname: '/venues/xno', search: '?table=gold', hash: '#book' })).toBe('/venues/xno?table=gold#book');
    expect(currentPathAsNext({ pathname: '/events/3' })).toBe('/events/3');
  });

  it('is empty on the home page and on sign-in pages', () => {
    expect(currentPathAsNext({ pathname: '/' })).toBe('/');
    expect(currentPathAsNext({ pathname: '/login' })).toBe('');
  });
});
