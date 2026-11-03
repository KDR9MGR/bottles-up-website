import { call } from './account';

// What BottlesUp staff use to look after verification, ranks, awards and plaques in the customer app: who asked to be verified, who asked for a rank, the ranks that were awarded, the
// plaques to send, and the ranks themselves (their names and the followers they need). Everything here is a call to a database function that checks the caller is a BottlesUp admin
// (20261110100000_recognition_jobs); the page only shows what those functions answer.

export type VerificationState = 'requested' | 'approved' | 'rejected' | 'revoked';
export type ReviewState = 'pending' | 'approved' | 'rejected';
export type PlaqueState = 'requested' | 'shipped' | 'delivered' | 'cancelled';

export interface Person {
  name: string;
  handle: string | null;
  category: string | null;
}

export interface Verification {
  id: string;
  state: VerificationState;
  note: string | null;
  reason: string | null;
  createdAt: string;
  decidedAt: string | null;
  followers: number;
  profile: Person;
}

export interface RankReview {
  id: string;
  state: ReviewState;
  level: string;
  levelName: string;
  followers: number;
  followersNow: number;
  verified: boolean;
  reason: string | null;
  createdAt: string;
  decidedAt: string | null;
  profile: Person;
}

export interface Award {
  id: string;
  level: string;
  levelName: string;
  awardedAt: string;
  followersNow: number;
  profile: Person;
}

export interface Plaque {
  id: string;
  level: string;
  levelName: string;
  state: PlaqueState;
  address: string[];
  phone: string | null;
  addressRemoved: boolean;
  carrier: string | null;
  tracking: string | null;
  createdAt: string;
  profile: Person;
}

export interface RankLevel {
  key: string;
  name: string;
  minFollowers: number;
  colour: string;
  plaque: boolean;
  active: boolean;
}

const str = (v: unknown): string | null => (typeof v === 'string' && v.trim() !== '' ? v : null);
const num = (v: unknown): number => (typeof v === 'number' ? v : Number(v ?? 0) || 0);
const obj = (v: unknown): Record<string, unknown> | null => (typeof v === 'object' && v !== null && !Array.isArray(v) ? (v as Record<string, unknown>) : null);

function person(v: unknown): Person {
  const o = obj(v);
  return { name: str(o?.display_name) ?? 'A profile that is gone', handle: str(o?.handle), category: str(o?.category) };
}

function oneOf<T extends string>(v: unknown, allowed: readonly T[]): T | null {
  return typeof v === 'string' && (allowed as readonly string[]).includes(v) ? (v as T) : null;
}

export function parseVerifications(rows: unknown): Verification[] {
  if (!Array.isArray(rows)) return [];
  const out: Verification[] = [];
  for (const r of rows) {
    const o = obj(r);
    const id = str(o?.id);
    const state = oneOf(o?.state, ['requested', 'approved', 'rejected', 'revoked'] as const);
    const createdAt = str(o?.created_at);
    if (!o || !id || !state || !createdAt) continue;
    out.push({ id, state, note: str(o.note), reason: str(o.reason), createdAt, decidedAt: str(o.decided_at), followers: num(o.followers), profile: person(o.profile) });
  }
  return out;
}

export function parseReviews(rows: unknown): RankReview[] {
  if (!Array.isArray(rows)) return [];
  const out: RankReview[] = [];
  for (const r of rows) {
    const o = obj(r);
    const id = str(o?.id);
    const state = oneOf(o?.state, ['pending', 'approved', 'rejected'] as const);
    const level = str(o?.level);
    const createdAt = str(o?.created_at);
    if (!o || !id || !state || !level || !createdAt) continue;
    out.push({
      id, state, level, levelName: str(o.level_name) ?? level, followers: num(o.followers), followersNow: num(o.followers_now), verified: o.verified === true, reason: str(o.reason), createdAt,
      decidedAt: str(o.decided_at), profile: person(o.profile),
    });
  }
  return out;
}

export function parseAwards(rows: unknown): Award[] {
  if (!Array.isArray(rows)) return [];
  const out: Award[] = [];
  for (const r of rows) {
    const o = obj(r);
    const id = str(o?.id);
    const level = str(o?.level);
    const awardedAt = str(o?.awarded_at);
    if (!o || !id || !level || !awardedAt) continue;
    out.push({ id, level, levelName: str(o.level_name) ?? level, awardedAt, followersNow: num(o.followers_now), profile: person(o.profile) });
  }
  return out;
}

/** The lines to write on a parcel, in order, leaving out what was not given. */
export function addressLines(o: Record<string, unknown>): string[] {
  const place = [str(o.city), str(o.region)].filter(Boolean).join(', ');
  const post = [place, str(o.postal)].filter(Boolean).join(' ');
  return [str(o.recipient), str(o.line1), str(o.line2), post === '' ? null : post, str(o.country)].filter((x): x is string => x !== null);
}

