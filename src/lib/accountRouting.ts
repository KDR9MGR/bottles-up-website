// Where a person goes after signing in (client website brief, section 3). One identity,
// many possible homes: a personal dashboard, a venue-owner or organizer business, a manager
// or staff assignment, the platform admin area, or the older staff pages.
//
//   Personal user                 -> personal dashboard
//   Owner of one venue            -> that venue's dashboard
//   Owner of several venues       -> all-venues overview
//   Event organizer               -> My Events
//   Manager / server / door /     -> their assigned workspace
//   security / verifier
//   Several businesses or roles   -> workspace selector; remember the last one used
//
// Pure functions over a snapshot of the account. The snapshot is what the database says
// right now (active memberships only: revoked or expired access is simply absent), and a
// remembered destination is re-checked against it, so a stale bookmark or a revoked role
// never opens an operational dashboard.

import { landingSection, ROLE_LABEL, workspacePath, isWorkspaceRole, type WorkspaceRole } from './roleNavigation';
import { sanitizeNext } from './safeNext';
import { isVerificationState, type VerificationState } from './verification';

export type BusinessKind = 'venue_owner' | 'organizer';

/** One row of my_workspaces(): an active membership. */
export interface Workspace {
  membershipId: string;
  orgId: string;
  orgName: string;
  orgKind: BusinessKind;
  role: WorkspaceRole;
  venueId: string | null;
  venueName: string | null;
  eventId: string | null;
  eventTitle: string | null;
  shiftId: string | null;
  shiftName: string | null;
  accessEndAt: string | null;
}

/** One row of my_businesses(): a business the person owns or organizes. */
export interface Business {
  orgId: string;
  name: string;
  kind: BusinessKind;
  verificationState: VerificationState;
  requestMessage: string | null;
  missing: string[];
  venueCount: number;
  pendingClaims: number;
}

/** What the person chose on the public site when they created the account. */
export type SignupIntent = { kind: 'personal' } | { kind: 'business'; businessKind: BusinessKind };

/** The older staff table: role 'door_staff' lands on the scanner, every other role on /staff. */
export type LegacyStaffRole = 'door_staff' | 'server' | 'cashier' | 'bartender' | 'manager';

export interface AccountSnapshot {
  signedIn: boolean;
  profileComplete: boolean;
  signupIntent: SignupIntent | null;
  workspaces: Workspace[];
  businesses: Business[];
  isCmsAdmin: boolean;
  legacyStaffRole: LegacyStaffRole | null;
}

export const EMPTY_SNAPSHOT: AccountSnapshot = {
  signedIn: false,
  profileComplete: false,
  signupIntent: null,
  workspaces: [],
  businesses: [],
  isCmsAdmin: false,
  legacyStaffRole: null,
};

// ---------------------------------------------------------------------------
// Reading what the sign-up form stored on the account
// ---------------------------------------------------------------------------

/**
 * `user_metadata` is chosen by the user, so it is treated as untrusted: it only steers which
 * onboarding page is offered first, never what the person may do. Anything unexpected is null.
 */
export function parseSignupIntent(meta: unknown): SignupIntent | null {
  if (!meta || typeof meta !== 'object') return null;
  const m = meta as Record<string, unknown>;
  if (m.signup_intent === 'personal') return { kind: 'personal' };
  if (m.signup_intent === 'business') {
    if (m.business_kind === 'venue_owner' || m.business_kind === 'organizer') {
      return { kind: 'business', businessKind: m.business_kind };
    }
  }
  return null;
}

// ---------------------------------------------------------------------------
// Destinations
// ---------------------------------------------------------------------------

export type DestinationKind = 'personal' | 'workspace' | 'cms' | 'legacy-staff';
export type Attention = 'finish_setup' | 'more_information' | 'under_review';

export interface Destination {
  /** Stable id used to remember the last workspace: the membership id, or a fixed word. */
  key: string;
  kind: DestinationKind;
  title: string;
  subtitle: string;
  path: string;
  /** Set when the business behind this destination needs the person's action. */
  attention: Attention | null;
}

export const PERSONAL_KEY = 'personal';
export const CMS_KEY = 'cms';
export const LEGACY_STAFF_KEY = 'legacy-staff';

