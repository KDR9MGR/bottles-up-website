import { describe, expect, it } from 'vitest';
import {
  actionsFor, actionHelp, cleanBannedTerm, parseReportGroups, profileName, reasonText, rulesProblem, type ReportGroup,
} from './moderation';

const row = (over: Record<string, unknown> = {}) => ({
  kind: 'post', target: 'p1', status: 'open', action: null, note: null, handled_at: null, reports: 3, reporters: 3, reasons: ['spam', 'scam'], details: ['they want money'],
  excerpt: 'Buy my stuff', first_at: '2026-10-27T10:00:00Z', last_at: '2026-10-27T12:00:00Z',
  profile: { id: 'u1', handle: 'ann', display_name: 'Ann Lee', status: 'active' }, state: 'active', ...over,
});

const group = (over: Partial<ReportGroup> = {}): ReportGroup => ({ ...parseReportGroups([row()])[0], ...over });

describe('reading the queue', () => {
  it('reads a group with everything the database sends', () => {
    const [g] = parseReportGroups([row()]);
    expect(g).toMatchObject({ kind: 'post', target: 'p1', status: 'open', reports: 3, reporters: 3, reasons: ['spam', 'scam'], details: ['they want money'], excerpt: 'Buy my stuff', state: 'active' });
    expect(g.profile).toEqual({ id: 'u1', handle: 'ann', displayName: 'Ann Lee', status: 'active' });
    expect(g.lastAt).toBe('2026-10-27T12:00:00Z');
  });

  it('leaves out a row it cannot read instead of showing it wrong', () => {
    expect(parseReportGroups([row({ kind: 'chat' }), row({ status: 'weird' }), row({ target: null }), row({ first_at: null }), 'junk', null, row({ target: 'ok' })]).map((g) => g.target)).toEqual(['ok']);
    expect(parseReportGroups(null)).toEqual([]);
    expect(parseReportGroups({})).toEqual([]);
  });

  it('copes with a missing profile (an account that was deleted), a missing last time and an unknown state', () => {
    const [g] = parseReportGroups([row({ profile: null, last_at: null, state: 'mystery', reasons: 'x', details: null })]);
    expect(g.profile).toBeNull();
    expect(g.lastAt).toBe(g.firstAt);
    expect(g.state).toBe('active');
    expect(g.reasons).toEqual([]);
    expect(g.details).toEqual([]);
  });

  it('names reasons and profiles for a person to read', () => {
    expect(reasonText(['spam', 'scam', 'brand_new'])).toBe('Spam, Scam or fraud, brand_new');
    expect(profileName(group().profile)).toBe('Ann Lee (@ann)');
    expect(profileName({ id: 'x', handle: 'ann', displayName: null, status: null })).toBe('@ann');
    expect(profileName({ id: 'x', handle: null, displayName: 'Ann', status: null })).toBe('Ann');
    expect(profileName({ id: 'x', handle: null, displayName: null, status: null })).toBe('Unnamed profile');
    expect(profileName(null)).toBe('Account deleted');
  });
});

describe('what a moderator may do', () => {
  it('an open post can be dismissed, removed or its person suspended', () => {
    expect(actionsFor(group())).toEqual(['dismiss', 'remove', 'suspend']);
  });

  it('an open profile cannot be "removed", only dismissed or suspended', () => {
    expect(actionsFor(group({ kind: 'profile' }))).toEqual(['dismiss', 'suspend']);
  });

  it('content that is already removed is not removed twice, and can be restored', () => {
    expect(actionsFor(group({ state: 'removed' }))).toEqual(['dismiss', 'suspend', 'restore']);
  });

  it('a person who is already suspended is not suspended twice', () => {
    expect(actionsFor(group({ profile: { id: 'u1', handle: 'ann', displayName: 'Ann', status: 'suspended' } }))).toEqual(['dismiss', 'remove']);
  });

  it('with no profile left there is nobody to suspend', () => {
    expect(actionsFor(group({ profile: null }))).toEqual(['dismiss', 'remove']);
  });

  it('a decided group offers only a restore, and only while something is hidden', () => {
    expect(actionsFor(group({ status: 'actioned', state: 'removed' }))).toEqual(['restore']);
    expect(actionsFor(group({ status: 'actioned', state: 'active', profile: { id: 'u1', handle: 'ann', displayName: 'Ann', status: 'suspended' } }))).toEqual(['restore']);
    expect(actionsFor(group({ status: 'actioned', state: 'suspended' }))).toEqual(['restore']);
    expect(actionsFor(group({ status: 'dismissed', state: 'active' }))).toEqual([]);
  });

  it('every action says in a sentence what it does', () => {
    for (const a of ['dismiss', 'remove', 'suspend', 'restore'] as const) expect(actionHelp(a, group()).length).toBeGreaterThan(20);
    expect(actionHelp('remove', group({ kind: 'message' }))).toMatch(/both people/);
    expect(actionHelp('remove', group())).toMatch(/everyone/);
  });
});

describe('rules and banned words', () => {
  it('rules are 20 to 8000 characters once trimmed', () => {
    expect(rulesProblem('short')).toMatch(/at least 20/);
    expect(rulesProblem(`   ${'a'.repeat(19)}   `)).toMatch(/at least 20/);
    expect(rulesProblem('a'.repeat(20))).toBeNull();
    expect(rulesProblem('a'.repeat(8000))).toBeNull();
    expect(rulesProblem('a'.repeat(8001))).toMatch(/8000/);
  });

  it('a banned term is cleaned the way the database cleans it', () => {
    expect(cleanBannedTerm('  Bad   WORD ')).toBe('bad word');
    expect(cleanBannedTerm('a')).toBeNull();
    expect(cleanBannedTerm('x'.repeat(41))).toBeNull();
    expect(cleanBannedTerm('no-dashes')).toBeNull();
    expect(cleanBannedTerm('abc123')).toBe('abc123');
  });
});
