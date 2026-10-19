// The outbox sender's logic, with nothing in it that touches the network or the clock directly, so every rule can be tested.
//
// The app queues guest messages in public.site_outbox (table seated, wait estimate changed, VIP invitation). The edge function `process-outbox`
// claims a batch with outbox_claim(), sends each one by e-mail, and reports with outbox_finish(). The database guarantees one sender per message
// at a time and stops after 5 attempts (20261019100000_outbox_claim.sql); the rules here decide WHAT happens to each claimed message:
//
//   (walkin_confirmation: a table a manager booked for a guest who is here. It says the table is booked, the code, and the deposit still due at the club.)
//   * it is sent, only if the facts are still true when it goes out (a guest who was un-seated is not told they are seated; an estimate that
//     was cleared is not announced; an ended VIP membership is not invited);
//   * it fails at once, with a reason a manager can read, when it can never be sent (no address, unknown kind, gone, too old);
//   * it is retried later when the provider failed (the database spaces attempts 10 minutes apart and gives up after the 5th).
// A message older than MAX_AGE_HOURS is not sent: "your table is ready" a day late is worse than silence.
//
// The wording below is a first draft written from the client's brief ("a customer acknowledgment with booking details and the staff-entered
// estimate"), to be reviewed by the client before this is switched on.

import { escapeHtml } from './teamInvitationTemplate.ts';

export const MAX_AGE_HOURS = 12;
export const BATCH_SIZE = 20;

export interface ClaimedMessage {
  id: string;
  kind: string;
  venue_id: string | null;
  ref_id: string | null;
  payload: Record<string, unknown> | null;
  attempts: number;
  created_at: string;
}

export interface BookingFacts {
  type: 'booking';
  customerEmail: string | null;
  customerName: string | null;
  venueName: string;
  tableTypeName: string;
  guestCount: number;
  confirmationCode: string | null;
  startTime: string | null;
  seated: boolean;
  estimateMinutes: number | null;
  /** What is still to be paid at the club (the booking's total less what was collected), in cents. */
  dueCents: number;
}

export interface VipFacts {
  type: 'vip';
  email: string | null;
  name: string;
  tier: string;
  credentialCode: string;
  validFrom: string | null;
  validUntil: string | null;
  ended: boolean;
  venueName: string;
}

export type Facts = BookingFacts | VipFacts | null;

export type Decision =
  | { action: 'send'; to: string; subject: string; html: string; text: string }
  | { action: 'fail'; reason: string };

const oneLine = (v: string) => v.replace(/\s+/g, ' ').trim();
const EMAIL = /^[^\s@<>,;]+@[^\s@<>,;]+\.[^\s@<>,;]+$/;

export function isSendableEmail(value: string | null | undefined): value is string {
  return typeof value === 'string' && value.length <= 254 && EMAIL.test(value.trim());
}

export function formatMinutes(minutes: number): string {
  if (minutes < 60) return `${minutes} minute${minutes === 1 ? '' : 's'}`;
  const h = Math.floor(minutes / 60);
  const m = minutes % 60;
  const hours = `${h} hour${h === 1 ? '' : 's'}`;
  return m === 0 ? hours : `${hours} ${m} minute${m === 1 ? '' : 's'}`;
}

/** '01:00:00' -> '1:00 AM', '22:30:00' -> '10:30 PM'. Anything else is shown as it came. */
export function formatClock(time: string | null): string | null {
  if (!time) return null;
  const m = /^(\d{1,2}):(\d{2})/.exec(time);
  if (!m) return time;
  const h = Number(m[1]);
  if (h > 23) return time;
  return `${h % 12 === 0 ? 12 : h % 12}:${m[2]} ${h < 12 ? 'AM' : 'PM'}`;
}

function shell(heading: string, body: string): string {
  return `
    <div style="font-family: sans-serif; max-width: 480px; margin: 0 auto; padding: 24px; background: #0a0a0a; color: #fff; border-radius: 16px;">
      <h1 style="color: #f97316; font-size: 22px;">${escapeHtml(heading)}</h1>
      ${body}
      <p style="color: #999; font-size: 13px; margin-top: 24px;">BottlesUp</p>
    </div>
  `;
}

function detailRows(rows: Array<[string, string]>): string {
  return `<table style="width: 100%; border-collapse: collapse; margin: 16px 0;">
        ${rows.map(([k, v]) => `<tr><td style="padding: 4px 0; color: #ccc;">${escapeHtml(k)}</td><td style="padding: 4px 0; color: #fff; text-align: right;">${escapeHtml(v)}</td></tr>`).join('\n        ')}
      </table>`;
}

