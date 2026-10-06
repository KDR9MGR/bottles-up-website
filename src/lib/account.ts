// Talks to the account and onboarding functions in the database. Every rule that matters
// (who may do what, verification, ownership) is enforced there; this file only calls them and
// turns the results into types the screens use.
//
// The snapshot is built defensively. The live site must keep working for everyone if the newer
// database functions are not deployed yet, so a missing function or column yields an empty
// answer for that part (for example "no workspaces"), never a failed page load.

import type { Session } from '@supabase/supabase-js';
import { supabase } from '@/lib/supabase';
import {
  EMPTY_SNAPSHOT,
  parseBusinessRow,
  parseSignupIntent,
  parseWorkspaceRow,
  type AccountSnapshot,
  type Business,
  type BusinessKind,
  type LegacyStaffRole,
} from '@/lib/accountRouting';
import type { SetupStep } from '@/lib/venueSetup';
import {
  emptyOutcome, normalizeScan, outcomeFromErrorMessage, parseDoorEvent, parseGuest, parseScanOutcome,
  type DoorEvent, type Guest, type ScanOutcome,
} from '@/lib/doorScan';
import {
  parseShift, parseTeamInvitation, parseTeamMember,
  type EmailOutcome, type InvitePayload, type Shift, type TeamInvitation, type TeamMember,
} from '@/lib/team';

// The generated Database type lags the schema (see tests/README.md), and these calls return
// shapes this file validates itself. A narrow, local view of the client keeps the rest of the
// code typed without pretending the generated types know the new functions.
interface RpcResult {
  data: unknown;
  error: { message: string; code?: string; details?: string | null } | null;
}
interface LooseClient {
  rpc: (fn: string, args?: Record<string, unknown>) => PromiseLike<RpcResult>;
  from: (table: string) => {
    select: (cols: string) => {
      eq: (col: string, val: string) => {
        maybeSingle: () => PromiseLike<RpcResult>;
      };
    };
  };
}
const db = supabase as unknown as LooseClient;

export class AccountError extends Error {
  readonly detail: string | null;
  constructor(message: string, detail: string | null = null) {
    super(message);
    this.name = 'AccountError';
    this.detail = detail;
  }
}

async function call<T = unknown>(fn: string, args?: Record<string, unknown>): Promise<T> {
  const { data, error } = await db.rpc(fn, args);
  if (error) throw new AccountError(friendlyMessage(error.message), error.details ?? null);
  return data as T;
}

// ---------------------------------------------------------------------------
// Messages
// ---------------------------------------------------------------------------

export const ACCESS_ENDED_MESSAGE = 'Your access has ended, or you are signed out.';

const FRIENDLY: [RegExp, string][] = [
  [/username is not available/i, 'That username is taken or not allowed. Try another.'],
  [/not authenticated/i, 'Please sign in to continue.'],
  [/not authori[sz]ed/i, ACCESS_ENDED_MESSAGE],
  [/not allowed|permission denied/i, "You don't have access to do that."],
  [/already under review/i, 'This business is already under review.'],
  [/already verified/i, 'This business is already verified.'],
  [/details are locked/i, 'These details cannot be changed while the business is under review or verified.'],
  [/incomplete/i, 'Some required details are still missing.'],
  [/already have a pending request/i, 'You already asked to claim this venue. We will review it soon.'],
  [/already belongs to your business/i, 'This venue already belongs to your business.'],
  [/venue not found/i, 'We could not find that venue.'],
];

/** Database errors are written for developers; people get a plain sentence. Unknown ones pass through. */
export function friendlyMessage(raw: string): string {
  for (const [pattern, message] of FRIENDLY) if (pattern.test(raw)) return message;
  return raw;
}

// ---------------------------------------------------------------------------
// The snapshot: who is this person, and what can they open
// ---------------------------------------------------------------------------

async function safeRows(fn: string): Promise<Record<string, unknown>[]> {
  try {
    const { data, error } = await db.rpc(fn);
    if (error || !Array.isArray(data)) return [];
    return data as Record<string, unknown>[];
  } catch {
    return [];
  }
}

async function safeSingle(table: string, cols: string, id: string): Promise<Record<string, unknown> | null> {
  try {
    const { data, error } = await db.from(table).select(cols).eq('id', id).maybeSingle();
    if (error || !data || typeof data !== 'object') return null;
    return data as Record<string, unknown>;
  } catch {
    return null;
  }
}

