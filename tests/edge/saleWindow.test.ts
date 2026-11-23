import { describe, expect, it } from 'vitest';
import { saleWindowBlock } from '../../supabase/functions/_shared/saleWindow.ts';

const at = (iso: string) => new Date(iso);

describe('a ticket type\'s sales window', () => {
  it('a ticket type with no dates is on sale, always (every type made before this existed)', () => {
    expect(saleWindowBlock({}, at('2026-12-01T10:00:00Z'))).toEqual({ blocked: false });
    expect(saleWindowBlock({ sale_starts_at: null, sale_ends_at: null }, at('2026-12-01T10:00:00Z'))).toEqual({ blocked: false });
    expect(saleWindowBlock({ sale_starts_at: undefined, sale_ends_at: undefined }, at('1999-01-01T00:00:00Z'))).toEqual({ blocked: false });
  });

  it('before the start it is not on sale yet, and says when it opens', () => {
    const r = saleWindowBlock({ sale_starts_at: '2026-12-05T19:00:00Z' }, at('2026-12-05T18:59:59Z'));
    expect(r).toEqual({ blocked: true, reason: 'not_started', message: 'Ticket sales for this ticket type have not opened yet.', opens_at: '2026-12-05T19:00:00.000Z' });
  });

  it('at the very moment sales start it is on sale (the start is included)', () => {
    expect(saleWindowBlock({ sale_starts_at: '2026-12-05T19:00:00Z' }, at('2026-12-05T19:00:00Z'))).toEqual({ blocked: false });
    expect(saleWindowBlock({ sale_starts_at: '2026-12-05T19:00:00Z' }, at('2026-12-05T19:00:01Z'))).toEqual({ blocked: false });
  });

  it('at the very moment sales end it is closed (the end is not included), and a moment before it is open', () => {
    expect(saleWindowBlock({ sale_ends_at: '2026-12-10T22:00:00Z' }, at('2026-12-10T21:59:59Z'))).toEqual({ blocked: false });
    const r = saleWindowBlock({ sale_ends_at: '2026-12-10T22:00:00Z' }, at('2026-12-10T22:00:00Z'));
    expect(r).toEqual({ blocked: true, reason: 'ended', message: 'Ticket sales for this ticket type have ended.', closed_at: '2026-12-10T22:00:00.000Z' });
  });

  it('after the end it stays closed', () => {
    expect(saleWindowBlock({ sale_ends_at: '2026-12-10T22:00:00Z' }, at('2027-06-01T00:00:00Z'))).toMatchObject({ blocked: true, reason: 'ended' });
  });

  it('with both dates it is open between them and closed outside', () => {
    const tier = { sale_starts_at: '2026-12-05T19:00:00Z', sale_ends_at: '2026-12-10T22:00:00Z' };
    expect(saleWindowBlock(tier, at('2026-12-01T00:00:00Z'))).toMatchObject({ blocked: true, reason: 'not_started' });
    expect(saleWindowBlock(tier, at('2026-12-07T12:00:00Z'))).toEqual({ blocked: false });
    expect(saleWindowBlock(tier, at('2026-12-11T00:00:00Z'))).toMatchObject({ blocked: true, reason: 'ended' });
  });

  it('dates are compared as moments, whatever zone they were written in', () => {
    // 19:00 in Toronto (UTC-5 in December) is 00:00 UTC the next day
    const tier = { sale_starts_at: '2026-12-05T19:00:00-05:00' };
    expect(saleWindowBlock(tier, at('2026-12-05T23:59:59Z'))).toMatchObject({ blocked: true, reason: 'not_started' });
    expect(saleWindowBlock(tier, at('2026-12-06T00:00:00Z'))).toEqual({ blocked: false });
  });

  it('a date that cannot be read counts as no date (it never locks anybody out)', () => {
    expect(saleWindowBlock({ sale_starts_at: 'not a date', sale_ends_at: '' }, at('2026-12-01T00:00:00Z'))).toEqual({ blocked: false });
    expect(saleWindowBlock({ sale_ends_at: 'garbage' }, at('2026-12-01T00:00:00Z'))).toEqual({ blocked: false });
    expect(saleWindowBlock({ sale_starts_at: 'garbage', sale_ends_at: '2026-12-10T22:00:00Z' }, at('2026-12-01T00:00:00Z'))).toEqual({ blocked: false });
  });

  it('uses the real clock when none is given', () => {
    expect(saleWindowBlock({ sale_starts_at: '2999-01-01T00:00:00Z' })).toMatchObject({ blocked: true, reason: 'not_started' });
    expect(saleWindowBlock({ sale_ends_at: '2000-01-01T00:00:00Z' })).toMatchObject({ blocked: true, reason: 'ended' });
    expect(saleWindowBlock({ sale_starts_at: '2000-01-01T00:00:00Z', sale_ends_at: '2999-01-01T00:00:00Z' })).toEqual({ blocked: false });
  });
});
