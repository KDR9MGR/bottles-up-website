import { beforeEach, describe, expect, it, vi } from 'vitest';

const h = vi.hoisted(() => ({ call: vi.fn() }));
vi.mock('./account', async (orig) => ({ ...(await orig<typeof import('./account')>()), call: h.call }));
import {
  addressLines, decideReview, decideVerification, fetchAwards, fetchLevels, fetchPlaques, fetchReviews, fetchVerifications, followersText, levelForm, levelProblem, markDelivered, markShipped,
  parseAwards, parseLevels, parsePlaques, parseReviews, parseVerifications, revokeAward, saveLevel, type LevelForm,
} from './recognition';

beforeEach(() => h.call.mockReset());

const who = { display_name: 'Ann Lee', handle: 'ann', category: 'dj' };

describe('reading the lists', () => {
  it('verification requests: who asked, what they said and how many follow them; a row that cannot be read is left out', () => {
    const rows = parseVerifications([
      { id: 'v1', state: 'requested', note: 'I am a radio host.', created_at: '2099-01-01T00:00:00Z', followers: 12, profile: who },
      { id: 'v2', state: 'rejected', reason: 'No.', created_at: '2099-01-01T00:00:00Z', decided_at: '2099-01-02T00:00:00Z', profile: null },
      { id: 'v3', state: 'maybe', created_at: '2099-01-01T00:00:00Z' },
      { id: 'v4', state: 'requested' },
      { state: 'requested', created_at: '2099-01-01T00:00:00Z' },
      'x',
    ]);
    expect(rows.map((r) => r.id)).toEqual(['v1', 'v2']);
    expect(rows[0]).toMatchObject({ state: 'requested', note: 'I am a radio host.', followers: 12, profile: { name: 'Ann Lee', handle: 'ann', category: 'dj' }, decidedAt: null });
    expect(rows[1]).toMatchObject({ reason: 'No.', note: null, decidedAt: '2099-01-02T00:00:00Z', profile: { name: 'A profile that is gone', handle: null } });
    expect(parseVerifications(null)).toEqual([]);
  });

  it('rank reviews: the level, the followers then and now, and whether the profile is still verified', () => {
    const rows = parseReviews([
      { id: 'r1', state: 'pending', level: 'elite', level_name: 'Elite', followers: 100500, followers_now: 101000, verified: true, created_at: '2099-01-01T00:00:00Z', profile: who },
      { id: 'r2', state: 'rejected', level: 'icon', reason: 'Bought followers.', created_at: '2099-01-01T00:00:00Z' },
      { id: 'r3', state: 'later', level: 'icon', created_at: '2099-01-01T00:00:00Z' },
      { id: 'r4', state: 'pending', created_at: '2099-01-01T00:00:00Z' },
    ]);
    expect(rows.map((r) => r.id)).toEqual(['r1', 'r2']);
    expect(rows[0]).toMatchObject({ levelName: 'Elite', followers: 100500, followersNow: 101000, verified: true });
    expect(rows[1]).toMatchObject({ levelName: 'icon', verified: false, reason: 'Bought followers.', followers: 0 });
  });

  it('awards: the rank, when, and who holds it', () => {
    const rows = parseAwards([{ id: 'a1', level: 'elite', level_name: 'Elite', awarded_at: '2099-01-01T00:00:00Z', followers_now: 7, profile: who }, { id: 'a2', level: 'icon' }, { level: 'icon', awarded_at: 'x' }]);
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({ levelName: 'Elite', followersNow: 7, profile: { handle: 'ann' } });
  });

  it('plaques: the address in the order of a parcel, with what is missing left out, and a wiped address says so', () => {
    const rows = parsePlaques([
      { id: 'p1', state: 'requested', level: 'icon', level_name: 'Icon', recipient: 'Ann Lee', line1: '1 King St W', line2: 'Unit 4', city: 'Toronto', region: 'ON', postal: 'M5V 1A1', country: 'Canada', phone: '555', created_at: '2099-01-01T00:00:00Z', profile: who },
      { id: 'p2', state: 'delivered', level: 'icon', address_removed: true, carrier: 'Canada Post', tracking: 'AB1', created_at: '2099-01-01T00:00:00Z' },
      { id: 'p3', state: 'lost', level: 'icon', created_at: '2099-01-01T00:00:00Z' },
    ]);
    expect(rows.map((r) => r.id)).toEqual(['p1', 'p2']);
    expect(rows[0].address).toEqual(['Ann Lee', '1 King St W', 'Unit 4', 'Toronto, ON M5V 1A1', 'Canada']);
    expect(rows[0].phone).toBe('555');
    expect(rows[1]).toMatchObject({ address: [], addressRemoved: true, carrier: 'Canada Post', tracking: 'AB1' });
    expect(addressLines({ recipient: 'A', city: 'T', postal: 'P' })).toEqual(['A', 'T P']);
    expect(addressLines({ recipient: 'A', region: 'ON' })).toEqual(['A', 'ON']);
    expect(addressLines({})).toEqual([]);
  });

  it('levels: in use unless the database says otherwise', () => {
    const rows = parseLevels([{ key: 'elite', name: 'Elite', min_followers: 100000, colour: '#2E9E5B', plaque: false, active: true }, { key: 'icon', name: 'Icon', min_followers: 1000000, colour: '#7E57C2', plaque: true, active: false }, { key: 'x', name: 'X' }, 'y']);
    expect(rows).toHaveLength(2);
    expect(rows[1]).toMatchObject({ plaque: true, active: false, minFollowers: 1000000 });
    expect(parseLevels([{ key: 'elite', name: 'Elite', colour: '#2E9E5B' }])[0]).toMatchObject({ active: true, plaque: false, minFollowers: 0 });
    expect(parseLevels(null)).toEqual([]);
  });

  it('writes a count of followers with commas', () => {
    expect(followersText(1000000)).toBe('1,000,000');
    expect(followersText(950)).toBe('950');
  });
});