export async function fetchAccountSnapshot(session: Session | null): Promise<AccountSnapshot> {
  if (!session) return EMPTY_SNAPSHOT;
  const uid = session.user.id;

  const [workspaceRows, businessRows, profile, admin, staff] = await Promise.all([
    safeRows('my_workspaces'),
    safeRows('my_businesses'),
    safeSingle('profiles', 'id, profile_completed_at', uid),
    safeSingle('cms_admins', 'id', uid),
    safeSingle('door_staff', 'role', uid),
  ]);

  const workspaces = workspaceRows.map(parseWorkspaceRow).filter((w): w is NonNullable<typeof w> => w !== null);
  const businesses = businessRows.map(parseBusinessRow).filter((b): b is Business => b !== null);

  // If the profile columns are not deployed yet the query above returns null; do not nag
  // everyone to "complete" a profile they have no way to complete.
  const profileColumnsExist = profile !== null && 'profile_completed_at' in profile;
  const profileComplete = profileColumnsExist ? profile.profile_completed_at != null : true;

  const role = staff && typeof staff.role === 'string' ? (staff.role as LegacyStaffRole) : staff ? 'server' : null;

  return {
    signedIn: true,
    profileComplete,
    signupIntent: parseSignupIntent(session.user.user_metadata),
    workspaces,
    businesses,
    isCmsAdmin: admin !== null,
    legacyStaffRole: role,
  };
}

// ---------------------------------------------------------------------------
// Personal profile
// ---------------------------------------------------------------------------

export interface ProfileInput {
  name: string;
  username: string;
  city: string;
  bio: string;
  social: Record<string, string>;
}

export async function usernameAvailable(username: string): Promise<boolean> {
  return (await call<boolean>('username_available', { p_username: username })) === true;
}

export async function saveMyProfile(input: ProfileInput): Promise<void> {
  await call('save_my_profile', {
    p_name: input.name,
    p_username: input.username,
    p_city: input.city,
    p_bio: input.bio || null,
    p_social: input.social,
  });
}

export interface MyProfile {
  name: string | null;
  username: string | null;
  city: string | null;
  bio: string | null;
  social_links: Record<string, string>;
  avatar_url: string | null;
}

/** The signed-in person's own profile, to pre-fill "Complete Your Profile". Null if there is none yet. */
export async function fetchMyProfile(userId: string): Promise<MyProfile | null> {
  const { data, error } = await db
    .from('profiles')
    .select('name, username, city, bio, social_links, avatar_url')
    .eq('id', userId)
    .maybeSingle();
  // Before the migration is deployed the new columns do not exist; behave as "no profile yet".
  if (error) return null;
  return (data as MyProfile | null) ?? null;
}

// ---------------------------------------------------------------------------
// Business
// ---------------------------------------------------------------------------

export async function createOrganization(name: string, kind: BusinessKind): Promise<string> {
  return call<string>('create_organization', { p_name: name, p_kind: kind });
}

export interface BusinessDetails {
  legal_name: string | null;
  description: string | null;
  logo_url: string | null;
  representative_name: string | null;
  representative_role: string | null;
  representative_phone: string | null;
  contact_email: string | null;
  contact_phone: string | null;
  address: string | null;
  city: string | null;
  website: string | null;
  social_links: Record<string, string>;
  representative_confirmed_at: string | null;
}

const DETAIL_COLUMNS =
  'legal_name, description, logo_url, representative_name, representative_role, representative_phone, ' +
  'contact_email, contact_phone, address, city, website, social_links, representative_confirmed_at';

export async function fetchBusinessDetails(orgId: string): Promise<BusinessDetails | null> {
  const { data, error } = await db.from('site_business_profiles').select(DETAIL_COLUMNS).eq('org_id', orgId).maybeSingle();
  if (error) throw new AccountError(friendlyMessage(error.message));
  return (data as BusinessDetails | null) ?? null;
}

export async function saveBusinessDetails(orgId: string, details: Record<string, unknown>): Promise<void> {
  await call('save_business_details', { p_org: orgId, p_details: details });
}

export async function submitVerification(orgId: string): Promise<void> {
  await call('submit_verification', { p_org: orgId });
}

export interface VerificationEvent {
  from_state: string;
  to_state: string;
  message: string | null;
  created_at: string;
}

