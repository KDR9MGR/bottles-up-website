import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { beforeEach, describe, expect, it, vi } from 'vitest';

vi.mock('../../supabase/functions/_shared/reportPdf.ts', async (importOriginal) => {
  const original = await importOriginal<typeof import('../../supabase/functions/_shared/reportPdf.ts')>();
  return { ...original, buildReportPdf: vi.fn(original.buildReportPdf) };
});
import { runReportJobs, type JobDeps } from '../../supabase/functions/_shared/reportJob.ts';
import { buildReportPdf } from '../../supabase/functions/_shared/reportPdf.ts';
import { pdfText } from './helpers/pdfText.ts';

// run-report-jobs (the logic): take the queued reports, ask the database for each AS the person who switched it on, make the PDF, send it to the configured list, write the delivery log, and say
// how the run went. Nothing in a request chooses a report or an address. The documents are the app's own (tests/fixtures/report_docs), so what is sent is what the app would have made.

const fixture = (name: string) => JSON.parse(readFileSync(join(__dirname, '..', 'fixtures', 'report_docs', `${name}.json`), 'utf8'));
const NIGHT = fixture('night_final_with_times');
const OWNER = fixture('owner_all_final');
const EVENT = fixture('event_full');

const dataOf = (f: { kind: string; timeZone: string; input: Record<string, unknown> }) => ({ kind: f.kind, time_zone: f.timeZone, ref: '2026-11-14', ...f.input });
const job = (kind = 'venue_night', over: Record<string, unknown> = {}) => ({ job_id: 'j1', kind, org_id: 'o1', venue_id: 'v1', event_id: null, report_ref: '2026-11-14', attempts: 1, ...over });
const ROWS = [
  { delivery_id: 'd1', batch_id: 'b1', email: 'a1@club.example', org_name: 'Club Co', venue_name: 'Club A', event_title: null },
  { delivery_id: 'd2', batch_id: 'b1', email: 'a2@club.example', org_name: 'Club Co', venue_name: 'Club A', event_title: null },
];
const NOW = new Date('2026-11-15T03:15:00Z');

type Reply = { data: unknown; error: { message: string } | null };
let replies: Record<string, (args: Record<string, unknown>) => Reply | Promise<Reply>>;
let calls: [string, Record<string, unknown>][];
let sends: { to: string; subject: string; html: string; text: string; filename: string; pdf: string }[];
let sendResult: (to: string) => unknown;
let configured: boolean;

const deps = (): JobDeps => ({
  rpc: async (fn, args) => {
    calls.push([fn, args]);
    const reply = replies[fn];
    if (!reply) throw new Error(`unexpected call ${fn}`);
    return reply(args);
  },
  send: async (to, subject, html, text, attachment) => {
    sends.push({ to, subject, html, text, filename: attachment.filename, pdf: attachment.contentBase64 });
    return sendResult(to) as { sent: boolean };
  },
  emailConfigured: () => configured,
  now: () => NOW,
});
const callsOf = (fn: string) => calls.filter((c) => c[0] === fn).map((c) => c[1]);
const finishes = () => callsOf('report_job_finish').map((a) => [a.p_outcome, a.p_error]);

beforeEach(() => {
  vi.clearAllMocks();
  vi.spyOn(console, 'error').mockImplementation(() => {});
  calls = [];
  sends = [];
  configured = true;
  sendResult = () => ({ sent: true });
  replies = {
    report_job_claim: () => ({ data: [job()], error: null }),
    report_job_data: () => ({ data: dataOf(NIGHT), error: null }),
    report_job_begin: () => ({ data: ROWS, error: null }),
    report_send_finish: () => ({ data: 2, error: null }),
    report_job_finish: (a) => ({ data: a.p_outcome === 'retry' ? 'pending' : a.p_outcome, error: null }),
  };
});

