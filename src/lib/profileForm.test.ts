import { describe, expect, it } from 'vitest';
import { normalizeUsername, validateUsernameShape } from './profileForm';

describe('username rules (mirror the database)', () => {
  it('lower-cases and trims', () => {
    expect(normalizeUsername('  Night.Owl ')).toBe('night.owl');
  });

  it.each(['night.owl', 'nia_99', 'a.b', 'x'.repeat(30), 'abc'])('accepts %s', (u) => {
    expect(validateUsernameShape(u)).toBeNull();
  });

  it.each([
    ['', /at least 3/],
    ['ab', /at least 3/],
    ['x'.repeat(31), /at most 30/],
    ['night owl', /only lowercase/],
    ['night-owl', /only lowercase/],
    ['Night', /only lowercase/],
    ['nía', /only lowercase/],
    ['admin', /reserved/],
    ['bottlesup', /reserved/],
  ])('rejects %j', (u, message) => {
    expect(validateUsernameShape(u)).toMatch(message);
  });
});
