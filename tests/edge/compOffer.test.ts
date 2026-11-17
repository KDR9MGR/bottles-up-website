import { beforeEach, describe, expect, it, vi } from 'vitest';
import { sendCompOffer, TOKEN, UUID, type Deps } from '../../supabase/functions/_shared/compOffer.ts';

// Sending a complimentary offer's claim link. What matters: only the offer's id is read from the request (no address, no text); the database decides, as the caller, whether they may send; the link
// is made with the service role only after that, e-mailed, never returned or logged; every way out records how the attempt ended, exactly once; the app is told only plain sentences.
const OFFER = '11111111-1111-4111-8111-111111111111';
const SEND = '22222222-2222-4222-8222-222222222222';
const TOKEN_VALUE = 'ab'.repeat(32);
const ROW = { send_id: SEND, venue_id: 'v', to_email: 'gina@x.example', to_name: 'Gina Guest', venue_name: 'Club A', event_title: null, item: 'Patron', quantity: 2, expires_at: '2026-11-25T02:00:00Z', time_zone: 'America/Toronto', first_send: true };

type Call = { who: 'user' | 'service' | 'send'; fn: string; args: unknown };
let calls: Call[];
let user: ReturnType<typeof vi.fn>;
let service: ReturnType<typeof vi.fn>;
let send: ReturnType<typeof vi.fn>;

const deps = (over: Partial<Deps> = {}): Deps => ({
  rpcUser: (fn, args) => { calls.push({ who: 'user', fn, args }); return user(fn, args); },
  rpcService: (fn, args) => { calls.push({ who: 'service', fn, args }); return service(fn, args); },
  send: (to, subject, html, text) => { calls.push({ who: 'send', fn: 'send', args: { to, subject, html, text } }); return send(to, subject, html, text); },
  siteUrl: 'https://bottlesupapp.com',
  ...over,
});
const run = (body: unknown = { offerId: OFFER }, over: Partial<Deps> = {}) => sendCompOffer(body, deps(over));
const finishCalls = () => calls.filter((c) => c.fn === 'comp_offer_send_finish');

beforeEach(() => {
  calls = [];
  vi.spyOn(console, 'error').mockImplementation(() => {});
  user = vi.fn(async () => ({ data: [ROW], error: null }));
  service = vi.fn(async (fn: string) => (fn === 'comp_offer_issue_link' ? { data: TOKEN_VALUE, error: null } : { data: true, error: null }));
  send = vi.fn(async () => ({ sent: true }));
});

describe('the request', () => {
  it('needs an offer id that is an id', async () => {
    for (const body of [null, 'x', 5, [], {}, { offerId: 5 }, { offerId: 'not-an-id' }, { offerId: OFFER + 'x' }, { offerId: '' }]) {
      const res = await run(body);
      expect(res.status, JSON.stringify(body)).toBe(400);
      expect(res.body).toEqual({ error: 'Say which offer to send.' });
    }
    expect((await sendCompOffer(undefined, deps())).status).toBe(400);
    expect(calls).toEqual([]);
  });

  it('reads nothing else from it: an address, a subject or a link in the body change nothing', async () => {
    await run({ offerId: OFFER, to: 'evil@x.example', email: 'evil@x.example', subject: 'hi', link: 'https://evil.example', token: 'x'.repeat(64) });
    expect(calls.find((c) => c.who === 'send')!.args).toMatchObject({ to: 'gina@x.example', subject: 'A complimentary bottle for you' });
    expect(JSON.stringify(calls.find((c) => c.who === 'send')!.args)).not.toContain('evil');
  });
});