describe('a report that goes out', () => {
  it('takes the due jobs (three at a time), asks for the report, makes the PDF, begins the log, sends each address and says it was sent', async () => {
    const summary = await runReportJobs(deps());
    expect(summary).toEqual({ claimed: 1, sent: 1, skipped: 0, failed: 0, retried: 0 });
    expect(callsOf('report_job_claim')).toEqual([{ p_limit: 3 }]);
    expect(callsOf('report_job_data')).toEqual([{ p_job: 'j1' }]);
    const begin = callsOf('report_job_begin')[0];
    expect(begin.p_job).toBe('j1');
    expect(begin.p_filename).toBe('club-a-2026-11-14-full-final.pdf');
    expect(sends.map((s) => s.to)).toEqual(['a1@club.example', 'a2@club.example']);
    expect(finishes()).toEqual([['sent', null]]);
  });

  it('the PDF is the app\'s report, in the club\'s time zone, with the right name and size, and the address list is the database\'s, never the request\'s', async () => {
    replies.report_job_data = () => ({ data: { ...dataOf(NIGHT), time_zone: 'America/Toronto' }, error: null });
    await runReportJobs(deps());
    const pdf = Buffer.from(sends[0].pdf, 'base64');
    expect(pdf.subarray(0, 5).toString()).toBe('%PDF-');
    expect(sends[0].pdf.startsWith('JVBERi0')).toBe(true);
    expect(callsOf('report_job_begin')[0].p_bytes).toBe(pdf.length);
    expect(sends[0].filename).toBe('club-a-2026-11-14-full-final.pdf');
    const text = pdfText(pdf);
    expect(text).toContain('Nightly report');
    expect(text).toContain('Club A - Saturday Nov 14');
    expect(text).toContain('FINAL - closed 22:12 by Mia Manager');
    expect(sends.every((s) => s.pdf === sends[0].pdf)).toBe(true);
  });

  it('the e-mail is the fixed one, says it was sent automatically, names the report from the database\'s names, and never names a person', async () => {
    await runReportJobs(deps());
    const mail = sends[0];
    expect(mail.subject).toBe('A report from BottlesUp Business');
    expect(mail.text).toContain('Club A: the night report, Saturday, November 14, 2026');
    expect(mail.text).toContain('Sent automatically by BottlesUp Business when the night was closed');
    expect(mail.text).not.toContain('Sent by ');
    expect(mail.html).toContain('Sent automatically by BottlesUp Business');
    expect(mail.html).not.toMatch(/Sent by /);
  });

  it('the log is written with what the provider said for each address', async () => {
    sendResult = (to) => (to === 'a1@club.example' ? { sent: true } : { sent: false, reason: 'send_failed' });
    await runReportJobs(deps());
    expect(callsOf('report_send_finish')).toEqual([{ p_results: [{ id: 'd1', ok: true }, { id: 'd2', ok: false, error: 'the e-mail provider did not accept the message' }] }]);
    expect(finishes()).toEqual([['sent', null]]);
  });

  it('a provider that is not configured is said so in the log', async () => {
    sendResult = () => ({ sent: false, reason: 'not_configured' });
    await runReportJobs(deps());
    expect(callsOf('report_send_finish')[0].p_results).toEqual([{ id: 'd1', ok: false, error: 'the e-mail provider is not configured' }, { id: 'd2', ok: false, error: 'the e-mail provider is not configured' }]);
  });

  it('a send that throws is a failed address, and the rest are still sent', async () => {
    let n = 0;
    sendResult = () => {
      n += 1;
      if (n === 1) throw new Error('network');
      return { sent: true };
    };
    await runReportJobs(deps());
    expect(sends).toHaveLength(2);
    expect(callsOf('report_send_finish')[0].p_results).toEqual([{ id: 'd1', ok: false, error: 'the e-mail provider did not accept the message' }, { id: 'd2', ok: true }]);
    expect(finishes()).toEqual([['sent', null]]);
  });

  it('when no address accepted it, the job fails with a sentence that points to Send again (nothing is retried: the others would get a second copy)', async () => {
    sendResult = () => ({ sent: false, reason: 'send_failed' });
    const summary = await runReportJobs(deps());
    expect(finishes()).toEqual([['failed', 'The e-mail provider did not accept the message. Use Send again.']]);
    expect(summary.failed).toBe(1);
    expect(sends).toHaveLength(2);
  });

  it('a log that cannot be written does not undo the send', async () => {
    replies.report_send_finish = () => ({ data: null, error: { message: 'down' } });
    const summary = await runReportJobs(deps());
    expect(summary.sent).toBe(1);
    expect(finishes()).toEqual([['sent', null]]);
  });

  it('an unusable row (no id, no address, no business) is not sent to', async () => {
    replies.report_job_begin = () => ({ data: [ROWS[0], { delivery_id: 'x', email: null, org_name: 'Club Co' }, { delivery_id: null, email: 'b@x.example', org_name: 'Club Co' }, { delivery_id: 'y', email: 'c@x.example', org_name: null }, 'junk'], error: null });
    await runReportJobs(deps());
    expect(sends.map((s) => s.to)).toEqual(['a1@club.example']);
  });

  it('when no row of the list could be used, nothing is sent and the job is NOT called sent', async () => {
    replies.report_job_begin = () => ({ data: [{ delivery_id: 'x', email: null, org_name: 'Club Co' }, 'junk'], error: null });
    const summary = await runReportJobs(deps());
    expect(sends).toHaveLength(0);
    expect(finishes()).toEqual([['failed', 'The list of addresses could not be read.']]);
    expect(summary.failed).toBe(1);
    expect(callsOf('report_send_finish')).toHaveLength(0);
  });

  it('the owner\'s combined report and an organizer\'s event report go out the same way, each named from its own data', async () => {
    replies.report_job_claim = () => ({ data: [job('owner_combined', { venue_id: null }), job('organizer_sales', { job_id: 'j2', venue_id: null, event_id: 'e1', report_ref: 'e1' })], error: null });
    replies.report_job_data = (a) => ({ data: a.p_job === 'j1' ? dataOf(OWNER) : { ...dataOf(EVENT), ref: 'e1' }, error: null });
    replies.report_job_begin = (a) => ({
      data: a.p_job === 'j1' ? [{ delivery_id: 'd1', email: 'owner@club.example', org_name: 'Club Co', venue_name: null, event_title: null }] : [{ delivery_id: 'd9', email: 'org@events.example', org_name: 'Night Events', venue_name: null, event_title: 'Night One' }],
      error: null,
    });
    const summary = await runReportJobs(deps());
    expect(summary.sent).toBe(2);
    expect(callsOf('report_job_begin').map((a) => a.p_filename)).toEqual(['club-co-all-venues-2026-11-14-final.pdf', 'night-one-event-report.pdf']);
    expect(sends[0].text).toContain('Club Co: the combined report for every club');
    expect(sends[1].text).toContain('Night Events: the event report for Night One');
    expect(pdfText(Buffer.from(sends[0].pdf, 'base64'))).toContain('All venues');
    expect(pdfText(Buffer.from(sends[1].pdf, 'base64'))).toContain('Event report');
  });

  it('a limit can be given', async () => {
    await runReportJobs(deps(), 7);
    expect(callsOf('report_job_claim')).toEqual([{ p_limit: 7 }]);
  });

  it('nothing queued is nothing done', async () => {
    replies.report_job_claim = () => ({ data: [], error: null });
    expect(await runReportJobs(deps())).toEqual({ claimed: 0, sent: 0, skipped: 0, failed: 0, retried: 0 });
    expect(calls).toHaveLength(1);
  });
});