function bookingRows(f: BookingFacts): Array<[string, string]> {
  const rows: Array<[string, string]> = [['Venue', f.venueName], ['Table', f.tableTypeName], ['Party', `${f.guestCount} guest${f.guestCount === 1 ? '' : 's'}`]];
  const clock = formatClock(f.startTime);
  if (clock) rows.push(['Arrival time', clock]);
  if (f.confirmationCode) rows.push(['Booking code', f.confirmationCode]);
  return rows;
}

function renderBooking(kind: 'seated_ack' | 'estimate_updated', f: BookingFacts, siteUrl: string): { subject: string; html: string; text: string } {
  const name = oneLine(f.customerName ?? '') || 'there';
  const venue = oneLine(f.venueName);
  const estimate = f.estimateMinutes != null ? formatMinutes(f.estimateMinutes) : null;
  const link = f.confirmationCode ? `${siteUrl.replace(/\/+$/, '')}/booking/${encodeURIComponent(f.confirmationCode)}` : null;

  const intro = kind === 'seated_ack' ? `Your party has been seated at ${venue}.` : `The service estimate for your table at ${venue} has changed.`;
  const estimateLine = estimate
    ? `${kind === 'seated_ack' ? 'Your server estimates' : 'Your server now estimates'} about ${estimate} for bottle service.`
    : null;
  const linkHtml = link
    ? `<p><a href="${escapeHtml(link)}" style="color: #f97316;">View your booking</a></p>`
    : '';

  const html = shell(
    kind === 'seated_ack' ? 'You are seated' : 'Updated service estimate',
    `<p>Hi ${escapeHtml(name)},</p>
      <p>${escapeHtml(intro)}</p>
      ${estimateLine ? `<p style="font-size: 18px; font-weight: bold;">${escapeHtml(estimateLine)}</p>` : ''}
      ${detailRows(bookingRows(f))}
      ${linkHtml}
      <p style="color: #999; font-size: 13px;">This message only lets you know where things stand. It does not change what you have paid or what is still due at the venue.</p>`,
  );
  const text = [
    `Hi ${name},`,
    '',
    intro,
    ...(estimateLine ? [estimateLine] : []),
    '',
    ...bookingRows(f).map(([k, v]) => `${k}: ${v}`),
    ...(link ? ['', `View your booking: ${link}`] : []),
    '',
    'This message only lets you know where things stand. It does not change what you have paid or what is still due at the venue.',
  ].join('\n');
  const subject = oneLine(kind === 'seated_ack' ? `You're seated at ${venue}` : `Updated service estimate at ${venue}`);
  return { subject, html, text };
}

function renderWalkin(f: BookingFacts, siteUrl: string): { subject: string; html: string; text: string } {
  const name = oneLine(f.customerName ?? '') || 'there';
  const venue = oneLine(f.venueName);
  const link = f.confirmationCode ? `${siteUrl.replace(/\/+$/, '')}/booking/${encodeURIComponent(f.confirmationCode)}` : null;
  const rows = bookingRows(f);
  if (f.dueCents > 0) rows.push(['Still to pay at the club', `$${(f.dueCents / 100).toFixed(2)}`]);
  const intro = `Your table at ${venue} is booked.`;
  const html = shell(
    'Your table is booked',
    `<p>Hi ${escapeHtml(name)},</p>
      <p>${escapeHtml(intro)}</p>
      ${detailRows(rows)}
      ${link ? `<p><a href="${escapeHtml(link)}" style="color: #f97316;">View your booking</a></p>` : ''}
      <p style="color: #999; font-size: 13px;">Show your booking code to the team at the venue. What is still to pay is paid at the club.</p>`,
  );
  const text = [
    `Hi ${name},`,
    '',
    intro,
    '',
    ...rows.map(([k, v]) => `${k}: ${v}`),
    ...(link ? ['', `View your booking: ${link}`] : []),
    '',
    'Show your booking code to the team at the venue. What is still to pay is paid at the club.',
  ].join('\n');
  return { subject: oneLine(`Your table at ${venue} is booked`), html, text };
}