export async function fetchBusiness(orgId: string): Promise<Business | null> {
  const rows = await safeRows('my_businesses');
  const found = rows.map(parseBusinessRow).find((b): b is Business => b !== null && b.orgId === orgId);
  return found ?? null;
}

// ---------------------------------------------------------------------------
// Venues: find, claim, create, set up
// ---------------------------------------------------------------------------

export interface VenueMatch {
  venueId: string;
  name: string;
  address: string | null;
  isClaimed: boolean;
  claimedByYou: boolean;
}

export async function searchVenues(query: string): Promise<VenueMatch[]> {
  const rows = await call<Record<string, unknown>[] | null>('search_venues', { p_query: query });
  return (rows ?? []).map((r) => ({
    venueId: String(r.venue_id),
    name: String(r.name ?? ''),
    address: typeof r.address === 'string' ? r.address : null,
    isClaimed: r.is_claimed === true,
    claimedByYou: r.claimed_by_you === true,
  }));
}

export async function requestVenueClaim(orgId: string, venueId: string, message: string): Promise<void> {
  await call('request_venue_claim', { p_org: orgId, p_venue: venueId, p_message: message || null });
}

export interface VenueClaim {
  claimId: string;
  venueId: string;
  venueName: string;
  status: 'pending' | 'approved' | 'rejected';
  reviewNote: string | null;
  createdAt: string;
}

export async function listVenueClaims(orgId: string): Promise<VenueClaim[]> {
  const rows = await call<Record<string, unknown>[] | null>('list_venue_claims', { p_org: orgId });
  return (rows ?? []).map((r) => ({
    claimId: String(r.claim_id),
    venueId: String(r.venue_id),
    venueName: String(r.venue_name ?? ''),
    status: r.status === 'approved' || r.status === 'rejected' ? r.status : 'pending',
    reviewNote: typeof r.review_note === 'string' ? r.review_note : null,
    createdAt: String(r.created_at ?? ''),
  }));
}

export async function createOrgVenue(orgId: string, name: string): Promise<string> {
  return call<string>('create_org_venue', { p_org: orgId, p_name: name });
}

export interface OrgVenue {
  id: string;
  name: string;
  address: string | null;
  description: string | null;
  cover_image_url: string | null;
  status: string;
}

/** The venues of a business, from the permission-checked list the database gives this person. */
export async function fetchOrgVenues(orgId: string): Promise<{ venueId: string; name: string; status: string }[]> {
  const rows = await call<Record<string, unknown>[] | null>('my_venues');
  return (rows ?? [])
    .filter((r) => r.org_id === orgId)
    .map((r) => ({ venueId: String(r.venue_id), name: String(r.name ?? r.venue_name ?? ''), status: String(r.status ?? 'draft') }));
}

export async function updateVenueProfile(venueId: string, details: Record<string, unknown>): Promise<void> {
  await call('update_venue_profile', { p_venue: venueId, p_details: details });
}

export async function venueSetupStatus(venueId: string): Promise<SetupStep[]> {
  const rows = await call<Record<string, unknown>[] | null>('venue_setup_status', { p_venue: venueId });
  return (rows ?? []).map((r) => ({
    step: String(r.step),
    status: r.status === 'done' || r.status === 'todo' || r.status === 'unavailable' ? r.status : 'todo',
    required: r.required === true,
    detail: typeof r.detail === 'string' ? r.detail : null,
  }));
}

// ---------------------------------------------------------------------------
// Invitations
// ---------------------------------------------------------------------------

export type InviteOutcome = 'ok' | 'already_accepted' | 'invalid' | 'revoked' | 'expired' | 'email_mismatch';

export interface InviteResult {
  outcome: InviteOutcome;
  membershipId: string | null;
  orgId: string | null;
}

const OUTCOMES: readonly string[] = ['ok', 'already_accepted', 'invalid', 'revoked', 'expired', 'email_mismatch'];

export async function acceptInvitation(token: string): Promise<InviteResult> {
  const rows = await call<Record<string, unknown>[] | null>('accept_invitation', { p_token: token });
  const row = rows?.[0];
  const outcome = row && typeof row.outcome === 'string' && OUTCOMES.includes(row.outcome) ? (row.outcome as InviteOutcome) : 'invalid';
  return {
    outcome,
    membershipId: typeof row?.joined_membership_id === 'string' ? row.joined_membership_id : null,
    orgId: typeof row?.joined_org_id === 'string' ? row.joined_org_id : null,
  };
}