describe('what the database refuses', () => {
  const outcomeFor = async (fn: 'report_job_data' | 'report_job_begin', message: string) => {
    replies[fn] = () => ({ data: null, error: { message } });
    calls = [];
    sends = [];
    await runReportJobs(deps());
    return finishes()[0];
  };

  it('a person who has lost access: it fails, saying who should switch it on again, and nothing is sent', async () => {
    expect(await outcomeFor('report_job_data', 'not allowed')).toEqual(['failed', 'The person who switched it on no longer has access. Switch it on again.']);
    expect(sends).toHaveLength(0);
    expect(callsOf('report_job_begin')).toHaveLength(0);
  });
  it('a switch that was turned off: skipped, not an error', async () => {
    expect(await outcomeFor('report_job_data', 'automatic sending was switched off')).toEqual(['skipped', 'Automatic sending was switched off.']);
  });
  it('nobody to act as: it fails', async () => {
    expect(await outcomeFor('report_job_data', 'nobody is set to send it')).toEqual(['failed', 'The person who switched it on is no longer here. Switch it on again.']);
  });
  it('a problem the database words oddly is tried again, with a sentence that does not leak the message', async () => {
    expect(await outcomeFor('report_job_data', 'relation "x" does not exist')).toEqual(['retry', 'The report could not be prepared.']);
  });
  it('a list with nobody on it: skipped, with the sentence that says what to do', async () => {
    expect(await outcomeFor('report_job_begin', 'no one is set to receive this report: add an e-mail address first')).toEqual(['skipped', 'No one is set to receive it. Add an e-mail address first.']);
    expect(sends).toHaveLength(0);
  });
  it('the hourly limit: tried again later', async () => {
    expect(await outcomeFor('report_job_begin', 'too many reports sent this hour: try again later')).toEqual(['retry', 'Too many reports were sent this hour.']);
  });
  it('lost access at the second step: it fails too', async () => {
    expect(await outcomeFor('report_job_begin', 'not allowed')).toEqual(['failed', 'The person who switched it on no longer has access. Switch it on again.']);
  });
  it('a switch turned off at the second step: skipped', async () => {
    expect(await outcomeFor('report_job_begin', 'automatic sending was switched off')).toEqual(['skipped', 'Automatic sending was switched off.']);
  });
  it('a report too large, or a name the log refuses: it fails (trying again would not help)', async () => {
    expect(await outcomeFor('report_job_begin', 'this report is too large to e-mail (5 MB at most)')).toEqual(['failed', 'The report is too large to e-mail.']);
    expect(await outcomeFor('report_job_begin', 'the file name must end in .pdf and use only letters')).toEqual(['failed', 'The report has an unusable file name.']);
  });
  it('no rows back at all is a skip', async () => {
    replies.report_job_begin = () => ({ data: [], error: null });
    await runReportJobs(deps());
    expect(finishes()).toEqual([['skipped', 'No one is set to receive it. Add an e-mail address first.']]);
    replies.report_job_begin = () => ({ data: null, error: null });
    calls = [];
    await runReportJobs(deps());
    expect(finishes()).toEqual([['skipped', 'No one is set to receive it. Add an e-mail address first.']]);
  });
});