function renderVip(f: VipFacts): { subject: string; html: string; text: string } {
  const name = oneLine(f.name) || 'there';
  const venue = oneLine(f.venueName);
  const rows: Array<[string, string]> = [['Venue', venue], ['Level', oneLine(f.tier)], ['Your code', f.credentialCode]];
  if (f.validFrom) rows.push(['Valid from', f.validFrom]);
  if (f.validUntil) rows.push(['Valid until', f.validUntil]);
  const html = shell(
    'Your VIP access',
    `<p>Hi ${escapeHtml(name)},</p>
      <p>${escapeHtml(venue)} has added you to its VIP list. Give your code to the door team when you arrive.</p>
      ${detailRows(rows)}
      <p style="color: #999; font-size: 13px;">Keep this code to yourself. If you were not expecting this message, you can ignore it.</p>`,
  );
  const text = [
    `Hi ${name},`,
    '',
    `${venue} has added you to its VIP list. Give your code to the door team when you arrive.`,
    '',
    ...rows.map(([k, v]) => `${k}: ${v}`),
    '',
    'Keep this code to yourself. If you were not expecting this message, you can ignore it.',
  ].join('\n');
  return { subject: oneLine(`Your VIP access at ${venue}`), html, text };
}

export function decideMessage(msg: ClaimedMessage, facts: Facts, nowMs: number, siteUrl: string): Decision {
  const created = Date.parse(msg.created_at);
  if (Number.isFinite(created) && nowMs - created > MAX_AGE_HOURS * 3600_000) {
    return { action: 'fail', reason: `Not sent: the message was more than ${MAX_AGE_HOURS} hours old` };
  }

  if (msg.kind === 'seated_ack' || msg.kind === 'estimate_updated') {
    if (!facts || facts.type !== 'booking') return { action: 'fail', reason: 'Not sent: the booking no longer exists' };
    if (!facts.seated) return { action: 'fail', reason: 'Not sent: the guest is no longer marked as seated' };
    if (!isSendableEmail(facts.customerEmail)) return { action: 'fail', reason: 'Not sent: the booking has no valid e-mail address' };
    if (msg.kind === 'estimate_updated' && facts.estimateMinutes == null) return { action: 'fail', reason: 'Not sent: the estimate was cleared' };
    const m = renderBooking(msg.kind, facts, siteUrl);
    return { action: 'send', to: facts.customerEmail.trim(), ...m };
  }

  if (msg.kind === 'walkin_confirmation') {
    if (!facts || facts.type !== 'booking') return { action: 'fail', reason: 'Not sent: the booking no longer exists' };
    if (!isSendableEmail(facts.customerEmail)) return { action: 'fail', reason: 'Not sent: the booking has no valid e-mail address' };
    const m = renderWalkin(facts, siteUrl);
    return { action: 'send', to: facts.customerEmail.trim(), ...m };
  }

  if (msg.kind === 'vip_invite') {
    if (!facts || facts.type !== 'vip') return { action: 'fail', reason: 'Not sent: the VIP membership no longer exists' };
    if (facts.ended) return { action: 'fail', reason: 'Not sent: the VIP membership has ended' };
    if (!isSendableEmail(facts.email)) return { action: 'fail', reason: 'Not sent: the VIP guest has no valid e-mail address' };
    const m = renderVip(facts);
    return { action: 'send', to: facts.email.trim(), ...m };
  }

  return { action: 'fail', reason: `Not sent: unknown message kind "${oneLine(String(msg.kind)).slice(0, 40)}"` };
}

// ---------------------------------------------------------------------------------------------------------------------------------------
// Reading the facts a message needs, at the moment it is about to go out
// ---------------------------------------------------------------------------------------------------------------------------------------

// Only the part of the Supabase client that is used, so tests can hand in a fake. The real client's query builder is a deep generic type that
// is not worth restating here; every row read below is checked field by field when it is used.
// eslint-disable-next-line @typescript-eslint/no-explicit-any
type Db = { from: (table: string) => any };

