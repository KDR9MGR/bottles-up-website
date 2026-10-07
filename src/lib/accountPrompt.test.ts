import { describe, expect, it } from 'vitest';
import { PROMPT_DISMISS_DAYS, safeStoreUrl, shouldShowAccountPrompt } from './accountPrompt';

const DAY = 24 * 60 * 60 * 1000;
const NOW = Date.UTC(2026, 9, 10, 12);
const base = { loading: false, signedIn: false, dismissedAt: null, now: NOW };

describe('shouldShowAccountPrompt', () => {
  it('shows to a signed-out visitor who has not dismissed it', () => {
    expect(shouldShowAccountPrompt(base)).toBe(true);
  });

  it('never shows to someone signed in (no asking an existing user to register again)', () => {
    expect(shouldShowAccountPrompt({ ...base, signedIn: true })).toBe(false);
  });

  it('shows nothing while the session is still being checked, so signed-in people never see a flash', () => {
    expect(shouldShowAccountPrompt({ ...base, loading: true })).toBe(false);
    expect(shouldShowAccountPrompt({ ...base, loading: true, signedIn: true })).toBe(false);
  });

  it('stays hidden after being dismissed', () => {
    expect(shouldShowAccountPrompt({ ...base, dismissedAt: String(NOW - 1000) })).toBe(false);
    expect(shouldShowAccountPrompt({ ...base, dismissedAt: String(NOW - 29 * DAY) })).toBe(false);
  });

  it('comes back once the dismissal window has passed', () => {
    expect(shouldShowAccountPrompt({ ...base, dismissedAt: String(NOW - PROMPT_DISMISS_DAYS * DAY) })).toBe(true);
    expect(shouldShowAccountPrompt({ ...base, dismissedAt: String(NOW - 90 * DAY) })).toBe(true);
  });

  it.each(['', 'abc', 'NaN', '0', '-5', 'Infinity'])('a damaged stored value (%j) does not hide it forever', (v) => {
    expect(shouldShowAccountPrompt({ ...base, dismissedAt: v })).toBe(true);
  });

  it('a dismissal dated in the future (clock change) does not hide it forever', () => {
    expect(shouldShowAccountPrompt({ ...base, dismissedAt: String(NOW + 5 * DAY) })).toBe(true);
  });
});

describe('safeStoreUrl', () => {
  it('accepts https store links', () => {
    expect(safeStoreUrl('https://apps.apple.com/app/id123')).toBe('https://apps.apple.com/app/id123');
  });
  it.each([undefined, '', 'http://apps.apple.com/x', 'javascript:alert(1)', 'data:text/html,x', 'apps.apple.com/x', 'not a url'])('rejects %j', (v) => {
    expect(safeStoreUrl(v)).toBeNull();
  });
});
