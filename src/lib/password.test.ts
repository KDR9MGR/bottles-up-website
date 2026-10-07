import { describe, expect, it } from 'vitest';
import { isValidEmail, passwordProblem } from './password';

describe('passwordProblem', () => {
  it('accepts a password with length, upper case, a number and a symbol', () => {
    expect(passwordProblem('Night#Owl9')).toBeNull();
  });

  it.each([
    ['too short', 'Ab1!'],
    ['no upper case', 'night#owl9'],
    ['no number', 'Night#Owl!'],
    ['no symbol', 'NightOwl99'],
    ['empty', ''],
  ])('rejects %s', (_n, pw) => {
    expect(passwordProblem(pw)).toMatch(/at least 8 characters/);
  });

  it('counts exactly eight characters as long enough', () => {
    expect(passwordProblem('Abcdef1!')).toBeNull();
    expect(passwordProblem('Abcde1!')).not.toBeNull();
  });
});

describe('isValidEmail', () => {
  it('accepts ordinary addresses, ignoring surrounding spaces', () => {
    expect(isValidEmail('nia@example.com')).toBe(true);
    expect(isValidEmail('  nia@example.com ')).toBe(true);
  });
  it.each(['', 'nia', 'nia@', '@example.com', 'nia@example', 'n ia@example.com', 'a@b@c.com'])('rejects %j', (e) => {
    expect(isValidEmail(e)).toBe(false);
  });
});
