import { beforeEach, describe, expect, it, vi } from 'vitest';

let env: Record<string, string | undefined> = {};
let sendCompOfferEmail: typeof import('../../supabase/functions/_shared/compOfferSender.ts').sendCompOfferEmail;
const fetchMock = vi.fn();
const LINK = 'https://bottlesupapp.com/claim/' + 'b'.repeat(64);

beforeEach(async () => {
  vi.restoreAllMocks();
  vi.spyOn(console, 'error').mockImplementation(() => {});
  vi.spyOn(console, 'warn').mockImplementation(() => {});
  fetchMock.mockReset();
  fetchMock.mockResolvedValue({ ok: true, status: 200 });
  vi.stubGlobal('fetch', fetchMock);
  env = { RESEND_API_KEY: 're_test_key' };
  (globalThis as any).Deno = { env: { get: (k: string) => env[k] } };
  ({ sendCompOfferEmail } = await import('../../supabase/functions/_shared/compOfferSender.ts'));
});

describe('the provider call', () => {
  it('sends one message to one address, using the key, with no attachment', async () => {
    const res = await sendCompOfferEmail('gina@x.example', 'A complimentary bottle for you', `<a href="${LINK}">x</a>`, LINK);
    expect(res).toEqual({ sent: true });
    expect(fetchMock).toHaveBeenCalledTimes(1);
    const [url, init] = fetchMock.mock.calls[0];
    expect(url).toBe('https://api.resend.com/emails');
    expect(init.method).toBe('POST');
    expect(init.headers.Authorization).toBe('Bearer re_test_key');
    const sent = JSON.parse(init.body);
    expect(sent).toMatchObject({ from: 'tickets@bottlesupapp.com', to: 'gina@x.example', subject: 'A complimentary bottle for you' });
    expect(sent.text).toBe(LINK);
    expect(sent.attachments).toBeUndefined();
  });

  it('uses the configured sender address when there is one', async () => {
    env.TICKETS_FROM_EMAIL = 'hello@club.example';
    await sendCompOfferEmail('gina@x.example', 's', 'h', 't');
    expect(JSON.parse(fetchMock.mock.calls[0][1].body).from).toBe('hello@club.example');
  });
});

describe('when it cannot send', () => {
  it('without a key it says "not configured" and calls nothing', async () => {
    delete env.RESEND_API_KEY;
    expect(await sendCompOfferEmail('gina@x.example', 's', 'h', 't')).toEqual({ sent: false, reason: 'not_configured' });
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it('when the provider refuses it says "send failed", never the provider\'s words', async () => {
    fetchMock.mockResolvedValue({ ok: false, status: 422, text: async () => 'gina@x.example is not a valid address' });
    expect(await sendCompOfferEmail('gina@x.example', 's', 'h', 't')).toEqual({ sent: false, reason: 'send_failed' });
  });

  it('when the network fails it says "send failed"', async () => {
    fetchMock.mockRejectedValue(new Error('connection reset'));
    expect(await sendCompOfferEmail('gina@x.example', 's', 'h', 't')).toEqual({ sent: false, reason: 'send_failed' });
  });

  it('never logs the link or the address', async () => {
    const error = vi.spyOn(console, 'error');
    const warn = vi.spyOn(console, 'warn');
    fetchMock.mockResolvedValue({ ok: false, status: 500 });
    await sendCompOfferEmail('gina@x.example', 's', `<a href="${LINK}">x</a>`, LINK);
    delete env.RESEND_API_KEY;
    await sendCompOfferEmail('gina@x.example', 's', 'h', LINK);
    const logged = JSON.stringify([...error.mock.calls, ...warn.mock.calls]);
    expect(logged).not.toContain('b'.repeat(64));
    expect(logged).not.toContain('gina@x.example');
  });
});
