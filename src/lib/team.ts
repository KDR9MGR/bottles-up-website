// The rules behind the Team screen (client brief, section 12 and website brief section 3): inviting people,
// temporary access, and what each state of a person or an invitation means. Pure functions, so they are tested
// without a browser. Who may invite whom is decided by the database (invitable_roles); nothing here grants anything.

import { isValidEmail } from './password';

// ---------------------------------------------------------------------------
// Inviting
// ---------------------------------------------------------------------------

export interface InviteForm {
  email: string;
  role: string;
  venueId: string;
  /** Temporary access has a start and an end; otherwise it lasts until the person is removed. */
  temporary: boolean;
  /** `datetime-local` values (the person's own clock), e.g. "2026-10-10T21:00". */
  start: string;
  end: string;
  shiftId: string;
}

export interface InvitePayload {
  email: string;
  role: string;
  venueId: string;
  shiftId: string | null;
  accessStartAt: string | null;
  accessEndAt: string | null;
}

/** A `datetime-local` value as an instant, or null if it is empty or not a real date and time. */
export function localInputToIso(value: string): string | null {
  if (!value) return null;
  const d = new Date(value);
  return Number.isNaN(d.getTime()) ? null : d.toISOString();
}

/** Plain-language problems with the form; an empty list means it can be sent. */
export function validateInvite(form: InviteForm, now: Date = new Date()): string[] {
  const problems: string[] = [];
  if (!isValidEmail(form.email)) problems.push('Enter the email address of the person you are inviting.');
  if (!form.venueId) problems.push('Choose the club they will work at.');
  if (!form.role) problems.push('Choose a role.');
  if (form.temporary) {
    const start = localInputToIso(form.start);
    const end = localInputToIso(form.end);
    if (!start || !end) {
      problems.push('Temporary access needs a start and an end.');
    } else if (new Date(end) <= new Date(start)) {
      problems.push('The end must be after the start.');
    } else if (new Date(end) <= now) {
      problems.push('The end is already in the past.');
    }
  }
  return problems;
}

export function buildInvitePayload(form: InviteForm): InvitePayload {
  return {
    email: form.email.trim().toLowerCase(),
    role: form.role,
    venueId: form.venueId,
    shiftId: form.shiftId || null,
    accessStartAt: form.temporary ? localInputToIso(form.start) : null,
    accessEndAt: form.temporary ? localInputToIso(form.end) : null,
  };
}

// ---------------------------------------------------------------------------
// The link and how to send it
// ---------------------------------------------------------------------------

export function invitationLink(origin: string, token: string): string {
  return `${origin.replace(/\/+$/, '')}/accept-invite?token=${encodeURIComponent(token)}`;
}

/**
 * A `mailto:` link, for when the server could not send the email. It opens the person's own mail app with the
 * message ready, so an invitation is never stuck just because outgoing mail is not configured.
 */
export function mailtoLink(to: string, businessName: string, roleName: string, link: string): string {
  // Names are typed by users: collapse any line break so a name cannot add a mail header once decoded.
  const business = businessName.replace(/\s+/g, ' ').trim();
  const role = roleName.replace(/\s+/g, ' ').trim();
  const subject = `You are invited to join ${business} on BottlesUp`;
  const body = `You have been invited to join ${business} on BottlesUp as ${role}.\n\nAccept the invitation here:\n${link}\n\nSign in or create an account with ${to} to accept.`;
  return `mailto:${encodeURIComponent(to)}?subject=${encodeURIComponent(subject)}&body=${encodeURIComponent(body)}`;
}

/** `reason` says why a send failed. (A plain shape, not a union: this project does not compile in strict mode.) */
export interface EmailOutcome {
  sent: boolean;
  reason?: string;
}

/** What to tell the person after trying to email the link. The link itself is always shown as well. */
export function emailOutcomeMessage(outcome: EmailOutcome, to: string): { tone: 'success' | 'warning'; text: string } {
  if (outcome.sent) return { tone: 'success', text: `We emailed the invitation to ${to}.` };
  switch (outcome.reason) {
    case 'not_configured':
      return { tone: 'warning', text: 'Email is not set up yet, so nothing was sent. Copy the link below and send it yourself.' };
    case 'rate_limited':
      return { tone: 'warning', text: 'This invitation was emailed recently. Copy the link below if you need to send it again.' };
    default:
      return { tone: 'warning', text: 'We could not send the email. Copy the link below and send it yourself.' };
  }
}

// ---------------------------------------------------------------------------
// States
// ---------------------------------------------------------------------------

export type MemberState = 'active' | 'scheduled' | 'expired' | 'revoked';
export type InvitationState = 'pending' | 'accepted' | 'expired' | 'revoked';
export type Tone = 'success' | 'info' | 'warning' | 'neutral';

export const MEMBER_STATE: Record<MemberState, { label: string; tone: Tone }> = {
  active: { label: 'Active', tone: 'success' },
  scheduled: { label: 'Starts later', tone: 'info' },
  expired: { label: 'Access ended', tone: 'neutral' },
  revoked: { label: 'Removed', tone: 'neutral' },
};

export const INVITATION_STATE: Record<InvitationState, { label: string; tone: Tone }> = {
  pending: { label: 'Waiting', tone: 'info' },
  accepted: { label: 'Accepted', tone: 'success' },
  expired: { label: 'Expired', tone: 'warning' },
  revoked: { label: 'Cancelled', tone: 'neutral' },
};

export function isMemberState(v: unknown): v is MemberState {
  return v === 'active' || v === 'scheduled' || v === 'expired' || v === 'revoked';
}
export function isInvitationState(v: unknown): v is InvitationState {
  return v === 'pending' || v === 'accepted' || v === 'expired' || v === 'revoked';
}

