import { beforeEach, describe, expect, it, vi } from 'vitest';
import { base64Bytes, MAX_BASE64_CHARS, MAX_PDF_BYTES, sendReport, type Deps } from '../../supabase/functions/_shared/reportEmail.ts';
import { buildReportEmail, describeReport, nightLabel, REPORT_SUBJECT } from '../../supabase/functions/_shared/reportEmailTemplate.ts';

const ORG = '11111111-1111-4111-8111-111111111111';
const VENUE = '22222222-2222-4222-8222-222222222222';
const EVENT = '33333333-3333-4333-8333-333333333333';

const pdfOf = (bytes: number) => Buffer.concat([Buffer.from('%PDF-1.4\n'), Buffer.alloc(Math.max(bytes - 9, 0), 0x20)]).toString('base64');
const PDF = pdfOf(2000);

const rows = [
  { delivery_id: 'd1', batch_id: 'b1', email: 'boss@club.example', org_name: 'Club Co', venue_name: 'Club A', event_title: null },
  { delivery_id: 'd2', batch_id: 'b1', email: 'accountant@club.example', org_name: 'Club Co', venue_name: 'Club A', event_title: null },
];

const base = { kind: 'venue_night', orgId: ORG, venueId: VENUE, ref: '2026-10-30', filename: 'night-2026-10-30.pdf', pdfBase64: PDF };

let rpcUser: ReturnType<typeof vi.fn>;
let rpcService: ReturnType<typeof vi.fn>;
let send: ReturnType<typeof vi.fn>;
const deps = (over: Partial<Deps> = {}): Deps => ({
  senderEmail: 'manager@club.example', rpcUser: rpcUser as Deps['rpcUser'], rpcService: rpcService as Deps['rpcService'], send: send as Deps['send'], ...over,
});

beforeEach(() => {
  vi.restoreAllMocks();
  vi.spyOn(console, 'error').mockImplementation(() => {});
  rpcUser = vi.fn(async () => ({ data: rows, error: null }));
  rpcService = vi.fn(async () => ({ data: 2, error: null }));
  send = vi.fn(async () => ({ sent: true }));
});

describe('who may ask, and what must be there', () => {
  it('needs a signed-in caller, before anything else', async () => {
    const out = await sendReport(base, deps({ senderEmail: null }));
    expect(out.status).toBe(401);
    expect(rpcUser).not.toHaveBeenCalled();
    expect(send).not.toHaveBeenCalled();
  });

  it.each([
    ['an unknown kind of report', { ...base, kind: 'everything' }],
    ['no business', { ...base, orgId: undefined }],
    ['a business that is not an id', { ...base, orgId: 'club' }],
    ['a club that is not an id', { ...base, venueId: '1; drop table' }],
    ['an event that is not an id', { ...base, eventId: 7 }],
    ['no report name', { ...base, ref: '' }],
    ['no file name', { ...base, filename: undefined }],
  ])('says which report it needs (%s) and asks the database nothing', async (_name, body) => {
    const out = await sendReport(body, deps());
    expect(out.status).toBe(400);
    expect(out.body).toEqual({ error: 'Say which report this is.' });
    expect(rpcUser).not.toHaveBeenCalled();
  });

  it('refuses a body that is not an object', async () => {
    expect((await sendReport(null, deps())).status).toBe(400);
    expect((await sendReport('report', deps())).status).toBe(400);
    expect(rpcUser).not.toHaveBeenCalled();
  });
});

