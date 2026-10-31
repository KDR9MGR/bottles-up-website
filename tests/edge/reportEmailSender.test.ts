import { beforeEach, describe, expect, it, vi } from 'vitest';

let env: Record<string, string | undefined> = {};
let sendReportEmail: typeof import('../../supabase/functions/_shared/reportEmailSender.ts').sendReportEmail;
const fetchMock = vi.fn();

const ATTACHMENT = { filename: 'night.pdf', contentBase64: 'JVBERi0xLjQK' };

beforeEach(async () => {
  vi.restoreAllMocks();
  vi.spyOn(console, 'error').mockImplementation(() => {});
  vi.spyOn(console, 'warn').mockImplementation(() => {});
  fetchMock.mockReset();
  fetchMock.mockResolvedValue({ ok: true, status: 200 });
  vi.stubGlobal('fetch', fetchMock);
  env = { RESEND_API_KEY: 're_test_key' };
  (globalThis as any).Deno = { env: { get: (k: string) => env[k] } };
  ({ sendReportEmail } = await import('../../supabase/functions/_shared/reportEmailSender.ts'));
});

describe('the provider call', () => {
  it('sends one message to one address with the PDF attached, using the key', async () => {
    const res = await sendReportEmail('boss@club.example', 'A report', '<p>x</p>', 'x', ATTACHMENT);
    expect(res).toEqual({ sent: true });
    expect(fetchMock).toHaveBeenCalledTimes(1);
    const [url, init] = fetchMock.mock.calls[0];
    expect(url).toBe('https://api.resend.com/emails');
    expect(init.method).toBe('POST');
    expect(init.headers.Authorization).toBe('Bearer re_test_key');
    const sent = JSON.parse(init.body);
    expect(sent).toMatchObject({ to: 'boss@club.example', subject: 'A report', html: '<p>x</p>', text: 'x' });
    expect(sent.attachments).toEqual([{ filename: 'night.pdf', content: 'JVBERi0xLjQK' }]);
  });

  it('sends from the same address as the ticket e-mails, unless one is set', async () => {
    await sendReportEmail('a@b.cc', 's', 'h', 't', ATTACHMENT);
    expect(JSON.parse(fetchMock.mock.calls[0][1].body).from).toBe('tickets@bottlesupapp.com');
    env.TICKETS_FROM_EMAIL = 'BottlesUp <hello@bottlesupapp.com>';
    await sendReportEmail('a@b.cc', 's', 'h', 't', ATTACHMENT);
    expect(JSON.parse(fetchMock.mock.calls[1][1].body).from).toBe('BottlesUp <hello@bottlesupapp.com>');
  });

  it('says "not configured" without calling anyone when there is no key', async () => {
    delete env.RESEND_API_KEY;
    expect(await sendReportEmail('a@b.cc', 's', 'h', 't', ATTACHMENT)).toEqual({ sent: false, reason: 'not_configured' });
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it('says "send failed" when the provider refuses, and does not repeat what it said', async () => {
    fetchMock.mockResolvedValue({ ok: false, status: 422, text: async () => 'secret provider detail' });
    const res = await sendReportEmail('a@b.cc', 's', 'h', 't', ATTACHMENT);
    expect(res).toEqual({ sent: false, reason: 'send_failed' });
    expect(JSON.stringify(res)).not.toContain('secret');
  });

  it('says "send failed" when the request itself fails', async () => {
    fetchMock.mockRejectedValue(new Error('network down'));
    expect(await sendReportEmail('a@b.cc', 's', 'h', 't', ATTACHMENT)).toEqual({ sent: false, reason: 'send_failed' });
  });
});
