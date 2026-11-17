import { beforeEach, describe, expect, it, vi } from 'vitest';

const invoke = vi.fn();
vi.mock('@/lib/supabase', () => ({ supabase: { functions: { invoke: (...args: unknown[]) => invoke(...args) } } }));

import {
  endMessage,
  expiryText,
  giftLabel,
  isClaimToken,
  isPlaced,
  listedTables,
  mapFloors,
  markerStyle,
  parseClaim,
  submitClaim,
  tablesOnFloor,
  viewClaim,
  type OpenClaim,
} from '@/lib/compClaim';

// The complimentary claim page's logic. What matters: only a real link reaches the server; the answer is read defensively and never half-trusted; a table is drawn where the venue's own floor plan
// draws it and is never lost (a table that cannot be drawn is listed by name); the words never say more than the state; a throttled visitor is told to wait, not that something broke.
const TOKEN = 'ab'.repeat(32);
const FLOOR = '44444444-4444-4444-8444-444444444444';
const T1 = '33333333-3333-4333-8333-333333333333';
const T2 = '55555555-5555-4555-8555-555555555555';
const T3 = '66666666-6666-4666-8666-666666666666';

const wire = {
  state: 'open', venue_name: 'Club A', event_title: 'Halloween Night', item: 'Patron', size: '750ml', quantity: 2, sign: 'Happy birthday', recipient_name: 'Gina', expires_at: '2026-11-25T02:00:00Z',
  floors: [{ id: FLOOR, label: 'Main floor', image_url: 'https://cdn.example/floor.png' }],
  tables: [
    { id: T1, name: 'Booth 1', floor_id: FLOOR, pos_x: 10, pos_y: 20, width: 5, height: 8 },
    { id: T2, name: 'Booth 2', floor_id: null, pos_x: null, pos_y: null, width: null, height: null },
  ],
};
const open = () => parseClaim(wire) as OpenClaim;

beforeEach(() => {
  invoke.mockReset();
});

describe('the link', () => {
  it('is 64 lowercase hex characters', () => {
    expect(isClaimToken(TOKEN)).toBe(true);
    for (const bad of [undefined, null, 5, '', 'abc', TOKEN.slice(1), TOKEN + 'a', TOKEN.toUpperCase(), 'g'.repeat(64), `${TOKEN.slice(0, 63)}-`, '../etc/passwd']) expect(isClaimToken(bad), String(bad)).toBe(false);
  });
});

describe('reading the answer', () => {
  it('an open offer, in full', () => {
    expect(open()).toEqual({
      state: 'open', venueName: 'Club A', eventTitle: 'Halloween Night', item: 'Patron', size: '750ml', quantity: 2, sign: 'Happy birthday', recipientName: 'Gina', expiresAt: '2026-11-25T02:00:00Z',
      floors: [{ id: FLOOR, label: 'Main floor', imageUrl: 'https://cdn.example/floor.png' }],
      tables: [
        { id: T1, name: 'Booth 1', floorId: FLOOR, x: 10, y: 20, width: 5, height: 8 },
        { id: T2, name: 'Booth 2', floorId: null, x: null, y: null, width: null, height: null },
      ],
    });
  });

  it('missing optional parts are null and missing lists are empty', () => {
    const c = parseClaim({ state: 'open', venue_name: 'Club A', item: 'Patron', quantity: 1, expires_at: '2026-11-25T02:00:00Z' }) as OpenClaim;
    expect([c.eventTitle, c.size, c.sign, c.recipientName, c.floors, c.tables]).toEqual([null, null, null, null, [], []]);
  });

  it('an open offer that is missing its basics is an error, not a half page', () => {
    for (const drop of ['venue_name', 'item', 'quantity', 'expires_at']) expect(parseClaim({ ...wire, [drop]: undefined }).state, drop).toBe('error');
    expect(parseClaim({ ...wire, quantity: '2' }).state).toBe('error');
  });

  it('keeps only floors and tables that are what they say', () => {
    const c = parseClaim({ ...wire, floors: [{ id: FLOOR, label: 'A', image_url: 5 }, { id: 5, label: 'bad' }, { label: 'no id' }, null, 'x'], tables: [{ id: T1, name: 'T', floor_id: 5, pos_x: 'ten' }, { name: 'no id' }, { id: T2 }, 7] }) as OpenClaim;
    expect(c.floors).toEqual([{ id: FLOOR, label: 'A', imageUrl: null }]);
    expect(c.tables).toEqual([{ id: T1, name: 'T', floorId: null, x: null, y: null, width: null, height: null }]);
  });

  it('a claimed offer says what it was, or nothing more', () => {
    expect(parseClaim({ state: 'claimed', item: 'Patron', quantity: 2, venue_name: 'Club A' })).toEqual({ state: 'claimed', item: 'Patron', quantity: 2, venueName: 'Club A' });
    expect(parseClaim({ state: 'claimed' })).toEqual({ state: 'claimed', item: null, quantity: null, venueName: null });
  });

  it.each(['submitted', 'expired', 'cancelled', 'not_found', 'bad_table'])('"%s" is that state alone', (state) => {
    expect(parseClaim({ state, venue_name: 'Club A', recipient_email: 'x@y.z' })).toEqual({ state });
  });

  it.each([null, undefined, 'open', 5, [], {}, { state: 'weird' }, { state: 5 }, { state: 'rate_limited' }])('%j is an error', (data) => {
    expect(parseClaim(data)).toEqual({ state: 'error' });
  });
});