describe('the PDF', () => {
  it('must be there', async () => {
    expect((await sendReport({ ...base, pdfBase64: '' }, deps())).body).toEqual({ error: 'The report is empty.' });
    expect((await sendReport({ ...base, pdfBase64: undefined }, deps())).status).toBe(400);
    expect(rpcUser).not.toHaveBeenCalled();
  });

  it('must be a PDF, whatever the file is called', async () => {
    const out = await sendReport({ ...base, pdfBase64: Buffer.from('MZ not a pdf, an exe').toString('base64') }, deps());
    expect(out).toEqual({ status: 400, body: { error: 'That is not a PDF.' } });
    expect(rpcUser).not.toHaveBeenCalled();
  });

  it('must be clean base64', async () => {
    expect((await sendReport({ ...base, pdfBase64: PDF + '!!' }, deps())).status).toBe(400);
    expect((await sendReport({ ...base, pdfBase64: PDF.slice(0, -1) }, deps())).status).toBe(400);
    expect((await sendReport({ ...base, pdfBase64: PDF + '\n' }, deps())).status).toBe(400);
    // right length, wrong characters
    expect((await sendReport({ ...base, pdfBase64: PDF.slice(0, -4) + '!!!!' }, deps())).body).toEqual({ error: 'That is not a PDF.' });
    expect((await sendReport({ ...base, pdfBase64: PDF.slice(0, -4) + 'A A=' }, deps())).status).toBe(400);
    expect(rpcUser).not.toHaveBeenCalled();
  });

  it('may be exactly 5 MB and no more', async () => {
    expect(MAX_PDF_BYTES).toBe(5242880);
    const exactly = pdfOf(5242880);
    expect(base64Bytes(exactly)).toBe(5242880);
    expect(exactly.length).toBeLessThanOrEqual(MAX_BASE64_CHARS);
    expect((await sendReport({ ...base, pdfBase64: exactly }, deps())).status).toBe(200);
    expect(rpcUser.mock.calls[0][1].p_bytes).toBe(5242880);

    rpcUser.mockClear();
    const over = pdfOf(5242881);
    const out = await sendReport({ ...base, pdfBase64: over }, deps());
    expect(out.status).toBe(413);
    expect(rpcUser).not.toHaveBeenCalled();
  });

  it('is refused by length before it is even looked at when it is huge', async () => {
    const out = await sendReport({ ...base, pdfBase64: 'JVBERi0' + 'A'.repeat(MAX_BASE64_CHARS) }, deps());
    expect(out.status).toBe(413);
    expect(rpcUser).not.toHaveBeenCalled();
  });

  it('is measured without decoding it', () => {
    expect(base64Bytes(Buffer.from('abc').toString('base64'))).toBe(3);
    expect(base64Bytes(Buffer.from('abcd').toString('base64'))).toBe(4);
    expect(base64Bytes(Buffer.from('abcde').toString('base64'))).toBe(5);
  });
});

describe('the database decides who gets it', () => {
  it('asks as the caller, with the report and its size, and no address', async () => {
    await sendReport({ ...base, eventId: null }, deps());
    expect(rpcUser).toHaveBeenCalledTimes(1);
    expect(rpcUser.mock.calls[0][0]).toBe('report_send_begin');
    expect(rpcUser.mock.calls[0][1]).toEqual({
      p_kind: 'venue_night', p_org: ORG, p_venue: VENUE, p_event: null, p_ref: '2026-10-30', p_filename: 'night-2026-10-30.pdf', p_bytes: base64Bytes(PDF), p_only_failed: false,
    });
    expect(rpcService).not.toHaveBeenCalledWith('report_send_begin', expect.anything());
  });

  it('passes "send again" through, and only when it is exactly true', async () => {
    await sendReport({ ...base, again: true }, deps());
    expect(rpcUser.mock.calls[0][1].p_only_failed).toBe(true);
    rpcUser.mockClear();
    await sendReport({ ...base, again: 'yes' }, deps());
    expect(rpcUser.mock.calls[0][1].p_only_failed).toBe(false);
  });

  it('ignores any address the request carries: it only writes to the addresses the database returns', async () => {
    await sendReport({ ...base, to: 'victim@elsewhere.example', recipients: ['victim@elsewhere.example'], email: 'victim@elsewhere.example' }, deps());
    const to = send.mock.calls.map((c) => c[0]);
    expect(to).toEqual(['boss@club.example', 'accountant@club.example']);
    expect(JSON.stringify(rpcUser.mock.calls)).not.toContain('victim');
  });

  it.each([
    ['not allowed', 403, 'You cannot e-mail this report.'],
    ['too many reports sent this hour: try again later', 429, 'Too many reports were sent this hour. Try again later.'],
    ['no one is set to receive this report: add an e-mail address first', 409, 'No one is set to receive this report. Add an e-mail address first.'],
    ['there is nothing to send again', 409, 'There is nothing to send again: every address already got this report.'],
    ['this report is too large to e-mail (5 MB at most)', 413, 'This report is too large to e-mail.'],
    ['say which night this report is for', 400, 'Say which report this is.'],
    ['say which report this is', 400, 'Say which report this is.'],
    ['the file name must end in .pdf and use only letters', 400, 'The report has an unusable file name.'],
    ['the report is empty', 400, 'The report is empty.'],
  ])('turns "%s" into a status and a sentence, and sends nothing', async (message, status, sentence) => {
    rpcUser.mockResolvedValue({ data: null, error: { message } });
    const out = await sendReport(base, deps());
    expect(out).toEqual({ status, body: { error: sentence } });
    expect(send).not.toHaveBeenCalled();
    expect(rpcService).not.toHaveBeenCalled();
  });

  it('hides anything it does not expect', async () => {
    rpcUser.mockResolvedValue({ data: null, error: { message: 'relation "site_report_recipients" does not exist' } });
    const out = await sendReport(base, deps());
    expect(out).toEqual({ status: 500, body: { error: 'Could not send the report.' } });
    expect(JSON.stringify(out)).not.toContain('relation');
    expect(send).not.toHaveBeenCalled();
  });

  it('treats an empty answer as a failure rather than a success', async () => {
    rpcUser.mockResolvedValue({ data: [], error: null });
    expect((await sendReport(base, deps())).status).toBe(500);
    rpcUser.mockResolvedValue({ data: null, error: null });
    expect((await sendReport(base, deps())).status).toBe(500);
    expect(send).not.toHaveBeenCalled();
  });
});

