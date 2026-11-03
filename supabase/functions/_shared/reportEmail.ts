// The logic of send-report-email, with its collaborators passed in so it can be tested without a network.
//
// The app builds a report PDF on the phone and asks to e-mail it. This function never takes addresses from the request: the database reads the configured list of THAT kind of
// report (and checks the caller may send it), writes one pending row for each address, and this sends one e-mail each and records what the provider said. The text of the e-mail is
// fixed (_shared/reportEmailTemplate.ts). See 20261119100000_report_emails.sql.

import type { SendResult } from './teamInvitationEmail.ts';
import type { PdfAttachment } from './reportEmailSender.ts';
import { buildReportEmail, REPORT_KINDS, type ReportKind } from './reportEmailTemplate.ts';

export const MAX_PDF_BYTES = 5 * 1024 * 1024;
/** The longest base64 text of a PDF that fits MAX_PDF_BYTES. */
export const MAX_BASE64_CHARS = Math.ceil(MAX_PDF_BYTES / 3) * 4;

type RpcResult = Promise<{ data: unknown; error: { message: string } | null }>;

export interface Deps {
  /** The signed-in caller's e-mail address, from their verified session. Never taken from the request body. */
  senderEmail: string | null;
  /** Calls a database function AS THE CALLER (their session), so the database decides what they may do. */
  rpcUser: (fn: string, args: Record<string, unknown>) => RpcResult;
  /** Calls a database function with the SERVICE role. Only this function holds that key. */
  rpcService: (fn: string, args: Record<string, unknown>) => RpcResult;
  send: (to: string, subject: string, html: string, text: string, attachment: PdfAttachment) => Promise<SendResult>;
}

export interface Outcome {
  status: number;
  body: Record<string, unknown>;
}

// Database messages are written for developers or for the screen: map the ones we expect to a status and a sentence, and hide the rest.
const MAPPED: [RegExp, number, string][] = [
  [/not allowed/i, 403, 'You cannot e-mail this report.'],
  [/too many reports/i, 429, 'Too many reports were sent this hour. Try again later.'],
  [/no one is set/i, 409, 'No one is set to receive this report. Add an e-mail address first.'],
  [/nothing to send again/i, 409, 'There is nothing to send again: every address already got this report.'],
  [/too large/i, 413, 'This report is too large to e-mail.'],
  [/say which (night|report)/i, 400, 'Say which report this is.'],
  [/file name/i, 400, 'The report has an unusable file name.'],
  [/report is empty/i, 400, 'The report is empty.'],
];

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const idOrNull = (v: unknown): string | null | undefined => (v == null ? null : typeof v === 'string' && UUID.test(v) ? v : undefined);
const text = (v: unknown): string | null => (typeof v === 'string' && v !== '' ? v : null);

/** The size of a base64 text in bytes, without decoding it. */
export function base64Bytes(b64: string): number {
  const pad = b64.endsWith('==') ? 2 : b64.endsWith('=') ? 1 : 0;
  return Math.floor((b64.length * 3) / 4) - pad;
}

export async function sendReport(body: unknown, deps: Deps): Promise<Outcome> {
  if (!deps.senderEmail) return { status: 401, body: { error: 'Sign in to e-mail a report.' } };
  const b = (body && typeof body === 'object' ? body : {}) as Record<string, unknown>;

  const kind = b.kind as ReportKind;
  const orgId = idOrNull(b.orgId);
  const venueId = idOrNull(b.venueId);
  const eventId = idOrNull(b.eventId);
  const ref = text(b.ref);
  const filename = text(b.filename);
  const pdf = b.pdfBase64;
  if (!REPORT_KINDS.includes(kind) || !orgId || venueId === undefined || eventId === undefined || !ref || !filename) {
    return { status: 400, body: { error: 'Say which report this is.' } };
  }
  if (typeof pdf !== 'string' || pdf.length === 0) return { status: 400, body: { error: 'The report is empty.' } };
  if (pdf.length > MAX_BASE64_CHARS) return { status: 413, body: { error: 'This report is too large to e-mail.' } };
  // "%PDF-" in base64: refuses anything that is not a PDF before it reaches an inbox.
  if (!pdf.startsWith('JVBERi0') || !/^[A-Za-z0-9+/]+={0,2}$/.test(pdf) || pdf.length % 4 !== 0) {
    return { status: 400, body: { error: 'That is not a PDF.' } };
  }
  const bytes = base64Bytes(pdf);
  if (bytes > MAX_PDF_BYTES) return { status: 413, body: { error: 'This report is too large to e-mail.' } };

  const begin = await deps.rpcUser('report_send_begin', {
    p_kind: kind, p_org: orgId, p_venue: venueId, p_event: eventId, p_ref: ref, p_filename: filename, p_bytes: bytes, p_only_failed: b.again === true,
  });
  if (begin.error) {
    const hit = MAPPED.find(([pattern]) => pattern.test(begin.error!.message));
    if (hit) return { status: hit[1], body: { error: hit[2] } };
    console.error('send-report-email: begin failed');
    return { status: 500, body: { error: 'Could not send the report.' } };
  }
  const rows = (Array.isArray(begin.data) ? begin.data : []) as Record<string, unknown>[];
  if (rows.length === 0) {
    console.error('send-report-email: no rows to send');
    return { status: 500, body: { error: 'Could not send the report.' } };
  }

  const results: { id: string; ok: boolean; error?: string }[] = [];
  const shown: { email: string; ok: boolean }[] = [];
  for (const row of rows) {
    const id = text(row.delivery_id);
    const to = text(row.email);
    const orgName = text(row.org_name);
    if (!id || !to || !orgName) {
      console.error('send-report-email: unexpected row');
      continue;
    }
    const mail = buildReportEmail({
      kind, orgName, venueName: text(row.venue_name), eventTitle: text(row.event_title), ref, senderEmail: deps.senderEmail, filename,
    });
    let sent: SendResult;
    try {
      sent = await deps.send(to, mail.subject, mail.html, mail.text, { filename, contentBase64: pdf });
    } catch {
      sent = { sent: false, reason: 'send_failed' };
    }
    results.push(sent.sent ? { id, ok: true } : { id, ok: false, error: sent.reason === 'not_configured' ? 'the e-mail provider is not configured' : 'the e-mail provider did not accept the message' });
    shown.push({ email: to, ok: sent.sent });
  }

  // Record what happened. If this fails the e-mails still went out, so say what we know.
  const finish = await deps.rpcService('report_send_finish', { p_results: results });
  if (finish.error) console.error('send-report-email: could not record the result');

  const sentCount = shown.filter((r) => r.ok).length;
  return { status: 200, body: { sent: sentCount, failed: shown.length - sentCount, results: shown } };
}
