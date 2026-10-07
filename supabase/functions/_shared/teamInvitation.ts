// The logic of send-team-invitation, with its collaborators passed in so it can be tested without a network.
//
// Safety comes from the database function reserve_invitation_email(): it takes no address (the recipient is the
// one stored on the invitation), requires the caller to manage that invitation AND hold the link token, and
// rate-limits sends per link. This code only turns its answer into an email and an HTTP status.

import { buildInvitationEmail, type InvitationEmailContext } from './teamInvitationTemplate.ts';
import type { SendResult } from './teamInvitationEmail.ts';

export interface Deps {
  /** Calls a database function as the signed-in caller (never with a service key). */
  rpc: (fn: string, args: Record<string, unknown>) => Promise<{ data: unknown; error: { message: string } | null }>;
  send: (to: string, subject: string, html: string, text: string) => Promise<SendResult>;
  /** Where the invitation link points. Trusted configuration, never taken from the request body. */
  siteUrl: string;
}

export interface Outcome {
  status: number;
  body: Record<string, unknown>;
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// Database messages are written for developers: map the ones we expect to a status and a sentence, and hide the rest.
const MAPPED: [RegExp, number, string][] = [
  [/wait a minute/i, 429, 'Please wait a minute before sending this invitation again.'],
  [/limit reached/i, 429, 'This invitation has already been emailed three times. Copy the link and send it yourself, or create a new link.'],
  [/not pending/i, 409, 'This invitation was already used, cancelled or has expired.'],
  [/not allowed|not authenticated/i, 403, 'You are not allowed to send this invitation.'],
];

const text = (v: unknown): string | null => (typeof v === 'string' && v !== '' ? v : null);

export async function sendTeamInvitation(body: unknown, deps: Deps): Promise<Outcome> {
  const b = (body && typeof body === 'object' ? body : {}) as Record<string, unknown>;
  const invitationId = b.invitation_id;
  const token = b.token;
  if (typeof invitationId !== 'string' || !UUID.test(invitationId) || typeof token !== 'string' || token.length < 20 || token.length > 200) {
    return { status: 400, body: { error: 'An invitation and its link are required.' } };
  }

  // Checked before the database is asked, so a misconfigured site address does not use up one of the three sends.
  if (!/^https?:\/\/[^\s/]+/.test(deps.siteUrl)) {
    console.error('send-team-invitation: site address is not configured');
    return { status: 500, body: { error: 'Could not send the invitation.' } };
  }

  const { data, error } = await deps.rpc('reserve_invitation_email', { p_invitation: invitationId, p_token: token });
  if (error) {
    const hit = MAPPED.find(([pattern]) => pattern.test(error.message));
    if (hit) return { status: hit[1], body: { error: hit[2] } };
    console.error('send-team-invitation: reserve failed');
    return { status: 500, body: { error: 'Could not send the invitation.' } };
  }

  const row = (Array.isArray(data) ? data[0] : data) as Record<string, unknown> | undefined;
  const to = text(row?.invitee_email);
  const orgName = text(row?.org_name);
  const role = text(row?.role);
  const expiresAt = text(row?.expires_at);
  if (!row || !to || !orgName || !role || !expiresAt) {
    console.error('send-team-invitation: unexpected reserve result');
    return { status: 500, body: { error: 'Could not send the invitation.' } };
  }

  const context: InvitationEmailContext = {
    inviteeEmail: to,
    role,
    orgName,
    venueName: text(row.venue_name),
    eventTitle: text(row.event_title),
    shiftName: text(row.shift_name),
    accessStartAt: text(row.access_start_at),
    accessEndAt: text(row.access_end_at),
    expiresAt,
    inviterName: text(row.inviter_name),
  };
  const link = `${deps.siteUrl.replace(/\/+$/, '')}/accept-invite?token=${encodeURIComponent(token)}`;
  const { subject, html, text: plain } = buildInvitationEmail(context, link);

  const result = await deps.send(to, subject, html, plain);
  // Always 200 once the invitation was valid: the screen shows the link either way, and says whether mail went out.
  return { status: 200, body: result.sent ? { sent: true, to } : { sent: false, reason: result.reason ?? 'send_failed' } };
}