describe('asking the function', () => {
  it('views with the link, by the one function the page uses', async () => {
    invoke.mockResolvedValue({ data: wire, error: null });
    const r = await viewClaim(TOKEN);
    expect(r.state).toBe('open');
    expect(invoke).toHaveBeenCalledWith('comp-claim', { body: { action: 'view', token: TOKEN } });
  });

  it('submits with the link and the table, and nothing else', async () => {
    invoke.mockResolvedValue({ data: { state: 'submitted' }, error: null });
    expect(await submitClaim(TOKEN, T1)).toEqual({ state: 'submitted' });
    expect(invoke).toHaveBeenCalledWith('comp-claim', { body: { action: 'submit', token: TOKEN, tableId: T1 } });
  });

  it('a throttled visitor is told so, not that something broke', async () => {
    invoke.mockResolvedValue({ data: null, error: { context: { status: 429 } } });
    expect(await viewClaim(TOKEN)).toEqual({ state: 'rate_limited' });
  });

  it('any other failure is an error', async () => {
    invoke.mockResolvedValue({ data: null, error: { context: { status: 500 } } });
    expect(await viewClaim(TOKEN)).toEqual({ state: 'error' });
    invoke.mockResolvedValue({ data: null, error: new Error('network') });
    expect(await viewClaim(TOKEN)).toEqual({ state: 'error' });
    invoke.mockRejectedValue(new Error('offline'));
    expect(await submitClaim(TOKEN, T1)).toEqual({ state: 'error' });
  });

  it('an answer that cannot be read is an error', async () => {
    invoke.mockResolvedValue({ data: 'nonsense', error: null });
    expect(await viewClaim(TOKEN)).toEqual({ state: 'error' });
  });
});

