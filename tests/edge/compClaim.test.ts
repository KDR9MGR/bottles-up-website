import { beforeEach, describe, expect, it, vi } from 'vitest';
import { handleClaim, LINK_LIMIT, sha256Hex, VISITOR_LIMIT, WINDOW_SECONDS } from '../../supabase/functions/_shared/compClaim.ts';

// The public door of the complimentary claim page. What matters: every visit counts (against the visitor and against the link) before anything is looked up; a link that cannot be a link is "not
// found", the same as one that is not there; the page is told ONLY what it shows (never another guest, a booking, an address); a second claim changes nothing; the database's own words never reach it.
const TOKEN = 'cd'.repeat(32);
const TABLE = '33333333-3333-4333-8333-333333333333';
const FLOOR = '44444444-4444-4444-8444-444444444444';
const OPEN = {
  state: 'open', venue_name: 'Club A', event_title: 'Halloween Night', item: 'Patron', size: '750ml', quantity: 2, sign: 'Happy birthday Gina', recipient_name: 'Gina', expires_at: '2026-11-25T02:00:00Z',
  floors: [{ id: FLOOR, label: 'Main floor', image_url: 'https://cdn.example/floor.png' }],
  tables: [{ id: TABLE, name: 'Booth 1', floor_id: FLOOR, pos_x: 10, pos_y: 20, width: 5, height: 5 }],
};

type Call = { fn: string; args: Record<string, unknown> };
let calls: Call[];
let answers: Record<string, unknown>;
let throttle: boolean[];

const rpc = async (fn: string, args: Record<string, unknown>) => {
  calls.push({ fn, args });
  if (fn === 'comp_claim_throttle') {
    const ok = throttle.length ? throttle.shift()! : true;
    return { data: ok, error: null };
  }
  const a = answers[fn];
  return a instanceof Error ? { data: null, error: { message: a.message } } : { data: a, error: null };
};
const run = (body: unknown, visitor = 'v1') => handleClaim(body, { rpcService: rpc, visitor });
const called = (fn: string) => calls.filter((c) => c.fn === fn);

beforeEach(() => {
  calls = [];
  throttle = [];
  answers = { comp_claim_view: OPEN, comp_claim_submit: { state: 'submitted' } };
  vi.spyOn(console, 'error').mockImplementation(() => {});
});

describe('the request', () => {
  it('must be an object with an action of view or submit', async () => {
    for (const body of [null, undefined, 'x', 5, [], {}, { action: 'delete', token: TOKEN }, { action: '', token: TOKEN }, { token: TOKEN }]) {
      const res = await run(body);
      expect(res.status, JSON.stringify(body)).toBe(400);
      expect(res.body).toEqual({ error: 'Invalid request.' });
    }
    expect(calls).toEqual([]);
  });

  it('a submit must say which table, and it must be an id', async () => {
    for (const tableId of [undefined, null, 5, 'booth 1', TABLE + 'x', '']) {
      const res = await run({ action: 'submit', token: TOKEN, tableId });
      expect(res.status, String(tableId)).toBe(400);
      expect(res.body).toEqual({ error: 'Choose where you are.' });
    }
    expect(calls).toEqual([]);
  });
});