describe('sending', () => {
  it('sends one e-mail to each address with the fixed subject and the PDF attached', async () => {
    const out = await sendReport(base, deps());
    expect(out.status).toBe(200);
    expect(send).toHaveBeenCalledTimes(2);
    for (const call of send.mock.calls) {
      expect(call[1]).toBe(REPORT_SUBJECT);
      expect(call[4]).toEqual({ filename: 'night-2026-10-30.pdf', contentBase64: PDF });
      expect(call[3]).toContain('Club A: the night report, Friday, October 30, 2026.');
      expect(call[3]).toContain('Sent by manager@club.example');
    }
    expect(send.mock.calls.map((c) => c[0])).toEqual(['boss@club.example', 'accountant@club.example']);
  });

  it('names the event for an organizer\'s report', async () => {
    rpcUser.mockResolvedValue({ data: [{ ...rows[0], venue_name: null, event_title: 'Halloween Night', org_name: 'Night Events' }], error: null });
    await sendReport({ ...base, kind: 'organizer_sales', venueId: null, eventId: EVENT, ref: EVENT }, deps());
    expect(send.mock.calls[0][3]).toContain('Night Events: the event report for Halloween Night.');
  });

  it('records what the provider said, once, with the service role, and never the PDF', async () => {
    send.mockResolvedValueOnce({ sent: true }).mockResolvedValueOnce({ sent: false, reason: 'send_failed' });
    const out = await sendReport(base, deps());
    expect(rpcService).toHaveBeenCalledTimes(1);
    expect(rpcService.mock.calls[0][0]).toBe('report_send_finish');
    expect(rpcService.mock.calls[0][1]).toEqual({ p_results: [{ id: 'd1', ok: true }, { id: 'd2', ok: false, error: 'the e-mail provider did not accept the message' }] });
    expect(JSON.stringify(rpcService.mock.calls)).not.toContain(PDF);
    expect(out.body).toEqual({ sent: 1, failed: 1, results: [{ email: 'boss@club.example', ok: true }, { email: 'accountant@club.example', ok: false }] });
  });

  it('says so when the e-mail provider is not set up', async () => {
    send.mockResolvedValue({ sent: false, reason: 'not_configured' });
    const out = await sendReport(base, deps());
    expect(rpcService.mock.calls[0][1].p_results.every((r: { error: string }) => r.error === 'the e-mail provider is not configured')).toBe(true);
    expect(out.body).toMatchObject({ sent: 0, failed: 2 });
  });

  it('keeps going when one address fails, even by throwing', async () => {
    send.mockRejectedValueOnce(new Error('socket hang up')).mockResolvedValueOnce({ sent: true });
    const out = await sendReport(base, deps());
    expect(send).toHaveBeenCalledTimes(2);
    expect(out.body).toMatchObject({ sent: 1, failed: 1 });
    expect(JSON.stringify(out)).not.toContain('socket');
  });

  it('still answers with what happened when the log cannot be written', async () => {
    rpcService.mockResolvedValue({ data: null, error: { message: 'boom' } });
    const out = await sendReport(base, deps());
    expect(out.status).toBe(200);
    expect(out.body).toMatchObject({ sent: 2, failed: 0 });
  });

  it('skips a row it cannot make sense of instead of sending something wrong', async () => {
    rpcUser.mockResolvedValue({ data: [{ delivery_id: 'd1', email: 'boss@club.example', org_name: null }, rows[1]], error: null });
    const out = await sendReport(base, deps());
    expect(send).toHaveBeenCalledTimes(1);
    expect(send.mock.calls[0][0]).toBe('accountant@club.example');
    expect(out.body).toMatchObject({ sent: 1, failed: 0 });
  });
});