export function onboardingPath(orgId: string): string {
  return `/business/${orgId}/onboarding`;
}

function businessFor(snapshot: AccountSnapshot, orgId: string): Business | undefined {
  return snapshot.businesses.find((b) => b.orgId === orgId);
}

/**
 * A business that cannot do anything useful yet. A venue owner with no venue (added or being
 * claimed), or a business that has not been submitted, or one the reviewer sent back, is sent to
 * onboarding. A business under review is NOT: it may keep drafting, so it lands on its dashboard.
 */
export function attentionFor(b: Business | undefined): Attention | null {
  if (!b) return null;
  if (b.verificationState === 'more_information_needed') return 'more_information';
  if (b.verificationState === 'not_submitted') return 'finish_setup';
  if (b.kind === 'venue_owner' && b.venueCount === 0 && b.pendingClaims === 0) return 'finish_setup';
  if (b.verificationState === 'under_review') return 'under_review';
  return null;
}

function scopeTitle(w: Workspace): string {
  switch (w.role) {
    case 'owner':
    case 'organizer':
      return w.orgName;
    case 'manager':
      return w.venueName ?? w.orgName;
    default:
      return w.eventTitle ?? w.venueName ?? w.orgName;
  }
}

function workspaceDestination(snapshot: AccountSnapshot, w: Workspace): Destination {
  const business = w.role === 'owner' || w.role === 'organizer' ? businessFor(snapshot, w.orgId) : undefined;
  const attention = attentionFor(business);
  const needsOnboarding = attention === 'finish_setup' || attention === 'more_information';
  const parts = [ROLE_LABEL[w.role]];
  if (w.role !== 'owner' && w.role !== 'organizer' && w.orgName !== scopeTitle(w)) parts.push(w.orgName);
  if (w.shiftName) parts.push(w.shiftName);
  return {
    key: w.membershipId,
    kind: 'workspace',
    title: scopeTitle(w),
    subtitle: parts.join(' · '),
    path: needsOnboarding ? onboardingPath(w.orgId) : workspacePath(w.membershipId, landingSection(w.role)),
    attention,
  };
}

/** Everything the person can open, personal account first. Each entry is something they hold now. */
export function buildDestinations(snapshot: AccountSnapshot): Destination[] {
  if (!snapshot.signedIn) return [];
  const out: Destination[] = [
    { key: PERSONAL_KEY, kind: 'personal', title: 'Personal account', subtitle: 'Bookings, tickets and profile', path: '/dashboard', attention: null },
  ];
  for (const w of snapshot.workspaces) out.push(workspaceDestination(snapshot, w));
  if (snapshot.isCmsAdmin) {
    out.push({ key: CMS_KEY, kind: 'cms', title: 'Platform admin', subtitle: 'BottlesUp team', path: '/cms', attention: null });
  }
  if (snapshot.legacyStaffRole) {
    out.push({
      key: LEGACY_STAFF_KEY,
      kind: 'legacy-staff',
      title: 'Team staff',
      subtitle: snapshot.legacyStaffRole === 'door_staff' ? 'Door scanner' : 'Server dashboard',
      path: snapshot.legacyStaffRole === 'door_staff' ? '/door/scan' : '/staff/tables',
      attention: null,
    });
  }
  return out;
}

// ---------------------------------------------------------------------------
// May this person be sent to this path?
// ---------------------------------------------------------------------------