// ---------------------------------------------------------------------------
// Admin review (CMS)
// ---------------------------------------------------------------------------

export async function reviewVerification(orgId: string, decision: 'verify' | 'request_info', message: string): Promise<void> {
  await call('review_verification', { p_org: orgId, p_decision: decision, p_message: message || null });
}

export async function reviewVenueClaim(claimId: string, approve: boolean, note: string): Promise<void> {
  await call('review_venue_claim', { p_claim: claimId, p_approve: approve, p_note: note || null });
}

export interface QueuedBusiness {
  orgId: string;
  orgName: string;
  orgKind: BusinessKind;
  submittedAt: string | null;
  submissionCount: number;
  legalName: string | null;
  representativeName: string | null;
  representativePhone: string | null;
  contactEmail: string | null;
  address: string | null;
  city: string | null;
  website: string | null;
  description: string | null;
  ownerEmail: string | null;
  venueCount: number;
}

const text = (v: unknown): string | null => (typeof v === 'string' && v !== '' ? v : null);

export async function fetchVerificationQueue(): Promise<QueuedBusiness[]> {
  const rows = await call<Record<string, unknown>[] | null>('admin_verification_queue');
  return (rows ?? []).map((r) => ({
    orgId: String(r.org_id),
    orgName: String(r.org_name ?? ''),
    orgKind: r.org_kind === 'organizer' ? 'organizer' : 'venue_owner',
    submittedAt: text(r.submitted_at),
    submissionCount: typeof r.submission_count === 'number' ? r.submission_count : 0,
    legalName: text(r.legal_name),
    representativeName: text(r.representative_name),
    representativePhone: text(r.representative_phone),
    contactEmail: text(r.contact_email),
    address: text(r.address),
    city: text(r.city),
    website: text(r.website),
    description: text(r.description),
    ownerEmail: text(r.owner_email),
    venueCount: typeof r.venue_count === 'number' ? r.venue_count : 0,
  }));
}

export interface QueuedClaim {
  claimId: string;
  orgId: string;
  orgName: string;
  venueId: string;
  venueName: string;
  venueAddress: string | null;
  currentOwnerName: string | null;
  message: string | null;
  createdAt: string;
}

export async function fetchClaimQueue(): Promise<QueuedClaim[]> {
  const rows = await call<Record<string, unknown>[] | null>('admin_venue_claims');
  return (rows ?? []).map((r) => ({
    claimId: String(r.claim_id),
    orgId: String(r.org_id),
    orgName: String(r.org_name ?? ''),
    venueId: String(r.venue_id),
    venueName: String(r.venue_name ?? ''),
    venueAddress: text(r.venue_address),
    currentOwnerName: text(r.current_owner_name),
    message: text(r.message),
    createdAt: String(r.created_at ?? ''),
  }));
}

// ---------------------------------------------------------------------------
// Team and invitations
// ---------------------------------------------------------------------------

export async function listTeam(orgId: string): Promise<TeamMember[]> {
  const rows = await call<Record<string, unknown>[] | null>('list_team', { p_org: orgId });
  return (rows ?? []).map(parseTeamMember).filter((m): m is TeamMember => m !== null);
}

export async function listTeamInvitations(orgId: string): Promise<TeamInvitation[]> {
  const rows = await call<Record<string, unknown>[] | null>('list_team_invitations', { p_org: orgId });
  return (rows ?? []).map(parseTeamInvitation).filter((i): i is TeamInvitation => i !== null);
}

export async function listShifts(venueId: string): Promise<Shift[]> {
  const rows = await call<Record<string, unknown>[] | null>('list_shifts', { p_venue: venueId });
  return (rows ?? []).map(parseShift).filter((x): x is Shift => x !== null);
}

/** The roles this person may appoint at this club, as decided by the database. */
export async function invitableRoles(orgId: string, venueId: string): Promise<string[]> {
  const rows = await call<string[] | null>('invitable_roles', { p_org: orgId, p_venue: venueId });
  return rows ?? [];
}

export interface IssuedLink {
  invitationId: string;
  /** The link token. It exists only now: the database keeps a hash, so it cannot be shown again. */
  token: string;
}

