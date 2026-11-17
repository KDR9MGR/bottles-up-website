// The logic of run-report-jobs, with its collaborators passed in so it can be tested without a network.
//
// When a night is closed the database queues the reports whose automatic sending someone switched on (20261126100000_auto_report_jobs.sql). This takes the jobs that are due, asks the database
// for each report AS the person who switched it on (so their access is checked every time), makes the PDF, and sends it to the configured list exactly as the button does, writing the same
// delivery log. Nothing in the request chooses a report or an address. A failure before anything was sent is tried again later; an address that did not accept the e-mail is not retried here
// (the others would get a second copy): it shows in the log and "Send again" handles it.

import { buildReportEmail, type ReportKind } from './reportEmailTemplate.ts';
import { MAX_PDF_BYTES } from './reportEmail.ts';
import type { PdfAttachment } from './reportEmailSender.ts';
import { documentForJob } from './reportDocs.ts';
import { buildReportPdf, toBase64 } from './reportPdf.ts';
import type { SendResult } from './teamInvitationEmail.ts';

type RpcResult = Promise<{ data: unknown; error: { message: string } | null }>;

export interface JobDeps {
  /** Calls a database function with the SERVICE role. Only the scheduled function holds that key. */
  rpc: (fn: string, args: Record<string, unknown>) => RpcResult;
  send: (to: string, subject: string, html: string, text: string, attachment: PdfAttachment) => Promise<SendResult>;
  /** Is the e-mail provider set up? Checked before any delivery is written, so a missing key leaves nothing half done. */
  emailConfigured: () => boolean;
  now: () => Date;
}

export interface Summary {
  claimed: number;
  sent: number;
  skipped: number;
  failed: number;
  retried: number;
}

type Outcome = { outcome: 'sent' | 'skipped' | 'failed' | 'retry'; error?: string };

const text = (v: unknown): string | null => (typeof v === 'string' && v !== '' ? v : null);

/** What a database refusal means for the job. The messages are the database's own; the sentences are what a person reads under the switch. */
function fromRefusal(message: string): Outcome {
  if (/switched off/i.test(message)) return { outcome: 'skipped', error: 'Automatic sending was switched off.' };
  if (/not allowed/i.test(message)) return { outcome: 'failed', error: 'The person who switched it on no longer has access. Switch it on again.' };
  if (/nobody is set to send/i.test(message)) return { outcome: 'failed', error: 'The person who switched it on is no longer here. Switch it on again.' };
  if (/no one is set to receive/i.test(message)) return { outcome: 'skipped', error: 'No one is set to receive it. Add an e-mail address first.' };
  if (/too many reports/i.test(message)) return { outcome: 'retry', error: 'Too many reports were sent this hour.' };
  if (/too large/i.test(message)) return { outcome: 'failed', error: 'The report is too large to e-mail.' };
  if (/file name/i.test(message)) return { outcome: 'failed', error: 'The report has an unusable file name.' };
  return { outcome: 'retry', error: 'The report could not be prepared.' };
}

async function runOne(job: Record<string, unknown>, deps: JobDeps): Promise<Outcome> {
  const jobId = text(job.job_id);
  const kind = text(job.kind) as ReportKind | null;
  const ref = text(job.report_ref);
  if (!jobId || !kind || !ref) return { outcome: 'failed', error: 'The job could not be read.' };

  const data = await deps.rpc('report_job_data', { p_job: jobId });
  if (data.error) return fromRefusal(data.error.message);

  const doc = documentForJob(data.data);
  if (doc === null) return { outcome: 'failed', error: 'The report could not be read.' };

  let bytes: Uint8Array;
  try {
    bytes = await buildReportPdf(doc, deps.now());
  } catch {
    return { outcome: 'retry', error: 'The PDF could not be made.' };
  }
  if (bytes.length > MAX_PDF_BYTES) return { outcome: 'failed', error: 'The report is too large to e-mail.' };
  if (!deps.emailConfigured()) return { outcome: 'retry', error: 'The e-mail provider is not configured.' };

  const begin = await deps.rpc('report_job_begin', { p_job: jobId, p_filename: doc.fileName, p_bytes: bytes.length });
  if (begin.error) return fromRefusal(begin.error.message);
  const rows = (Array.isArray(begin.data) ? begin.data : []) as Record<string, unknown>[];
  if (rows.length === 0) return { outcome: 'skipped', error: 'No one is set to receive it. Add an e-mail address first.' };

  const pdf = toBase64(bytes);
  const results: { id: string; ok: boolean; error?: string }[] = [];
  for (const row of rows) {
    const id = text(row.delivery_id);
    const to = text(row.email);
    const orgName = text(row.org_name);
    if (!id || !to || !orgName) continue;
    const mail = buildReportEmail({ kind, orgName, venueName: text(row.venue_name), eventTitle: text(row.event_title), ref, senderEmail: '', filename: doc.fileName, automatic: true });
    let sent: SendResult;
    try {
      sent = await deps.send(to, mail.subject, mail.html, mail.text, { filename: doc.fileName, contentBase64: pdf });
    } catch {
      sent = { sent: false, reason: 'send_failed' };
    }
    results.push(sent.sent ? { id, ok: true } : { id, ok: false, error: sent.reason === 'not_configured' ? 'the e-mail provider is not configured' : 'the e-mail provider did not accept the message' });
  }
  // Nothing was handed to the provider at all (every row of the list was unusable): that is not "sent".
  if (results.length === 0) return { outcome: 'failed', error: 'The list of addresses could not be read.' };
  // Record what the provider said. If this fails the e-mails still went out: the job is done either way.
  const finish = await deps.rpc('report_send_finish', { p_results: results });
  if (finish.error) console.error('run-report-jobs: could not record the deliveries');
  if (results.every((r) => !r.ok)) return { outcome: 'failed', error: 'The e-mail provider did not accept the message. Use Send again.' };
  return { outcome: 'sent' };
}

export async function runReportJobs(deps: JobDeps, limit = 3): Promise<Summary> {
  const summary: Summary = { claimed: 0, sent: 0, skipped: 0, failed: 0, retried: 0 };
  const claim = await deps.rpc('report_job_claim', { p_limit: limit });
  if (claim.error) throw new Error('report_job_claim failed');
  const jobs = (Array.isArray(claim.data) ? claim.data : []) as Record<string, unknown>[];
  summary.claimed = jobs.length;
  for (const job of jobs) {
    let result: Outcome;
    try {
      result = await runOne(job, deps);
    } catch {
      result = { outcome: 'retry', error: 'The run stopped unexpectedly.' };
    }
    const jobId = text(job.job_id);
    if (!jobId) continue;
    const done = await deps.rpc('report_job_finish', { p_job: jobId, p_outcome: result.outcome, p_error: result.error ?? null });
    if (done.error) console.error('run-report-jobs: could not record how a job ended');
    const status = typeof done.data === 'string' ? done.data : result.outcome;
    if (status === 'sent') summary.sent++;
    else if (status === 'skipped') summary.skipped++;
    else if (status === 'pending') summary.retried++;
    else summary.failed++;
  }
  return summary;
}
