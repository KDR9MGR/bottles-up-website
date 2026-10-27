import { call } from './account';

// What BottlesUp staff use to look after the social part of the customer app: the reports people send, suspending a person, the on/off switches, the community rules and the
// banned words. Everything here is a call to a database function that checks the caller is a BottlesUp admin (20261101100000, 20261102100000, 20261105100000); the page only
// shows what those functions answer.

export type ReportKind = 'post' | 'comment' | 'profile' | 'message' | 'review';
export type ReportStatus = 'open' | 'actioned' | 'dismissed';
export type ReportAction = 'dismiss' | 'remove' | 'suspend' | 'restore';
export type ReportState = 'active' | 'removed' | 'suspended' | 'gone';

export const KIND_LABELS: Record<ReportKind, string> = {
  post: 'Post or story',
  comment: 'Comment',
  profile: 'Profile',
  message: 'Message',
  review: 'Review',
};

export const REASON_LABELS: Record<string, string> = {
  spam: 'Spam',
  harassment: 'Harassment or bullying',
  hate: 'Hate speech',
  sexual: 'Nudity or sexual content',
  violence: 'Violence or threats',
  scam: 'Scam or fraud',
  impersonation: 'Pretending to be someone else',
  self_harm: 'Self-harm',
  other: 'Something else',
};

export const ACTION_LABELS: Record<ReportAction, string> = {
  dismiss: 'Dismiss',
  remove: 'Remove it',
  suspend: 'Suspend the person',
  restore: 'Restore',
};

export const STATE_LABELS: Record<ReportState, string> = {
  active: 'Visible',
  removed: 'Removed',
  suspended: 'Suspended',
  gone: 'Deleted',
};

export interface ReportedProfile {
  id: string;
  handle: string | null;
  displayName: string | null;
  status: string | null;
}

export interface ReportGroup {
  kind: ReportKind;
  target: string;
  status: ReportStatus;
  action: string | null;
  note: string | null;
  handledAt: string | null;
  reports: number;
  reporters: number;
  reasons: string[];
  details: string[];
  excerpt: string | null;
  firstAt: string;
  lastAt: string;
  profile: ReportedProfile | null;
  state: ReportState;
}

const KINDS: ReportKind[] = ['post', 'comment', 'profile', 'message', 'review'];
const STATUSES: ReportStatus[] = ['open', 'actioned', 'dismissed'];
const STATES: ReportState[] = ['active', 'removed', 'suspended', 'gone'];
const str = (v: unknown): string | null => (typeof v === 'string' && v !== '' ? v : null);
const num = (v: unknown): number => (typeof v === 'number' ? v : Number(v ?? 0) || 0);

/** Reads the queue the database answers; a row that cannot be read is left out rather than shown wrong. */
export function parseReportGroups(rows: unknown): ReportGroup[] {
  if (!Array.isArray(rows)) return [];
  const out: ReportGroup[] = [];
  for (const r of rows) {
    if (typeof r !== 'object' || r === null) continue;
    const o = r as Record<string, unknown>;
    const kind = KINDS.find((k) => k === o.kind);
    const status = STATUSES.find((s) => s === o.status);
    const target = str(o.target);
    const firstAt = str(o.first_at);
    if (!kind || !status || !target || !firstAt) continue;
    const p = o.profile;
    const profile = typeof p === 'object' && p !== null && str((p as Record<string, unknown>).id)
      ? {
        id: String((p as Record<string, unknown>).id),
        handle: str((p as Record<string, unknown>).handle),
        displayName: str((p as Record<string, unknown>).display_name),
        status: str((p as Record<string, unknown>).status),
      }
      : null;
    out.push({
      kind,
      target,
      status,
      action: str(o.action),
      note: str(o.note),
      handledAt: str(o.handled_at),
      reports: num(o.reports),
      reporters: num(o.reporters),
      reasons: Array.isArray(o.reasons) ? o.reasons.filter((x): x is string => typeof x === 'string') : [],
      details: Array.isArray(o.details) ? o.details.filter((x): x is string => typeof x === 'string') : [],
      excerpt: str(o.excerpt),
      firstAt,
      lastAt: str(o.last_at) ?? firstAt,
      profile,
      state: STATES.find((s) => s === o.state) ?? 'active',
    });
  }
  return out;
}

/** "Spam, Scam or fraud" for the reasons given. A reason this page does not know is shown as it came. */
export function reasonText(reasons: string[]): string {
  return reasons.map((r) => REASON_LABELS[r] ?? r).join(', ');
}

/** "Jane Doe (@jane)", or whichever of the two there is. */
export function profileName(p: ReportedProfile | null): string {
  if (!p) return 'Account deleted';
  if (p.displayName && p.handle) return `${p.displayName} (@${p.handle})`;
  return p.displayName ?? (p.handle ? `@${p.handle}` : 'Unnamed profile');
}

/**
 * What a moderator may do with a group. An open one can be dismissed, its content removed (not a profile) or its person suspended (not if no profile is left); something already
 * removed or suspended can be restored. A decided group offers only a restore, and only while there is something to restore.
 */