export function parsePlaques(rows: unknown): Plaque[] {
  if (!Array.isArray(rows)) return [];
  const out: Plaque[] = [];
  for (const r of rows) {
    const o = obj(r);
    const id = str(o?.id);
    const state = oneOf(o?.state, ['requested', 'shipped', 'delivered', 'cancelled'] as const);
    const level = str(o?.level);
    const createdAt = str(o?.created_at);
    if (!o || !id || !state || !level || !createdAt) continue;
    out.push({
      id, state, level, levelName: str(o.level_name) ?? level, address: addressLines(o), phone: str(o.phone), addressRemoved: o.address_removed === true, carrier: str(o.carrier), tracking: str(o.tracking), createdAt,
      profile: person(o.profile),
    });
  }
  return out;
}

export function parseLevels(rows: unknown): RankLevel[] {
  if (!Array.isArray(rows)) return [];
  const out: RankLevel[] = [];
  for (const r of rows) {
    const o = obj(r);
    const key = str(o?.key);
    const name = str(o?.name);
    const colour = str(o?.colour);
    if (!o || !key || !name || !colour) continue;
    out.push({ key, name, minFollowers: num(o.min_followers), colour, plaque: o.plaque === true, active: o.active !== false });
  }
  return out;
}

/** "1,000,000" for a count of followers. */
export const followersText = (n: number) => n.toLocaleString('en-CA');

export interface LevelForm {
  name: string;
  minFollowers: string;
  colour: string;
  plaque: boolean;
  active: boolean;
}

export function levelForm(l: RankLevel): LevelForm {
  return { name: l.name, minFollowers: String(l.minFollowers), colour: l.colour, plaque: l.plaque, active: l.active };
}

/** The sentence for what is wrong with this level, or null. The database checks the same things and also that the count sits between its neighbours'. */
export function levelProblem(f: LevelForm, key: string): string | null {
  const name = f.name.trim();
  if (name.length < 2 || name.length > 40) return 'The name must be 2 to 40 characters.';
  if (!/^#[0-9A-Fa-f]{6}$/.test(f.colour.trim())) return 'The colour looks like #1D9BF0.';
  if (key === 'verified') return f.minFollowers.trim() === '0' && f.active && !f.plaque ? null : 'Verified needs no followers, is always in use and has no plaque.';
  if (!/^\d{1,10}$/.test(f.minFollowers.trim()) || Number(f.minFollowers) < 1) return 'The followers needed must be a whole number of 1 or more.';
  return null;
}

export const fetchVerifications = async (state: VerificationState | 'all' = 'requested') => parseVerifications(await call('cms_verifications', { p_state: state }));

export async function decideVerification(id: string, decision: 'approve' | 'reject' | 'revoke', reason: string): Promise<void> {
  await call('cms_verification_decide', { p_id: id, p_decision: decision, p_reason: reason.trim() === '' ? null : reason.trim() });
}

export const fetchReviews = async (state: ReviewState | 'all' = 'pending') => parseReviews(await call('cms_rank_reviews', { p_state: state }));

export async function decideReview(id: string, approve: boolean, reason: string): Promise<void> {
  await call('cms_rank_decide', { p_review: id, p_approve: approve, p_reason: reason.trim() === '' ? null : reason.trim() });
}

export const fetchAwards = async () => parseAwards(await call('cms_awards', { p_limit: 100 }));

export async function revokeAward(id: string, reason: string): Promise<void> {
  await call('cms_award_revoke', { p_award: id, p_reason: reason.trim() });
}

export const fetchPlaques = async (state: PlaqueState | 'all' = 'requested') => parsePlaques(await call('cms_plaques', { p_state: state }));

export async function markShipped(id: string, carrier: string, tracking: string): Promise<void> {
  await call('cms_plaque_shipped', { p_plaque: id, p_carrier: carrier.trim(), p_tracking: tracking.trim() });
}

export async function markDelivered(id: string): Promise<void> {
  await call('cms_plaque_delivered', { p_plaque: id });
}

export const fetchLevels = async () => parseLevels(await call('cms_rank_levels'));

export async function saveLevel(key: string, f: LevelForm): Promise<void> {
  const problem = levelProblem(f, key);
  if (problem) throw new Error(problem);
  await call('cms_rank_level_set', { p_key: key, p_name: f.name.trim(), p_min_followers: key === 'verified' ? 0 : Number(f.minFollowers), p_colour: f.colour.trim(), p_plaque: f.plaque, p_active: f.active });
}
