import { describe, expect, it } from 'vitest';
import { isDisposableEmail } from './disposableEmail';

describe('isDisposableEmail', () => {
  it('flags known throwaway domains', () => {
    expect(isDisposableEmail('x@mailinator.com')).toBe(true);
    expect(isDisposableEmail('x@yopmail.com')).toBe(true);
  });
  it('ignores case and surrounding spaces', () => {
    expect(isDisposableEmail('  X@MAILINATOR.COM ')).toBe(true);
  });
  it('lets normal addresses through', () => {
    expect(isDisposableEmail('ada@gmail.com')).toBe(false);
    expect(isDisposableEmail('ada@bottlesupapp.com')).toBe(false);
  });
  it('does not flag input with no domain', () => {
    expect(isDisposableEmail('')).toBe(false);
    expect(isDisposableEmail('not-an-email')).toBe(false);
  });
  // Documents a limit rather than a wish: only exact domains match. The code's
  // own comment says the server re-checks, so this is a convenience, not a gate.
  it('matches the exact domain only, so a subdomain slips past the client-side check', () => {
    expect(isDisposableEmail('x@sub.mailinator.com')).toBe(false);
  });
});