describe('what cannot be made', () => {
  it('data that cannot be read as a report fails without asking for a log', async () => {
    replies.report_job_data = () => ({ data: { kind: 'venue_night', report: { view: 'full' } }, error: null });
    await runReportJobs(deps());
    expect(finishes()).toEqual([['failed', 'The report could not be read.']]);
    expect(callsOf('report_job_begin')).toHaveLength(0);
    replies.report_job_data = () => ({ data: null, error: null });
    calls = [];
    await runReportJobs(deps());
    expect(finishes()).toEqual([['failed', 'The report could not be read.']]);
  });
  it('an e-mail provider that is not set up waits (nothing is written to the log first)', async () => {
    configured = false;
    const summary = await runReportJobs(deps());
    expect(finishes()).toEqual([['retry', 'The e-mail provider is not configured.']]);
    expect(summary.retried).toBe(1);
    expect(callsOf('report_job_begin')).toHaveLength(0);
    expect(sends).toHaveLength(0);
  });
  it('a PDF that cannot be drawn is tried again', async () => {
    vi.mocked(buildReportPdf).mockRejectedValueOnce(new Error('font'));
    await runReportJobs(deps());
    expect(finishes()).toEqual([['retry', 'The PDF could not be made.']]);
    expect(callsOf('report_job_begin')).toHaveLength(0);
  });
  it('a PDF too large to e-mail fails (it would be refused anyway)', async () => {
    vi.mocked(buildReportPdf).mockResolvedValueOnce(new Uint8Array(5 * 1024 * 1024 + 1));
    await runReportJobs(deps());
    expect(finishes()).toEqual([['failed', 'The report is too large to e-mail.']]);
    expect(callsOf('report_job_begin')).toHaveLength(0);
  });
  it('a PDF of exactly the largest size that can be e-mailed is sent', async () => {
    vi.mocked(buildReportPdf).mockResolvedValueOnce(new Uint8Array(5 * 1024 * 1024));
    await runReportJobs(deps());
    expect(finishes()).toEqual([['sent', null]]);
    expect(callsOf('report_job_begin')[0].p_bytes).toBe(5 * 1024 * 1024);
  });
  it('a job whose id is not text (a number, an object) is not worked on either', async () => {
    replies.report_job_claim = () => ({ data: [job('venue_night', { job_id: 5 }), job('venue_night', { job_id: { x: 1 } }), job('venue_night', { job_id: '' })], error: null });
    await runReportJobs(deps());
    expect(callsOf('report_job_data')).toHaveLength(0);
    expect(callsOf('report_job_finish')).toHaveLength(0);
  });
  it('a job with no id, kind or night is not worked on', async () => {
    replies.report_job_claim = () => ({ data: [job('venue_night', { job_id: null }), job('venue_night', { kind: null }), job('venue_night', { job_id: 'j3', report_ref: null }), 'junk'], error: null });
    const summary = await runReportJobs(deps());
    expect(callsOf('report_job_data')).toHaveLength(0);
    expect(finishes()).toEqual([['failed', 'The job could not be read.'], ['failed', 'The job could not be read.']]);
    expect(summary.claimed).toBe(4);
  });
  it('a call that throws is a try again, and the next job is still worked on', async () => {
    replies.report_job_claim = () => ({ data: [job('venue_night', { job_id: 'j1' }), job('venue_night', { job_id: 'j2' })], error: null });
    let n = 0;
    replies.report_job_data = () => {
      n += 1;
      if (n === 1) throw new Error('timeout');
      return { data: dataOf(NIGHT), error: null };
    };
    const summary = await runReportJobs(deps());
    expect(finishes()).toEqual([['retry', 'The run stopped unexpectedly.'], ['sent', null]]);
    expect(summary).toEqual({ claimed: 2, sent: 1, skipped: 0, failed: 0, retried: 1 });
  });
});