export function actionsFor(g: ReportGroup): ReportAction[] {
  if (g.status === 'open') {
    const actions: ReportAction[] = ['dismiss'];
    if (g.kind !== 'profile' && g.state === 'active') actions.push('remove');
    if (g.profile !== null && g.profile.status !== 'suspended') actions.push('suspend');
    if (g.state === 'removed' || g.state === 'suspended') actions.push('restore');
    return actions;
  }
  return g.state === 'removed' || g.state === 'suspended' || g.profile?.status === 'suspended' ? ['restore'] : [];
}

/** The sentence under a decision button, so nobody clicks without knowing what it does. */
export function actionHelp(a: ReportAction, g: ReportGroup): string {
  switch (a) {
    case 'dismiss':
      return 'Nothing is wrong. The reports are closed and the content stays.';
    case 'remove':
      return g.kind === 'message' ? 'The message disappears for both people.' : 'It disappears for everyone, including the person who wrote it.';
    case 'suspend':
      return 'Every profile this person owns is hidden and cannot be used. Their tickets and bookings are not affected.';
    case 'restore':
      return 'Brings back what was removed and every profile that was suspended.';
  }
}

export async function fetchReports(status: ReportStatus | 'all' = 'open', limit = 50, offset = 0): Promise<ReportGroup[]> {
  return parseReportGroups(await call('cms_reports_list', { p_status: status, p_limit: limit, p_offset: offset }));
}

export async function resolveReport(kind: ReportKind, target: string, action: ReportAction, note: string): Promise<number> {
  const r = await call<{ handled?: number } | null>('cms_report_resolve', { p_kind: kind, p_target: target, p_action: action, p_note: note.trim() === '' ? null : note.trim() });
  return num(r?.handled);
}

export interface FoundProfile {
  id: string;
  kind: string;
  handle: string | null;
  displayName: string | null;
  category: string | null;
  status: string;
}

export async function findProfiles(query: string): Promise<FoundProfile[]> {
  const rows = await call<unknown>('cms_find_profiles', { p_query: query });
  if (!Array.isArray(rows)) return [];
  return rows.flatMap((r): FoundProfile[] => {
    const o = r as Record<string, unknown>;
    const id = str(o?.id);
    return id ? [{ id, kind: str(o.kind) ?? 'personal', handle: str(o.handle), displayName: str(o.display_name), category: str(o.category), status: str(o.status) ?? 'active' }] : [];
  });
}

export async function setProfileSuspended(profile: string, suspended: boolean, note: string): Promise<number> {
  const r = await call<{ profiles?: number } | null>('cms_profile_set_status', { p_profile: profile, p_suspended: suspended, p_note: note.trim() === '' ? null : note.trim() });
  return num(r?.profiles);
}

// ---------------------------------------------------------------------------
// Switches, rules and banned words
// ---------------------------------------------------------------------------
export interface FeatureSwitch {
  key: string;
  enabled: boolean;
  note: string | null;
  updatedAt: string | null;
}

export async function fetchFeatures(): Promise<FeatureSwitch[]> {
  const rows = await call<unknown>('cms_list_features');
  if (!Array.isArray(rows)) return [];
  return rows.flatMap((r): FeatureSwitch[] => {
    const o = r as Record<string, unknown>;
    const key = str(o?.key);
    return key ? [{ key, enabled: o.enabled === true, note: str(o.note), updatedAt: str(o.updated_at) }] : [];
  });
}

export async function setFeature(key: string, enabled: boolean): Promise<void> {
  await call('cms_set_feature', { p_key: key, p_enabled: enabled });
}

export interface CommunityRules {
  version: number;
  body: string | null;
}

export async function fetchRules(): Promise<CommunityRules> {
  const r = await call<Record<string, unknown> | null>('rules_current');
  return { version: num(r?.version) || 1, body: str(r?.body) };
}

/** Rules are 20 to 8000 characters once trimmed (the database says the same). Answers the sentence to show, or null when fine. */
export function rulesProblem(body: string): string | null {
  const n = body.trim().length;
  if (n < 20) return 'Write at least 20 characters.';
  if (n > 8000) return 'The rules can be 8000 characters at most.';
  return null;
}

export async function publishRules(body: string): Promise<CommunityRules> {
  const r = await call<Record<string, unknown> | null>('cms_publish_rules', { p_body: body });
  return { version: num(r?.version) || 1, body: str(r?.body) };
}

export async function fetchBannedTerms(): Promise<string[]> {
  const rows = await call<unknown>('cms_list_banned_terms');
  return Array.isArray(rows) ? rows.flatMap((r) => (typeof (r as Record<string, unknown>)?.term === 'string' ? [String((r as Record<string, unknown>).term)] : [])) : [];
}

/** A banned term is 2 to 40 letters, numbers or spaces. Answers the cleaned term, or null when it is not one. */
export function cleanBannedTerm(raw: string): string | null {
  const t = raw.trim().toLowerCase().replace(/\s+/g, ' ');
  return /^[a-z0-9 ]{2,40}$/.test(t) ? t : null;
}

export async function setBannedTerm(term: string, banned: boolean): Promise<void> {
  await call('cms_set_banned_term', { p_term: term, p_banned: banned });
}