/** Someone whose access is, or will be, in force: they belong in the main list. Ended and removed go to history. */
export function isCurrentMember(state: MemberState): boolean {
  return state === 'active' || state === 'scheduled';
}

/** A new link can be sent for a waiting or expired invitation; a used or cancelled one is finished. */
export function canSendNewLink(state: InvitationState): boolean {
  return state === 'pending' || state === 'expired';
}

/** A waiting or expired invitation can be cancelled (an expired one is still pending in the database). */
export function canCancelInvitation(state: InvitationState): boolean {
  return state === 'pending' || state === 'expired';
}

/** Owners and organizers are not removed from here: only the platform team can do that, and the database enforces it. */
export function canRemoveMember(role: string, state: MemberState): boolean {
  if (role === 'owner' || role === 'organizer') return false;
  return state !== 'revoked';
}

// ---------------------------------------------------------------------------
// Wording
// ---------------------------------------------------------------------------

const fmt = (iso: string, locale?: string) =>
  new Date(iso).toLocaleString(locale, { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' });

/** "Ongoing", "Oct 10, 9:00 PM to Oct 11, 3:00 AM", "From ...", "Until ...". */
export function describeAccess(start: string | null, end: string | null, locale?: string): string {
  if (!start && !end) return 'Ongoing';
  if (start && end) return `${fmt(start, locale)} to ${fmt(end, locale)}`;
  if (start) return `From ${fmt(start, locale)}`;
  return `Until ${fmt(end as string, locale)}`;
}

/** A person's name, or their email when they have no profile name yet. */
export function displayName(name: string | null, email: string | null): string {
  return name?.trim() || email || 'Unknown';
}

/** Where someone works: the club, and the event if they are scoped to one. */
export function describeScope(venueName: string | null, eventTitle: string | null, shiftName: string | null): string {
  const parts = [venueName, eventTitle, shiftName].filter((p): p is string => !!p);
  return parts.length ? parts.join(' · ') : 'Whole business';
}

// ---------------------------------------------------------------------------
// Reading what the database returns
// ---------------------------------------------------------------------------

export interface TeamMember {
  membershipId: string;
  userId: string;
  email: string | null;
  name: string | null;
  role: string;
  venueId: string | null;
  venueName: string | null;
  eventId: string | null;
  eventTitle: string | null;
  shiftId: string | null;
  shiftName: string | null;
  accessStartAt: string | null;
  accessEndAt: string | null;
  state: MemberState;
  createdAt: string;
}

export interface TeamInvitation {
  invitationId: string;
  email: string;
  role: string;
  venueId: string | null;
  venueName: string | null;
  eventId: string | null;
  eventTitle: string | null;
  shiftId: string | null;
  shiftName: string | null;
  accessStartAt: string | null;
  accessEndAt: string | null;
  state: InvitationState;
  expiresAt: string;
  createdAt: string;
  emailsSent: number;
  lastEmailedAt: string | null;
}

export interface Shift {
  shiftId: string;
  name: string;
  startsAt: string;
  endsAt: string;
  eventTitle: string | null;
}

const str = (v: unknown): string | null => (typeof v === 'string' && v !== '' ? v : null);

/** One list_team() row. A row whose state this code does not know is dropped: it is better to omit a person than to mislabel them. */
export function parseTeamMember(row: Record<string, unknown>): TeamMember | null {
  if (typeof row.membership_id !== 'string' || typeof row.user_id !== 'string' || typeof row.role !== 'string') return null;
  if (!isMemberState(row.state)) return null;
  return {
    membershipId: row.membership_id,
    userId: row.user_id,
    email: str(row.email),
    name: str(row.name),
    role: row.role,
    venueId: str(row.venue_id),
    venueName: str(row.venue_name),
    eventId: str(row.event_id),
    eventTitle: str(row.event_title),
    shiftId: str(row.shift_id),
    shiftName: str(row.shift_name),
    accessStartAt: str(row.access_start_at),
    accessEndAt: str(row.access_end_at),
    state: row.state,
    createdAt: str(row.created_at) ?? '',
  };
}

export function parseTeamInvitation(row: Record<string, unknown>): TeamInvitation | null {
  if (typeof row.invitation_id !== 'string' || typeof row.email !== 'string' || typeof row.role !== 'string') return null;
  if (!isInvitationState(row.state)) return null;
  return {
    invitationId: row.invitation_id,
    email: row.email,
    role: row.role,
    venueId: str(row.venue_id),
    venueName: str(row.venue_name),
    eventId: str(row.event_id),
    eventTitle: str(row.event_title),
    shiftId: str(row.shift_id),
    shiftName: str(row.shift_name),
    accessStartAt: str(row.access_start_at),
    accessEndAt: str(row.access_end_at),
    state: row.state,
    expiresAt: str(row.expires_at) ?? '',
    createdAt: str(row.created_at) ?? '',
    emailsSent: typeof row.emails_sent === 'number' ? row.emails_sent : 0,
    lastEmailedAt: str(row.last_emailed_at),
  };
}

export function parseShift(row: Record<string, unknown>): Shift | null {
  if (typeof row.shift_id !== 'string' || typeof row.starts_at !== 'string' || typeof row.ends_at !== 'string') return null;
  return {
    shiftId: row.shift_id,
    name: str(row.name) ?? 'Shift',
    startsAt: row.starts_at,
    endsAt: row.ends_at,
    eventTitle: str(row.event_title),
  };
}

/** The main list and the history, each in the order the database gave them. */
export function splitTeam(members: readonly TeamMember[]): { current: TeamMember[]; history: TeamMember[] } {
  return {
    current: members.filter((m) => isCurrentMember(m.state)),
    history: members.filter((m) => !isCurrentMember(m.state)),
  };
}