describe('the database says no (it decides, as the caller)', () => {
  const refuse = (message: string) => { user = vi.fn(async () => ({ data: null, error: { message } })); };

  it.each([
    ['not allowed', 403, 'You cannot send this link.'],
    ['not authenticated', 401, 'Sign in again to send this link.'],
    ['a link cannot be sent for an offer that is expired', 409, 'A link cannot be sent for an offer that is expired.'],
    ['a link cannot be sent for an offer that is location submitted', 409, 'A link cannot be sent for an offer that is location submitted.'],
    ['this link was sent 5 times in the last day: wait before sending it again', 429, 'This link was sent 5 times in the last day: wait before sending it again.'],
    ['you have sent a lot of links this hour: wait before sending another', 429, 'You have sent a lot of links this hour: wait before sending another.'],
  ])('"%s" is %i with a plain sentence', async (message, status, sentence) => {
    refuse(message);
    const res = await run();
    expect(res.status).toBe(status);
    expect(res.body).toEqual({ error: sentence });
  });

  it('and then nothing happens: no link is made, nothing is sent, nothing is recorded', async () => {
    refuse('not allowed');
    await run();
    expect(calls.map((c) => c.fn)).toEqual(['comp_offer_send_begin']);
  });

  it('anything else is a generic failure that shows no database words', async () => {
    refuse('duplicate key value violates unique constraint "secret_index"');
    const res = await run();
    expect(res.status).toBe(500);
    expect(JSON.stringify(res.body)).not.toContain('secret_index');
    expect(res.body).toEqual({ error: 'The link could not be sent.' });
    expect(calls.length).toBe(1);
  });

  it('an answer that cannot be read is a failure before anything is made or sent', async () => {
    for (const data of [null, [], [{}], [{ ...ROW, send_id: 'x' }], [{ ...ROW, to_email: 5 }], [{ ...ROW, quantity: '2' }], [{ ...ROW, expires_at: null }], [{ ...ROW, item: null }], [{ ...ROW, venue_name: null }]]) {
      calls = [];
      user = vi.fn(async () => ({ data, error: null }));
      const res = await run();
      expect(res.status, JSON.stringify(data)).toBe(500);
      expect(calls.map((c) => c.fn)).toEqual(['comp_offer_send_begin']);
    }
  });
});

describe('a send that goes', () => {
  it('asks as the caller, makes the link as the service, sends, then records, in that order', async () => {
    const res = await run();
    expect(res).toEqual({ status: 200, body: { sent: true } });
    expect(calls.map((c) => `${c.who}:${c.fn}`)).toEqual(['user:comp_offer_send_begin', 'service:comp_offer_issue_link', 'send:send', 'service:comp_offer_send_finish']);
    expect(calls[0].args).toEqual({ p_offer: OFFER });
    expect(calls[1].args).toEqual({ p_offer: OFFER });
    expect(calls[3].args).toEqual({ p_send: SEND, p_ok: true, p_why: null });
  });

  it('e-mails the address the database gave, with the link in it', async () => {
    await run();
    const sent = calls.find((c) => c.who === 'send')!.args as { to: string; html: string; text: string };
    expect(sent.to).toBe('gina@x.example');
    expect(sent.text).toContain(`https://bottlesupapp.com/claim/${TOKEN_VALUE}`);
    expect(sent.html).toContain(`href="https://bottlesupapp.com/claim/${TOKEN_VALUE}"`);
    expect(sent.text).toContain('Club A would like to give you 2 × Patron');
  });

  it('puts the club\'s own time in the e-mail', async () => {
    user = vi.fn(async () => ({ data: [{ ...ROW, time_zone: 'America/Los_Angeles' }], error: null }));
    await run();
    expect((calls.find((c) => c.who === 'send')!.args as { text: string }).text).toContain('6:00 PM PST');
  });

  it('never returns the link or the token, and never logs them', async () => {
    const res = await run();
    expect(JSON.stringify(res)).not.toContain(TOKEN_VALUE);
    expect(JSON.stringify((console.error as unknown as { mock: { calls: unknown[] } }).mock.calls)).not.toContain(TOKEN_VALUE);
  });

  it('builds the link from the site address however it is written', async () => {
    await run({ offerId: OFFER }, { siteUrl: 'https://www.bottlesupapp.com///' });
    expect((calls.find((c) => c.who === 'send')!.args as { text: string }).text).toContain(`https://www.bottlesupapp.com/claim/${TOKEN_VALUE}`);
  });

  it('a site address that is not https sends nothing and records a failure', async () => {
    const res = await run({ offerId: OFFER }, { siteUrl: 'http://bottlesupapp.com' });
    expect(res.status).toBe(500);
    expect(calls.some((c) => c.who === 'send')).toBe(false);
    expect(finishCalls().map((c) => c.args)).toEqual([{ p_send: SEND, p_ok: false, p_why: 'send_failed' }]);
  });
});