describe('checking a level before it is saved', () => {
  const good: LevelForm = { name: 'Elite', minFollowers: '100000', colour: '#2E9E5B', plaque: false, active: true };
  it('accepts a good one and gives the form back from a level', () => {
    expect(levelProblem(good, 'elite')).toBeNull();
    expect(levelForm({ key: 'icon', name: 'Icon', minFollowers: 1000000, colour: '#7E57C2', plaque: true, active: false })).toEqual({ name: 'Icon', minFollowers: '1000000', colour: '#7E57C2', plaque: true, active: false });
  });
  it('wants a name of 2 to 40 characters', () => {
    expect(levelProblem({ ...good, name: ' E ' }, 'elite')).toBe('The name must be 2 to 40 characters.');
    expect(levelProblem({ ...good, name: 'N'.repeat(41) }, 'elite')).toBe('The name must be 2 to 40 characters.');
    expect(levelProblem({ ...good, name: 'N'.repeat(40) }, 'elite')).toBeNull();
    expect(levelProblem({ ...good, name: 'El' }, 'elite')).toBeNull();
  });
  it('wants a real colour', () => {
    expect(levelProblem({ ...good, colour: 'green' }, 'elite')).toBe('The colour looks like #1D9BF0.');
    expect(levelProblem({ ...good, colour: '#12345' }, 'elite')).toBe('The colour looks like #1D9BF0.');
    expect(levelProblem({ ...good, colour: '#abcdef' }, 'elite')).toBeNull();
  });
  it('wants a whole number of followers, one or more', () => {
    for (const bad of ['', '0', '-5', '1.5', 'many', '12345678901']) expect(levelProblem({ ...good, minFollowers: bad }, 'elite')).toBe('The followers needed must be a whole number of 1 or more.');
    expect(levelProblem({ ...good, minFollowers: '1' }, 'elite')).toBeNull();
  });
  it('keeps Verified as it must be', () => {
    const v: LevelForm = { name: 'Verified', minFollowers: '0', colour: '#1D9BF0', plaque: false, active: true };
    expect(levelProblem(v, 'verified')).toBeNull();
    for (const bad of [{ ...v, minFollowers: '5' }, { ...v, active: false }, { ...v, plaque: true }]) expect(levelProblem(bad, 'verified')).toBe('Verified needs no followers, is always in use and has no plaque.');
  });
});