const WORKSPACE_PATH = /^\/w\/([^/?#]+)(?:[/?#]|$)/;

/**
 * A remembered or requested destination is honoured only while the person still has access to
 * it. The pages and the database check access again on their own; this keeps a stale link from
 * even being tried, and from bouncing a person through a login for something that is gone.
 */
export function isDestinationPermitted(path: string, snapshot: AccountSnapshot): boolean {
  const ws = WORKSPACE_PATH.exec(path);
  if (ws) return snapshot.workspaces.some((w) => w.membershipId === ws[1]);
  if (path === '/cms' || path.startsWith('/cms/') || path.startsWith('/cms?')) return snapshot.isCmsAdmin;
  if (/^\/(staff|door)(\/|\?|#|$)/.test(path)) {
    return snapshot.legacyStaffRole !== null && !/^\/(staff|door)\/login/.test(path);
  }
  const biz = /^\/business\/([^/?#]+)/.exec(path);
  if (biz) return snapshot.businesses.some((b) => b.orgId === biz[1]) || biz[1] === 'new';
  return true;
}

// ---------------------------------------------------------------------------
// The decision
// ---------------------------------------------------------------------------

export type Landing =
  | { kind: 'signed_out' }
  | { kind: 'redirect'; to: string }
  | { kind: 'select'; destinations: Destination[] };

export interface LandingOptions {
  /** `?next=` from the link the person followed (a venue or event booking link, an invitation). */
  next?: string | null;
  /** Key of the workspace used last time on this device. */
  lastKey?: string | null;
  /** The person pressed "skip" on the profile step this session. */
  profileSkipped?: boolean;
}

export function decideLanding(snapshot: AccountSnapshot, options: LandingOptions = {}): Landing {
  if (!snapshot.signedIn) return { kind: 'signed_out' };

  const destinations = buildDestinations(snapshot);
  const work = destinations.filter((d) => d.kind !== 'personal');

  // 1. The destination they were heading for, if they are still allowed there.
  const next = sanitizeNext(options.next, '');
  if (next && isDestinationPermitted(next, snapshot)) return { kind: 'redirect', to: next };

  const hasWork = work.length > 0;

  // 2. Someone who chose "Create a Business Account" and has not created the business yet
  //    (for example they confirmed their email on another device) resumes where they left off.
  if (!hasWork && snapshot.signupIntent?.kind === 'business') {
    return { kind: 'redirect', to: `/business/new?type=${snapshot.signupIntent.businessKind}` };
  }

  // 3. Profile creation is the first task for a personal account. People who already have a
  //    business or a team role are not held up by it.
  if (!hasWork && !snapshot.profileComplete && !options.profileSkipped) {
    return { kind: 'redirect', to: '/onboarding/profile' };
  }

  // 4. Personal only.
  if (!hasWork) return { kind: 'redirect', to: '/dashboard' };

  // 5. Exactly one place to go.
  if (work.length === 1) return { kind: 'redirect', to: work[0].path };

  // 6. Several: the last one used, if it is still theirs; otherwise ask.
  const last = work.find((d) => d.key === options.lastKey);
  if (last) return { kind: 'redirect', to: last.path };
  return { kind: 'select', destinations };
}

/** Parses one my_workspaces() row, dropping a row whose role this code does not know. */
export function parseWorkspaceRow(row: Record<string, unknown>): Workspace | null {
  if (!isWorkspaceRole(row.role)) return null;
  if (row.org_kind !== 'venue_owner' && row.org_kind !== 'organizer') return null;
  if (typeof row.membership_id !== 'string' || typeof row.org_id !== 'string') return null;
  const str = (v: unknown) => (typeof v === 'string' ? v : null);
  return {
    membershipId: row.membership_id,
    orgId: row.org_id,
    orgName: str(row.org_name) ?? '',
    orgKind: row.org_kind,
    role: row.role,
    venueId: str(row.venue_id),
    venueName: str(row.venue_name),
    eventId: str(row.event_id),
    eventTitle: str(row.event_title),
    shiftId: str(row.shift_id),
    shiftName: str(row.shift_name),
    accessEndAt: str(row.access_end_at),
  };
}

/** Parses one my_businesses() row, dropping one with an unknown kind or state. */
export function parseBusinessRow(row: Record<string, unknown>): Business | null {
  if (row.org_kind !== 'venue_owner' && row.org_kind !== 'organizer') return null;
  if (!isVerificationState(row.verification_state)) return null;
  if (typeof row.org_id !== 'string') return null;
  return {
    orgId: row.org_id,
    name: typeof row.org_name === 'string' ? row.org_name : '',
    kind: row.org_kind,
    verificationState: row.verification_state,
    requestMessage: typeof row.request_message === 'string' ? row.request_message : null,
    missing: Array.isArray(row.missing) ? row.missing.filter((m): m is string => typeof m === 'string') : [],
    venueCount: typeof row.venue_count === 'number' ? row.venue_count : 0,
    pendingClaims: typeof row.pending_claims === 'number' ? row.pending_claims : 0,
  };
}
