// The logic of send-complimentary-offer, with its collaborators passed in so it can be tested without a network.
//
// A club's owner or manager presses "E-mail the link" on an offer. The database decides, as THE CALLER, whether they may send this offer now (and limits how often) and says where it goes;
// only then does this function, with the service role, make the one-use link, e-mail it and record whether the e-mail went. The request carries nothing but the offer's id: no address, no text.
// The link is never returned to the app and never logged. See 20261124100000_complimentary_send.sql.

import type { SendResult } from './teamInvitationEmail.ts';
import { buildCompOfferEmail } from './compOfferEmail.ts';

type RpcResult = Promise<{ data: unknown; error: { message: string } | null }>;

export interface Deps {
  /** Calls a database function AS THE CALLER (their session), so the database decides what they may do. */
  rpcUser: (fn: string, args: Record<string, unknown>) => RpcResult;
  /** Calls a database function with the SERVICE role. Only this function holds that key. */
  rpcService: (fn: string, args: Record<string, unknown>) => RpcResult;
  send: (to: string, subject: string, html: string, text: string) => Promise<SendResult>;
  /** The website's address, no trailing slash: where /claim/<token> lives. */
  siteUrl: string;
}

export interface Outcome {
  status: number;
  body: Record<string, unknown>;
}

export const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
/** The token the database makes: two uuids with the dashes taken out. */
export const TOKEN = /^[0-9a-f]{64}$/;

const sentence = (message: string) => {
  const m = message.trim().replace(/\.$/, '');
  return m.charAt(0).toUpperCase() + m.slice(1) + '.';
};

// Database messages are written for the screen or for developers: map the ones we expect to a status, and hide the rest.
function mapError(message: string): Outcome {
  if (/not authenticated/i.test(message)) return { status: 401, body: { error: 'Sign in again to send this link.' } };
  if (/not allowed/i.test(message)) return { status: 403, body: { error: 'You cannot send this link.' } };
  if (/a link cannot be (sent|issued) for an offer that is/i.test(message)) return { status: 409, body: { error: sentence(message) } };
  if (/sent 5 times|sent a lot of links/i.test(message)) return { status: 429, body: { error: sentence(message) } };
  console.error('send-complimentary-offer: unexpected database error');
  return { status: 500, body: { error: 'The link could not be sent.' } };
}

interface Row {
  send_id: string;
  to_email: string;
  to_name: string | null;
  venue_name: string;
  event_title: string | null;
  item: string;
  quantity: number;
  expires_at: string;
  time_zone: string | null;
}

function readRow(data: unknown): Row | null {
  const r = (Array.isArray(data) ? data[0] : data) as Record<string, unknown> | undefined;
  if (!r || typeof r.send_id !== 'string' || !UUID.test(r.send_id) || typeof r.to_email !== 'string' || typeof r.venue_name !== 'string' || typeof r.item !== 'string') return null;
  if (typeof r.quantity !== 'number' || typeof r.expires_at !== 'string') return null;
  return {
    send_id: r.send_id,
    to_email: r.to_email,
    to_name: typeof r.to_name === 'string' ? r.to_name : null,
    venue_name: r.venue_name,
    event_title: typeof r.event_title === 'string' ? r.event_title : null,
    item: r.item,
    quantity: r.quantity,
    expires_at: r.expires_at,
    time_zone: typeof r.time_zone === 'string' ? r.time_zone : null,
  };
}

export async function sendCompOffer(body: unknown, deps: Deps): Promise<Outcome> {
  const offerId = body && typeof body === 'object' ? (body as Record<string, unknown>).offerId : undefined;
  if (typeof offerId !== 'string' || !UUID.test(offerId)) return { status: 400, body: { error: 'Say which offer to send.' } };

  const begun = await deps.rpcUser('comp_offer_send_begin', { p_offer: offerId });
  if (begun.error) return mapError(begun.error.message);
  const row = readRow(begun.data);
  if (!row) {
    console.error('send-complimentary-offer: the database answered with something unreadable');
    return { status: 500, body: { error: 'The link could not be sent.' } };
  }

  // From here an attempt is recorded as pending: every way out says how it ended.
  const finish = async (ok: boolean, why: string | null) => {
    const done = await deps.rpcService('comp_offer_send_finish', { p_send: row.send_id, p_ok: ok, p_why: ok ? null : why });
    if (done.error) console.error('send-complimentary-offer: could not record the result of an attempt');
  };

  const issued = await deps.rpcService('comp_offer_issue_link', { p_offer: offerId });
  if (issued.error || typeof issued.data !== 'string' || !TOKEN.test(issued.data)) {
    await finish(false, 'send_failed');
    return issued.error && /cannot be issued/i.test(issued.error.message) ? mapError(issued.error.message) : { status: 500, body: { error: 'The link could not be sent.' } };
  }

  let email: { subject: string; html: string; text: string };
  try {
    email = buildCompOfferEmail({
      toName: row.to_name,
      venueName: row.venue_name,
      eventTitle: row.event_title,
      item: row.item,
      quantity: row.quantity,
      expiresAt: row.expires_at,
      timeZone: row.time_zone,
      link: `${deps.siteUrl.replace(/\/+$/, '')}/claim/${issued.data}`,
    });
  } catch {
    await finish(false, 'send_failed');
    return { status: 500, body: { error: 'The link could not be sent.' } };
  }

  let result: SendResult;
  try {
    result = await deps.send(row.to_email, email.subject, email.html, email.text);
  } catch {
    result = { sent: false, reason: 'send_failed' };
  }
  if (result.sent) {
    await finish(true, null);
    return { status: 200, body: { sent: true } };
  }
  const reason = result.reason === 'not_configured' ? 'not_configured' : 'send_failed';
  await finish(false, reason);
  return { status: 200, body: { sent: false, reason } };
}