describe('asking the database', () => {
  it('lists with the state asked for', async () => {
    h.call.mockResolvedValue([]);
    await fetchVerifications();
    await fetchVerifications('approved');
    await fetchReviews();
    await fetchReviews('all');
    await fetchPlaques();
    await fetchPlaques('shipped');
    await fetchAwards();
    await fetchLevels();
    expect(h.call.mock.calls).toEqual([
      ['cms_verifications', { p_state: 'requested' }], ['cms_verifications', { p_state: 'approved' }], ['cms_rank_reviews', { p_state: 'pending' }], ['cms_rank_reviews', { p_state: 'all' }],
      ['cms_plaques', { p_state: 'requested' }], ['cms_plaques', { p_state: 'shipped' }], ['cms_awards', { p_limit: 100 }], ['cms_rank_levels'],
    ]);
  });

  it('decides a verification, with a reason only when there is one', async () => {
    h.call.mockResolvedValue({});
    await decideVerification('v1', 'approve', '  ');
    await decideVerification('v2', 'reject', ' We could not confirm who you are. ');
    expect(h.call.mock.calls).toEqual([
      ['cms_verification_decide', { p_id: 'v1', p_decision: 'approve', p_reason: null }],
      ['cms_verification_decide', { p_id: 'v2', p_decision: 'reject', p_reason: 'We could not confirm who you are.' }],
    ]);
  });

  it('decides a rank review the same way', async () => {
    h.call.mockResolvedValue({});
    await decideReview('r1', true, '');
    await decideReview('r2', false, ' Bought followers. ');
    expect(h.call.mock.calls).toEqual([['cms_rank_decide', { p_review: 'r1', p_approve: true, p_reason: null }], ['cms_rank_decide', { p_review: 'r2', p_approve: false, p_reason: 'Bought followers.' }]]);
  });

  it('takes a rank back, ships and delivers a plaque', async () => {
    h.call.mockResolvedValue({});
    await revokeAward('a1', ' Not genuine. ');
    await markShipped('p1', ' Canada Post ', ' AB1 ');
    await markDelivered('p1');
    expect(h.call.mock.calls).toEqual([
      ['cms_award_revoke', { p_award: 'a1', p_reason: 'Not genuine.' }],
      ['cms_plaque_shipped', { p_plaque: 'p1', p_carrier: 'Canada Post', p_tracking: 'AB1' }],
      ['cms_plaque_delivered', { p_plaque: 'p1' }],
    ]);
  });

  it('saves a level, and says what is wrong before asking', async () => {
    h.call.mockResolvedValue({});
    await saveLevel('elite', { name: ' Elite ', minFollowers: '100000', colour: '#2E9E5B', plaque: true, active: true });
    await saveLevel('verified', { name: 'Verified', minFollowers: '0', colour: '#1D9BF0', plaque: false, active: true });
    expect(h.call.mock.calls).toEqual([
      ['cms_rank_level_set', { p_key: 'elite', p_name: 'Elite', p_min_followers: 100000, p_colour: '#2E9E5B', p_plaque: true, p_active: true }],
      ['cms_rank_level_set', { p_key: 'verified', p_name: 'Verified', p_min_followers: 0, p_colour: '#1D9BF0', p_plaque: false, p_active: true }],
    ]);
    h.call.mockClear();
    await expect(saveLevel('elite', { name: 'E', minFollowers: '5', colour: '#2E9E5B', plaque: false, active: true })).rejects.toThrow('The name must be 2 to 40 characters.');
    expect(h.call).not.toHaveBeenCalled();
  });
});