describe('a send that does not', () => {
  it.each([
    [{ sent: false, reason: 'not_configured' }, 'not_configured'],
    [{ sent: false, reason: 'send_failed' }, 'send_failed'],
    [{ sent: false }, 'send_failed'],
  ])('%j is told as "%s", and recorded', async (result, reason) => {
    send = vi.fn(async () => result);
    const res = await run();
    expect(res).toEqual({ status: 200, body: { sent: false, reason } });
    expect(finishCalls().map((c) => c.args)).toEqual([{ p_send: SEND, p_ok: false, p_why: reason }]);
  });

  it('a sender that throws is "send failed"', async () => {
    send = vi.fn(async () => { throw new Error('socket closed'); });
    const res = await run();
    expect(res).toEqual({ status: 200, body: { sent: false, reason: 'send_failed' } });
    expect(finishCalls().map((c) => c.args)).toEqual([{ p_send: SEND, p_ok: false, p_why: 'send_failed' }]);
  });

  it('a link that could not be made records the failure and sends nothing', async () => {
    service = vi.fn(async (fn: string) => (fn === 'comp_offer_issue_link' ? { data: null, error: { message: 'boom' } } : { data: true, error: null }));
    const res = await run();
    expect(res).toEqual({ status: 500, body: { error: 'The link could not be sent.' } });
    expect(calls.some((c) => c.who === 'send')).toBe(false);
    expect(finishCalls().map((c) => c.args)).toEqual([{ p_send: SEND, p_ok: false, p_why: 'send_failed' }]);
  });

  it('a link the database refuses to make (the offer changed meanwhile) is told plainly', async () => {
    service = vi.fn(async (fn: string) => (fn === 'comp_offer_issue_link' ? { data: null, error: { message: 'a link cannot be issued for an offer that is cancelled' } } : { data: true, error: null }));
    const res = await run();
    expect(res).toEqual({ status: 409, body: { error: 'A link cannot be issued for an offer that is cancelled.' } });
    expect(finishCalls().length).toBe(1);
    expect(calls.some((c) => c.who === 'send')).toBe(false);
  });

  it('a token that is not a token is never put in an e-mail', async () => {
    for (const data of ['short', 'ZZ'.repeat(32), 123, null, `${TOKEN_VALUE}x`]) {
      calls = [];
      service = vi.fn(async (fn: string) => (fn === 'comp_offer_issue_link' ? { data, error: null } : { data: true, error: null }));
      const res = await run();
      expect(res.status, String(data)).toBe(500);
      expect(calls.some((c) => c.who === 'send'), String(data)).toBe(false);
      expect(finishCalls().length).toBe(1);
    }
  });

  it('if recording the result fails the person is still told what happened, and nothing is logged with the link', async () => {
    service = vi.fn(async (fn: string) => (fn === 'comp_offer_issue_link' ? { data: TOKEN_VALUE, error: null } : { data: null, error: { message: 'down' } }));
    const res = await run();
    expect(res).toEqual({ status: 200, body: { sent: true } });
    expect(JSON.stringify((console.error as unknown as { mock: { calls: unknown[] } }).mock.calls)).not.toContain(TOKEN_VALUE);
  });
});

describe('who calls what', () => {
  it('only the caller\'s session is used for the question, and only the service role for the link and the record', async () => {
    await run();
    expect(calls.filter((c) => c.who === 'user').map((c) => c.fn)).toEqual(['comp_offer_send_begin']);
    expect(calls.filter((c) => c.who === 'service').map((c) => c.fn)).toEqual(['comp_offer_issue_link', 'comp_offer_send_finish']);
  });

  it('every attempt that began is finished exactly once, whichever way it ends', async () => {
    for (const variant of ['ok', 'refused-send', 'throws', 'no-link', 'bad-token']) {
      calls = [];
      send = vi.fn(async () => (variant === 'refused-send' ? { sent: false, reason: 'send_failed' } : variant === 'throws' ? Promise.reject(new Error('x')) : { sent: true }));
      service = vi.fn(async (fn: string) => (fn === 'comp_offer_issue_link' ? (variant === 'no-link' ? { data: null, error: { message: 'x' } } : { data: variant === 'bad-token' ? 'zz' : TOKEN_VALUE, error: null }) : { data: true, error: null }));
      await run();
      expect(finishCalls().length, variant).toBe(1);
    }
  });
});

describe('the shapes', () => {
  it('an id is 36 characters, a token is 64 hex characters', () => {
    expect(UUID.test(OFFER)).toBe(true);
    expect(UUID.test('1111')).toBe(false);
    expect(TOKEN.test(TOKEN_VALUE)).toBe(true);
    expect(TOKEN.test(TOKEN_VALUE.slice(1))).toBe(false);
    expect(TOKEN.test(TOKEN_VALUE.toUpperCase())).toBe(false);
  });
});