describe('every visit counts', () => {
  it('against the visitor and then against the link, in a window, before anything is looked up', async () => {
    await run({ action: 'view', token: TOKEN }, 'abc');
    expect(calls.map((c) => c.fn)).toEqual(['comp_claim_throttle', 'comp_claim_throttle', 'comp_claim_view']);
    expect(calls[0].args).toEqual({ p_key: 'ip:abc', p_limit: VISITOR_LIMIT, p_window_seconds: WINDOW_SECONDS });
    expect(calls[1].args).toEqual({ p_key: `link:${(await sha256Hex(TOKEN)).slice(0, 32)}`, p_limit: LINK_LIMIT, p_window_seconds: WINDOW_SECONDS });
  });

  it('the limits are 60 for a visitor and 30 for a link in ten minutes', () => {
    expect([VISITOR_LIMIT, LINK_LIMIT, WINDOW_SECONDS]).toEqual([60, 30, 600]);
  });

  it('the link itself is never a key (only its hash)', async () => {
    await run({ action: 'view', token: TOKEN });
    expect(JSON.stringify(called('comp_claim_throttle'))).not.toContain(TOKEN);
  });

  it('a visitor over the limit is told to wait, and nothing else is asked', async () => {
    throttle = [false];
    const res = await run({ action: 'view', token: TOKEN });
    expect(res).toEqual({ status: 429, body: { error: 'Too many tries. Wait a few minutes and try again.' } });
    expect(calls.map((c) => c.fn)).toEqual(['comp_claim_throttle']);
  });

  it('a link over its limit is told the same, and the offer is not looked up', async () => {
    throttle = [true, false];
    const res = await run({ action: 'view', token: TOKEN });
    expect(res.status).toBe(429);
    expect(called('comp_claim_view').length).toBe(0);
  });

  it('a submit counts the same way and is refused the same way', async () => {
    throttle = [true, false];
    expect((await run({ action: 'submit', token: TOKEN, tableId: TABLE })).status).toBe(429);
    expect(called('comp_claim_submit').length).toBe(0);
  });

  it('if the counting itself fails the visit fails: it is never let through uncounted', async () => {
    answers.comp_claim_throttle = new Error('down');
    const bad = async (fn: string, args: Record<string, unknown>) => (fn === 'comp_claim_throttle' ? { data: null, error: { message: 'down' } } : rpc(fn, args));
    const res = await handleClaim({ action: 'view', token: TOKEN }, { rpcService: bad, visitor: 'v' });
    expect(res.status).toBe(500);
    expect(called('comp_claim_view').length).toBe(0);
  });

  it('the visitor\'s answer must be exactly true, even when the link\'s is fine', async () => {
    let n = 0;
    const odd = async (fn: string, args: Record<string, unknown>) => (fn === 'comp_claim_throttle' ? { data: ++n === 1 ? 'true' : true, error: null } : rpc(fn, args));
    expect((await handleClaim({ action: 'view', token: TOKEN }, { rpcService: odd, visitor: 'v' })).status).toBe(429);
  });

  it('the link\'s answer must be exactly true, even when the visitor\'s is fine', async () => {
    let n = 0;
    const odd = async (fn: string, args: Record<string, unknown>) => (fn === 'comp_claim_throttle' ? { data: ++n === 2 ? 'true' : true, error: null } : rpc(fn, args));
    expect((await handleClaim({ action: 'view', token: TOKEN }, { rpcService: odd, visitor: 'v' })).status).toBe(429);
  });

  it('if counting the link fails the visit fails, and the offer is not looked up', async () => {
    let n = 0;
    const bad = async (fn: string, args: Record<string, unknown>) => (fn === 'comp_claim_throttle' ? (++n === 2 ? { data: null, error: { message: 'down' } } : { data: true, error: null }) : rpc(fn, args));
    const res = await handleClaim({ action: 'view', token: TOKEN }, { rpcService: bad, visitor: 'v' });
    expect(res.status).toBe(500);
    expect(called('comp_claim_view').length).toBe(0);
  });

  it('a throttle answer that is not exactly true is over the limit', async () => {
    const odd = async (fn: string, args: Record<string, unknown>) => (fn === 'comp_claim_throttle' ? { data: 'true', error: null } : rpc(fn, args));
    expect((await handleClaim({ action: 'view', token: TOKEN }, { rpcService: odd, visitor: 'v' })).status).toBe(429);
  });
});