describe('the map', () => {
  it('a table is placed when it has a floor and a position', () => {
    expect(isPlaced(open().tables[0])).toBe(true);
    expect(isPlaced(open().tables[1])).toBe(false);
    expect(isPlaced({ ...open().tables[0], floorId: null })).toBe(false);
    expect(isPlaced({ ...open().tables[0], x: null })).toBe(false);
    expect(isPlaced({ ...open().tables[0], y: null })).toBe(false);
  });

  it('a floor is drawn when it has a picture and a table on it', () => {
    expect(mapFloors(open()).map((f) => f.id)).toEqual([FLOOR]);
    expect(mapFloors({ ...open(), floors: [{ id: FLOOR, label: 'A', imageUrl: null }] })).toEqual([]);
    expect(mapFloors({ ...open(), tables: [] })).toEqual([]);
  });

  it('lists the tables of one floor', () => {
    expect(tablesOnFloor(open(), FLOOR).map((t) => t.id)).toEqual([T1]);
    expect(tablesOnFloor(open(), 'other')).toEqual([]);
  });

  it('lists by name every table that is not drawn, so nobody has nothing to choose', () => {
    expect(listedTables(open()).map((t) => t.id)).toEqual([T2]);
    const noPicture = { ...open(), floors: [{ id: FLOOR, label: 'A', imageUrl: null }] };
    expect(listedTables(noPicture).map((t) => t.id)).toEqual([T1, T2]);
    expect(listedTables({ ...open(), tables: [...open().tables, { id: T3, name: 'Booth 3', floorId: FLOOR, x: 50, y: 50, width: 5, height: 5 }] }).map((t) => t.id)).toEqual([T2]);
  });

  it('draws a table where the venue\'s own plan does: percent from the left and top, and its size', () => {
    expect(markerStyle(open().tables[0])).toEqual({ left: '10%', top: '20%', width: '5%', height: '8%' });
  });

  it('keeps a marker inside the picture', () => {
    expect(markerStyle({ id: 'x', name: 'x', floorId: FLOOR, x: 98, y: 99, width: 10, height: 10 })).toEqual({ left: '90%', top: '90%', width: '10%', height: '10%' });
    expect(markerStyle({ id: 'x', name: 'x', floorId: FLOOR, x: -5, y: -5, width: 10, height: 10 })).toEqual({ left: '0%', top: '0%', width: '10%', height: '10%' });
  });

  it('gives a table with no size a small square, and never a size that vanishes or fills the picture', () => {
    expect(markerStyle({ id: 'x', name: 'x', floorId: FLOOR, x: 10, y: 10, width: null, height: null })).toEqual({ left: '10%', top: '10%', width: '6%', height: '6%' });
    expect(markerStyle({ id: 'x', name: 'x', floorId: FLOOR, x: 10, y: 10, width: 0, height: 0 })).toMatchObject({ width: '2%', height: '2%' });
    expect(markerStyle({ id: 'x', name: 'x', floorId: FLOOR, x: 10, y: 10, width: 500, height: 500 })).toMatchObject({ width: '100%', height: '100%', left: '0%', top: '0%' });
  });
});

describe('the words', () => {
  it('the gift is quantity times item, with the size when there is one', () => {
    expect(giftLabel(open())).toBe('2 × Patron (750ml)');
    expect(giftLabel({ quantity: 1, item: 'Vodka', size: null })).toBe('1 × Vodka');
  });

  it('the expiry is the visitor\'s own time, and empty when unreadable', () => {
    expect(expiryText('2026-11-25T02:00:00Z', 'en-US')).toContain('November');
    expect(expiryText('2026-11-25T02:00:00Z', 'en-US')).toMatch(/\d{1,2}:\d{2}/);
    expect(expiryText('not a time')).toBe('');
  });

  it('every ending has a title and a sentence of its own, and none shows more than the state', () => {
    const titles = new Set<string>();
    for (const state of ['submitted', 'expired', 'cancelled', 'not_found', 'bad_table', 'rate_limited', 'error'] as const) {
      const m = endMessage({ state });
      expect(m.title.length, state).toBeGreaterThan(3);
      expect(m.body.length, state).toBeGreaterThan(10);
      titles.add(m.title);
    }
    expect(titles.size).toBe(7);
    expect(endMessage({ state: 'submitted' }).body).toContain('bring your bottle');
    expect(endMessage({ state: 'expired' }).title).toBe('This link has expired');
    expect(endMessage({ state: 'rate_limited' }).body).toContain('Wait a few minutes');
  });

  it('a claimed offer names what it was when it knows, and does not when it does not', () => {
    expect(endMessage({ state: 'claimed', item: 'Patron', quantity: 2, venueName: 'Club A' }).body).toBe('2 × Patron from Club A has been claimed. Ask a member of staff if you need anything.');
    expect(endMessage({ state: 'claimed', item: 'Patron', quantity: 2, venueName: null }).body).toBe('2 × Patron has been claimed. Ask a member of staff if you need anything.');
    expect(endMessage({ state: 'claimed', item: null, quantity: null, venueName: null }).body).toBe('This offer has already been claimed. Ask a member of staff if you need anything.');
  });

  it('nothing an ending says gives away a venue, a guest or a booking', () => {
    for (const state of ['submitted', 'expired', 'cancelled', 'not_found', 'bad_table', 'rate_limited', 'error'] as const) {
      const m = endMessage({ state });
      expect(`${m.title} ${m.body}`).not.toMatch(/@|booking|table \d/i);
    }
  });
});