describe('the run', () => {
  it('counts each ending by what the database says the job is now', async () => {
    replies.report_job_claim = () => ({ data: [job('venue_night', { job_id: 'a' }), job('venue_night', { job_id: 'b' }), job('venue_night', { job_id: 'c' }), job('venue_night', { job_id: 'd' })], error: null });
    const errors: Record<string, string | null> = { a: null, b: 'automatic sending was switched off', c: 'not allowed', d: 'relation x' };
    replies.report_job_data = (a) => (errors[String(a.p_job)] ? { data: null, error: { message: errors[String(a.p_job)]! } } : { data: dataOf(NIGHT), error: null });
    const summary = await runReportJobs(deps());
    expect(summary).toEqual({ claimed: 4, sent: 1, skipped: 1, failed: 1, retried: 1 });
  });
  it('trusts the status the database gives back (a retry that has used its tries is a failure)', async () => {
    replies.report_job_data = () => ({ data: null, error: { message: 'relation x' } });
    replies.report_job_finish = () => ({ data: 'failed', error: null });
    expect(await runReportJobs(deps())).toEqual({ claimed: 1, sent: 0, skipped: 0, failed: 1, retried: 0 });
  });
  it('a result that cannot be recorded does not stop the run', async () => {
    replies.report_job_finish = () => ({ data: null, error: { message: 'down' } });
    const summary = await runReportJobs(deps());
    expect(summary.sent).toBe(1);
  });
  it('a run that cannot take jobs fails loudly', async () => {
    replies.report_job_claim = () => ({ data: null, error: { message: 'down' } });
    await expect(runReportJobs(deps())).rejects.toThrow('report_job_claim failed');
  });
  it('the jobs are worked on one after another, each finished before the next begins', async () => {
    replies.report_job_claim = () => ({ data: [job('venue_night', { job_id: 'a' }), job('venue_night', { job_id: 'b' })], error: null });
    await runReportJobs(deps());
    expect(calls.map((c) => `${c[0]}:${c[1].p_job ?? ''}`).filter((c) => c.startsWith('report_job'))).toEqual([
      'report_job_claim:', 'report_job_data:a', 'report_job_begin:a', 'report_job_finish:a', 'report_job_data:b', 'report_job_begin:b', 'report_job_finish:b',
    ]);
  });
});
