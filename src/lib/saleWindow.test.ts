import { describe, expect, it } from 'vitest';
import { defaultTierId, isOnSale, saleLabel, saleState } from './saleWindow';

const at = (iso: string) => new Date(iso);

describe('saleState: when a ticket type may be bought', () => {
  it('a type with no dates is on sale', () => {
    expect(saleState({}, at('2026-12-01T10:00:00Z'))).toEqual({ state: 'open' });
    expect(saleState({ sale_starts_at: null, sale_ends_at: null }, at('2026-12-01T10:00:00Z'))).toEqual({ state: 'open' });
  });

  it('before it starts it is not on sale and says when it opens; at the start it is', () => {
    const tier = { sale_starts_at: '2026-12-05T19:00:00Z' };
    expect(saleState(tier, at('2026-12-05T18:59:59Z'))).toEqual({ state: 'not_started', opensAt: at('2026-12-05T19:00:00Z') });
    expect(saleState(tier, at('2026-12-05T19:00:00Z'))).toEqual({ state: 'open' });
  });

  it('a moment before it ends it is on sale; at the end it is closed', () => {
    const tier = { sale_ends_at: '2026-12-10T22:00:00Z' };
    expect(saleState(tier, at('2026-12-10T21:59:59Z'))).toEqual({ state: 'open' });
    expect(saleState(tier, at('2026-12-10T22:00:00Z'))).toEqual({ state: 'ended', closedAt: at('2026-12-10T22:00:00Z') });
  });

  it('a date that cannot be read counts as no date', () => {
    expect(saleState({ sale_starts_at: 'garbage', sale_ends_at: 'garbage' }, at('2026-12-01T00:00:00Z'))).toEqual({ state: 'open' });
  });

  it('isOnSale is the same question as a yes or no', () => {
    expect(isOnSale({ sale_ends_at: '2026-12-10T22:00:00Z' }, at('2026-12-10T21:00:00Z'))).toBe(true);
    expect(isOnSale({ sale_ends_at: '2026-12-10T22:00:00Z' }, at('2026-12-10T23:00:00Z'))).toBe(false);
    expect(isOnSale({ sale_starts_at: '2999-01-01T00:00:00Z' })).toBe(false);
  });
});

describe('saleLabel: what the page says', () => {
  it('says nothing for a type that is on sale', () => {
    expect(saleLabel({}, at('2026-12-01T10:00:00Z'))).toBeNull();
    expect(saleLabel({ sale_ends_at: '2026-12-10T22:00:00Z' }, at('2026-12-01T10:00:00Z'))).toBeNull();
  });

  it('says "Sales ended" after the end', () => {
    expect(saleLabel({ sale_ends_at: '2026-12-10T22:00:00Z' }, at('2026-12-11T00:00:00Z'))).toBe('Sales ended');
  });

  it('says when sales open, in the zone asked for', () => {
    const tier = { sale_starts_at: '2026-12-05T19:00:00-05:00' };
    expect(saleLabel(tier, at('2026-12-01T00:00:00Z'), 'America/Toronto')).toMatch(/^On sale from Dec\.? 5,? 7:00\s?p\.?m\.?$/i);
    expect(saleLabel(tier, at('2026-12-01T00:00:00Z'), 'UTC')).toMatch(/^On sale from Dec\.? 6,? 12:00\s?a\.?m\.?$/i);
  });
});

describe('defaultTierId: which ticket type the form starts on', () => {
  const now = at('2026-12-07T12:00:00Z');
  const closed = { id: 'closed', sale_ends_at: '2026-12-01T00:00:00Z' };
  const soon = { id: 'soon', sale_starts_at: '2026-12-20T00:00:00Z' };
  const open = { id: 'open' };
  const open2 = { id: 'open2' };

  it('the one asked for, when it is on sale', () => {
    expect(defaultTierId([closed, open, open2], 'open2', now)).toBe('open2');
  });

  it('otherwise the first one that is on sale (a closed first type is not chosen)', () => {
    expect(defaultTierId([closed, soon, open, open2], null, now)).toBe('open');
    expect(defaultTierId([closed, soon, open, open2], 'closed', now)).toBe('open');
    expect(defaultTierId([closed, open], 'missing', now)).toBe('open');
  });

  it('when none is on sale, the one asked for or the first, so the form can say why', () => {
    expect(defaultTierId([closed, soon], 'soon', now)).toBe('soon');
    expect(defaultTierId([closed, soon], null, now)).toBe('closed');
  });

  it('with no ticket types there is nothing to choose', () => {
    expect(defaultTierId([], 'x', now)).toBe('');
  });
});