describe('a link that cannot be a link', () => {
  it.each([undefined, null, 5, '', 'abc', 'ZZ'.repeat(32), `${TOKEN}x`, TOKEN.slice(1), TOKEN.toUpperCase(), '../etc/passwd'])('%j is "not found", the same as one that is not there', async (token) => {
    const res = await run({ action: 'view', token });
    expect(res).toEqual({ status: 200, body: { state: 'not_found' } });
    expect(called('comp_claim_view').length).toBe(0);
  });

  it('it still counts against the visitor (a guesser is slowed), but not against any link', async () => {
    await run({ action: 'view', token: 'nope' }, 'g');
    expect(calls.map((c) => c.fn)).toEqual(['comp_claim_throttle']);
    expect(calls[0].args.p_key).toBe('ip:g');
  });

  it('a visitor over the limit is stopped even with a bad link', async () => {
    throttle = [false];
    expect((await run({ action: 'view', token: 'nope' })).status).toBe(429);
  });
});

describe('viewing', () => {
  it('asks for the link by its token, with the service role, and nothing else', async () => {
    await run({ action: 'view', token: TOKEN });
    expect(called('comp_claim_view').map((c) => c.args)).toEqual([{ p_token: TOKEN }]);
  });

  it('tells the page what it shows, and only that', async () => {
    const res = await run({ action: 'view', token: TOKEN });
    expect(res.status).toBe(200);
    expect(res.body).toEqual({
      state: 'open', venue_name: 'Club A', event_title: 'Halloween Night', item: 'Patron', size: '750ml', quantity: 2, sign: 'Happy birthday Gina', recipient_name: 'Gina', expires_at: '2026-11-25T02:00:00Z',
      floors: [{ id: FLOOR, label: 'Main floor', image_url: 'https://cdn.example/floor.png' }],
      tables: [{ id: TABLE, name: 'Booth 1', floor_id: FLOOR, pos_x: 10, pos_y: 20, width: 5, height: 5 }],
    });
  });

  it('drops anything the database should not have sent: another guest, a booking, an address, the link', async () => {
    answers.comp_claim_view = {
      ...OPEN, recipient_email: 'gina@x.example', booking_id: 'b1', guest_name: 'Ada Lovelace', token_hash: 'abc', phone: '+1 555 0100',
      tables: [{ ...OPEN.tables[0], guest_name: 'Ada Lovelace', booking_id: 'b9', customer_email: 'ada@x.example' }],
      floors: [{ ...OPEN.floors[0], owner_email: 'o@x.example' }],
    };
    const text = JSON.stringify((await run({ action: 'view', token: TOKEN })).body);
    for (const leaked of ['gina@x.example', 'b1', 'Ada', 'abc', '555', 'ada@x.example', 'o@x.example', 'b9']) expect(text, leaked).not.toContain(leaked);
  });

  it('keeps only floors and tables that are what they say', async () => {
    answers.comp_claim_view = {
      ...OPEN,
      floors: [{ id: FLOOR, label: 'Main', image_url: 'javascript:alert(1)' }, { id: 'nope', label: 'Bad id' }, { id: FLOOR, label: 5 }, 'x', null],
      tables: [{ id: TABLE, name: 'Booth 1', floor_id: 'not-an-id', pos_x: 'ten', pos_y: Infinity, width: null }, { id: 'x', name: 'Bad' }, { id: TABLE, name: 5 }, 7],
    };
    const body = (await run({ action: 'view', token: TOKEN })).body as { floors: unknown[]; tables: unknown[] };
    expect(body.floors).toEqual([{ id: FLOOR, label: 'Main', image_url: null }]);
    expect(body.tables).toEqual([{ id: TABLE, name: 'Booth 1', floor_id: null, pos_x: null, pos_y: null, width: null, height: null }]);
  });

  it('a floor image must be http or https', async () => {
    answers.comp_claim_view = { ...OPEN, floors: [{ id: FLOOR, label: 'A', image_url: 'http://cdn.example/a.png' }, { id: FLOOR, label: 'B', image_url: 'data:image/png;base64,xx' }] };
    const body = (await run({ action: 'view', token: TOKEN })).body as { floors: { image_url: string | null }[] };
    expect(body.floors.map((f) => f.image_url)).toEqual(['http://cdn.example/a.png', null]);
  });

  it('missing optional parts are null, and missing floors or tables are empty lists', async () => {
    answers.comp_claim_view = { state: 'open', venue_name: 'Club A', item: 'Patron', quantity: 1, expires_at: '2026-11-25T02:00:00Z' };
    expect((await run({ action: 'view', token: TOKEN })).body).toEqual({
      state: 'open', venue_name: 'Club A', event_title: null, item: 'Patron', size: null, quantity: 1, sign: null, recipient_name: null, expires_at: '2026-11-25T02:00:00Z', floors: [], tables: [],
    });
  });

  it('an open offer that is missing its basics is a failure, not a half page', async () => {
    for (const drop of ['venue_name', 'item', 'quantity', 'expires_at']) {
      answers.comp_claim_view = { ...OPEN, [drop]: undefined };
      expect((await run({ action: 'view', token: TOKEN })).status, drop).toBe(500);
    }
  });

  it.each(['not_found', 'expired', 'cancelled'])('"%s" is passed on as that state alone', async (state) => {
    answers.comp_claim_view = { state, venue_name: 'Club A', item: 'Patron', recipient_email: 'gina@x.example' };
    expect(await run({ action: 'view', token: TOKEN })).toEqual({ status: 200, body: { state } });
  });

  it('a claimed offer says what it was, and the club', async () => {
    answers.comp_claim_view = { state: 'claimed', item: 'Patron', quantity: 2, venue_name: 'Club A', booking_id: 'b1' };
    expect((await run({ action: 'view', token: TOKEN })).body).toEqual({ state: 'claimed', item: 'Patron', quantity: 2, venue_name: 'Club A' });
  });

  it('a claimed offer with nothing more to say is just the state', async () => {
    answers.comp_claim_view = { state: 'claimed' };
    expect((await run({ action: 'view', token: TOKEN })).body).toEqual({ state: 'claimed' });
  });
});

