// The logic of send-invitation-code, with its collaborators passed in so it can be tested without a network.
//
// A temporary-staff link needs a 6-digit code before it can be used (website repo, 20261118100000_temporary_staff_links.sql). The code is made by a database function that only
// the service role can call, and it travels to the invitee ONLY by e-mail: it is never in the answer this returns (that would let anyone who holds a link skip the check). The
// database matches the e-mail address of the signed-in caller to the one on the invitation and enforces the limits (one a minute, five an hour); this turns its answer into an
// e-mail and an HTTP status.

import { buildCodeEmail, type CodeEmailContext } from './invitationCodeTemplate.ts';
import type { SendResult } from './teamInvitationEmail.ts';

export interface Deps {
  /** The signed-in caller's e-mail address, from their verified session; null when they have none. Never taken from the request body. */
  callerEmail: string | null;
  /** Calls a database function with the SERVICE role. Only this function holds that key. */
  rpcService: (fn: string, args: Record<string, unknown>) => Promise<{ data: unknown; error: { message: string } | null }>;
  send: (to: string, subject: string, html: string, text: string) => Promise<SendResult>;
}

export interface Outcome {
  status: number;
  body: Record<string, unknown>;
}

// Database messages are written for developers: map the ones we expect to a status and a sentence, and hide the rest.
const MAPPED: [RegExp, number, string][] = [
  [/wait a minute/i, 429, 'Please wait a minute before asking for another code.'],
  [/too many codes/i, 429, 'Too many codes have been sent for this link. Try again in an hour, or ask the person who invited you for a new link.'],
  [/does not need a code/i, 409, 'This link does not need a code.'],
  [/not pending/i, 409, 'This link was already used, cancelled or has expired.'],
  [/not allowed/i, 403, 'This link was not sent to the address you are signed in with.'],
];

const text = (v: unknown): string | null => (typeof v === 'string' && v !== '' ? v : null);

/** "t***@club.example": enough for the person to know which inbox to look in. */
export function maskEmail(address: string): string {
  const [local, domain] = address.split('@');
  return domain ? `${local.slice(0, 1)}***@${domain}` : '***';
}

export async function sendInvitationCode(body: unknown, deps: Deps): Promise<Outcome> {
  if (!deps.callerEmail) return { status: 401, body: { error: 'Sign in with the address your invitation was sent to.' } };
  const b = (body && typeof body === 'object' ? body : {}) as Record<string, unknown>;
  const token = b.token;
  if (typeof token !== 'string' || token.length < 20 || token.length > 200) {
    return { status: 400, body: { error: 'Your invitation link is required.' } };
  }

  const { data, error } = await deps.rpcService('issue_invitation_code', { p_token: token, p_email: deps.callerEmail });
  if (error) {
    const hit = MAPPED.find(([pattern]) => pattern.test(error.message));
    if (hit) return { status: hit[1], body: { error: hit[2] } };
    console.error('send-invitation-code: issue failed');
    return { status: 500, body: { error: 'Could not send the code.' } };
  }

  const row = (Array.isArray(data) ? data[0] : data) as Record<string, unknown> | undefined;
  const to = text(row?.invitee_email);
  const code = text(row?.code);
  const role = text(row?.role);
  const orgName = text(row?.org_name);
  const codeExpiresAt = text(row?.code_expires_at);
  if (!row || !to || !code || !role || !orgName || !codeExpiresAt || !/^[0-9]{6}$/.test(code)) {
    console.error('send-invitation-code: unexpected issue result');
    return { status: 500, body: { error: 'Could not send the code.' } };
  }

  const context: CodeEmailContext = {
    code,
    role,
    orgName,
    venueName: text(row.venue_name),
    eventTitle: text(row.event_title),
    shiftName: text(row.shift_name),
    accessStartAt: text(row.access_start_at),
    accessEndAt: text(row.access_end_at),
    codeExpiresAt,
  };
  const { subject, html, text: plain } = buildCodeEmail(context);

  const result = await deps.send(to, subject, html, plain);
  // The code is never in the answer. 200 once the database made a code: the screen says whether the mail went out.
  return { status: 200, body: result.sent ? { sent: true, to_hint: maskEmail(to) } : { sent: false, reason: result.reason ?? 'send_failed' } };
}