export async function inviteMember(orgId: string, p: InvitePayload): Promise<IssuedLink> {
  const rows = await call<Record<string, unknown>[] | null>('invite_member', {
    p_org: orgId,
    p_email: p.email,
    p_role: p.role,
    p_venue: p.venueId,
    p_event: null,
    p_shift: p.shiftId,
    p_access_start: p.accessStartAt,
    p_access_end: p.accessEndAt,
  });
  const row = rows?.[0];
  if (!row || typeof row.invitation_id !== 'string' || typeof row.token !== 'string') throw new AccountError('Could not create the invitation.');
  return { invitationId: row.invitation_id, token: row.token };
}

/** A new link for an invitation that is waiting or has expired. The old link stops working. */
export async function sendNewLink(invitationId: string): Promise<IssuedLink> {
  const rows = await call<Record<string, unknown>[] | null>('resend_invitation', { p_invitation: invitationId });
  const row = rows?.[0];
  if (!row || typeof row.token !== 'string') throw new AccountError('Could not create a new link.');
  return { invitationId, token: row.token };
}

export async function cancelInvitation(invitationId: string): Promise<void> {
  await call('revoke_invitation', { p_invitation: invitationId });
}

export async function removeMember(membershipId: string): Promise<void> {
  await call('revoke_membership', { p_membership: membershipId });
}

export async function createShift(venueId: string, name: string, startsAtIso: string, endsAtIso: string): Promise<string> {
  return call<string>('create_shift', { p_venue: venueId, p_name: name, p_starts: startsAtIso, p_ends: endsAtIso });
}

/**
 * Emails the link to the address on the invitation. Never throws: the invitation already exists, and the screen
 * shows the link either way, so the only question is what to say about the email.
 */
export async function emailInvitation(invitationId: string, token: string): Promise<EmailOutcome> {
  try {
    const { data, error } = await supabase.functions.invoke('send-team-invitation', {
      method: 'POST',
      body: { invitation_id: invitationId, token },
    });
    if (error) {
      const status = (error as { context?: { status?: number } }).context?.status;
      return { sent: false, reason: status === 429 ? 'rate_limited' : 'send_failed' };
    }
    const result = data as { sent?: boolean; reason?: string } | null;
    return result?.sent === true ? { sent: true } : { sent: false, reason: result?.reason ?? 'send_failed' };
  } catch {
    return { sent: false, reason: 'send_failed' };
  }
}

// ---------------------------------------------------------------------------
// Door scanner
// ---------------------------------------------------------------------------

/** The events one door workspace can work now, with how many guests are in. */
export async function doorEvents(membershipId: string): Promise<DoorEvent[]> {
  const rows = await call<Record<string, unknown>[] | null>('door_events', { p_membership: membershipId });
  return (rows ?? []).map(parseDoorEvent).filter((e): e is DoorEvent => e !== null);
}

/**
 * Admits a ticket for the selected event. Never throws: a scan must always end in something the person at the door
 * can act on, so a failure becomes an outcome ("your access has ended", "scan failed") instead of a stuck screen.
 */
export async function doorScan(ticketCode: string, eventId: string): Promise<ScanOutcome> {
  try {
    const rows = await call<Record<string, unknown>[] | null>('door_scan_ticket', { p_ticket_code: normalizeScan(ticketCode), p_event: eventId });
    return parseScanOutcome(rows?.[0]);
  } catch (err) {
    return emptyOutcome(outcomeFromErrorMessage(err instanceof Error ? err.message : ''));
  }
}

/** The entry code for a non-transferable ticket. Same promise as doorScan: it never throws. */
export async function doorVerifyCode(ticketCode: string, code: string, eventId: string): Promise<ScanOutcome> {
  try {
    const rows = await call<Record<string, unknown>[] | null>('door_verify_ticket_code', {
      p_ticket_code: normalizeScan(ticketCode),
      p_code: code.trim(),
      p_event: eventId,
    });
    return parseScanOutcome(rows?.[0]);
  } catch (err) {
    return emptyOutcome(outcomeFromErrorMessage(err instanceof Error ? err.message : ''));
  }
}

/** Paid guests of the event matching a name or ticket code (at least two characters; the database caps it at 50). */
export async function doorGuests(eventId: string, query: string): Promise<Guest[]> {
  const rows = await call<Record<string, unknown>[] | null>('door_guests', { p_event: eventId, p_query: query });
  return (rows ?? []).map(parseGuest).filter((g): g is Guest => g !== null);
}