describe('the e-mail itself', () => {
  const ctx = { kind: 'venue_night' as const, orgName: 'Club Co', venueName: 'Club A', eventTitle: null, ref: '2026-10-30', senderEmail: 'manager@club.example', filename: 'night.pdf' };

  it('has one fixed subject', () => {
    expect(REPORT_SUBJECT).toBe('A report from BottlesUp Business');
    expect(buildReportEmail(ctx).subject).toBe(REPORT_SUBJECT);
    expect(buildReportEmail({ ...ctx, orgName: 'X\r\nBcc: someone@else.example', venueName: 'Y\nInjected: 1' }).subject).toBe(REPORT_SUBJECT);
  });

  it('writes a night without a time zone moving it', () => {
    expect(nightLabel('2026-10-30')).toBe('Friday, October 30, 2026');
    expect(nightLabel('2026-01-01')).toBe('Thursday, January 1, 2026');
    expect(nightLabel('not a date')).toBe('not a date');
  });

  it('describes each kind of report', () => {
    expect(describeReport({ ...ctx, kind: 'owner_combined' })).toBe('Club Co: the combined report for every club, Friday, October 30, 2026');
    expect(describeReport(ctx)).toBe('Club A: the night report, Friday, October 30, 2026');
    expect(describeReport({ ...ctx, venueName: null })).toBe('Club Co: the night report, Friday, October 30, 2026');
    expect(describeReport({ ...ctx, kind: 'organizer_sales', venueName: null, eventTitle: 'Halloween' })).toBe('Club Co: the event report for Halloween');
    expect(describeReport({ ...ctx, kind: 'organizer_sales', venueName: null, eventTitle: null })).toBe('Club Co: the event report');
  });

  it('escapes everything a person typed, in the web version', () => {
    const mail = buildReportEmail({ ...ctx, orgName: '<script>alert(1)</script>', venueName: '"><img src=x>', senderEmail: 'a<b>@c.example', filename: '<b>.pdf' });
    const combined = buildReportEmail({ ...ctx, kind: 'owner_combined', orgName: '<script>alert(1)</script>' });
    for (const html of [mail.html, combined.html]) {
      expect(html).not.toContain('<script>');
      expect(html).not.toContain('<img');
    }
    expect(combined.html).toContain('&lt;script&gt;');
    expect(mail.html).not.toContain('<b>.pdf');
    expect(mail.html).toContain('&lt;b&gt;.pdf');
    expect(mail.html).toContain('&lt;img');
    expect(mail.html).not.toContain('a<b>');
  });

  it('keeps the plain-text version plain, on one line per sentence', () => {
    const mail = buildReportEmail({ ...ctx, orgName: 'Club\nCo', venueName: 'Club\r\nA' });
    expect(mail.text).toContain('Club A: the night report');
    expect(mail.text).not.toMatch(/<[a-z]/i);
  });
});