export async function loadFacts(db: Db, msg: ClaimedMessage): Promise<Facts> {
  if (!msg.ref_id) return null;

  if (msg.kind === 'seated_ack' || msg.kind === 'estimate_updated' || msg.kind === 'walkin_confirmation') {
    const { data: b, error } = await db
      .from('site_table_bookings')
      .select('customer_email, customer_name, guest_count, confirmation_code, amount_total_cents, amount_paid_cents, table_type:site_table_types(name), venue:site_venues(name), time_slot:site_venue_time_slots(start_time)')
      .eq('id', msg.ref_id)
      .maybeSingle();
    if (error) throw new Error('could not read the booking');
    if (!b) return null;
    const { data: seat, error: seatError } = await db.from('site_booking_seating').select('estimate_minutes').eq('booking_id', msg.ref_id).maybeSingle();
    if (seatError) throw new Error('could not read the seating');
    return {
      type: 'booking',
      customerEmail: b.customer_email ?? null,
      customerName: b.customer_name ?? null,
      venueName: b.venue?.name ?? 'the venue',
      tableTypeName: b.table_type?.name ?? 'your table',
      guestCount: b.guest_count ?? 1,
      confirmationCode: b.confirmation_code ?? null,
      startTime: b.time_slot?.start_time ?? null,
      seated: !!seat,
      estimateMinutes: seat?.estimate_minutes ?? null,
      dueCents: Math.max((b.amount_total_cents ?? 0) - (b.amount_paid_cents ?? 0), 0),
    };
  }

  if (msg.kind === 'vip_invite') {
    const { data: m, error } = await db
      .from('site_vip_members')
      .select('email, name, tier, credential_code, valid_from, valid_until, ended_at, venue:site_venues(name)')
      .eq('id', msg.ref_id)
      .maybeSingle();
    if (error) throw new Error('could not read the VIP membership');
    if (!m) return null;
    return {
      type: 'vip',
      email: m.email ?? null,
      name: m.name ?? '',
      tier: m.tier ?? 'VIP',
      credentialCode: m.credential_code,
      validFrom: m.valid_from ?? null,
      validUntil: m.valid_until ?? null,
      ended: m.ended_at != null,
      venueName: m.venue?.name ?? 'the venue',
    };
  }

  return null;
}

// ---------------------------------------------------------------------------------------------------------------------------------------
// One run
// ---------------------------------------------------------------------------------------------------------------------------------------

export interface OutboxDeps {
  /** False when no e-mail provider key is set: then nothing is claimed, so no attempt is used up. */
  configured(): boolean;
  claim(limit: number): Promise<ClaimedMessage[]>;
  loadFacts(msg: ClaimedMessage): Promise<Facts>;
  send(to: string, subject: string, html: string, text: string): Promise<{ sent: boolean; reason?: string }>;
  finish(id: string, result: 'sent' | 'retry' | 'failed', error: string | null): Promise<unknown>;
  purgeChat(): Promise<number>;
  now(): number;
  siteUrl: string;
}

export interface RunSummary {
  skipped?: 'not_configured';
  /** Set when the queue itself could not be read; nothing was sent in that run. */
  error?: string;
  claimed: number;
  sent: number;
  retried: number;
  failed: number;
  /** How many expired chats were deleted; null when the clean-up itself failed. */
  chatPurged: number | null;
}

const short = (e: unknown) => (e instanceof Error ? e.message : 'unexpected error').slice(0, 200);

export async function runOutbox(deps: OutboxDeps): Promise<RunSummary> {
  const summary: RunSummary = { claimed: 0, sent: 0, retried: 0, failed: 0, chatPurged: null };

  if (!deps.configured()) {
    summary.skipped = 'not_configured';
  } else {
    let batch: ClaimedMessage[] = [];
    try {
      batch = await deps.claim(BATCH_SIZE);
    } catch (e) {
      summary.error = `could not claim messages: ${short(e)}`;
    }
    summary.claimed = batch.length;
    for (const msg of batch) {
      try {
        const facts = await deps.loadFacts(msg);
        const decision = decideMessage(msg, facts, deps.now(), deps.siteUrl);
        if (decision.action === 'fail') {
          await deps.finish(msg.id, 'failed', decision.reason);
          summary.failed++;
          continue;
        }
        const res = await deps.send(decision.to, decision.subject, decision.html, decision.text);
        if (!res.sent) {
          await deps.finish(msg.id, 'retry', res.reason === 'not_configured' ? 'the e-mail provider is not configured' : 'the e-mail provider did not accept the message');
          summary.retried++;
          continue;
        }
        // The message is out. If recording that fails, try once more: an unrecorded send is sent again after the 10 minute hold.
        try {
          await deps.finish(msg.id, 'sent', null);
        } catch {
          await deps.finish(msg.id, 'sent', null);
        }
        summary.sent++;
      } catch (e) {
        try {
          await deps.finish(msg.id, 'retry', short(e));
        } catch {
          // The hold on the message lapses by itself and it is tried again; nothing more can be done here.
        }
        summary.retried++;
      }
    }
  }

  try {
    summary.chatPurged = await deps.purgeChat();
  } catch {
    summary.chatPurged = null;
  }
  return summary;
}