describe('saying where you are', () => {
  it('passes the link and the table to the database, once', async () => {
    const res = await run({ action: 'submit', token: TOKEN, tableId: TABLE });
    expect(res).toEqual({ status: 200, body: { state: 'submitted' } });
    expect(called('comp_claim_submit').map((c) => c.args)).toEqual([{ p_token: TOKEN, p_table: TABLE }]);
    expect(called('comp_claim_view').length).toBe(0);
  });

  it.each(['claimed', 'expired', 'cancelled', 'not_found', 'bad_table'])('"%s" comes back as that state', async (state) => {
    answers.comp_claim_submit = { state };
    expect((await run({ action: 'submit', token: TOKEN, tableId: TABLE })).body).toEqual({ state });
  });

  it('a second claim answers with the state alone, and nothing about the first', async () => {
    answers.comp_claim_submit = { state: 'claimed', table: 'Booth 1', booking_id: 'b1' };
    expect((await run({ action: 'submit', token: TOKEN, tableId: TABLE })).body).toEqual({ state: 'claimed' });
  });
});

describe('when the database misbehaves', () => {
  it('an error is a generic failure with none of its words', async () => {
    answers.comp_claim_view = new Error('relation "site_comp_offers" does not exist');
    const res = await run({ action: 'view', token: TOKEN });
    expect(res).toEqual({ status: 500, body: { error: 'Something went wrong. Try again.' } });
  });

  it.each([null, 'open', 5, [], { state: 'weird' }, { state: 5 }, {}])('an answer of %j is a failure', async (answer) => {
    answers.comp_claim_view = answer;
    expect((await run({ action: 'view', token: TOKEN })).status).toBe(500);
  });
});

describe('the hash', () => {
  it('is SHA-256 in hex', async () => {
    expect(await sha256Hex('abc')).toBe('ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
    expect(await sha256Hex('')).toBe('e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
  });
});
