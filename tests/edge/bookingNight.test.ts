import { describe, expect, it } from 'vitest';
import * as web from '../../src/lib/bookingNight';
import * as edge from '../../supabase/functions/_shared/bookingNight.ts';

// A venue's "night" runs past midnight: a 1:00 AM table is Saturday night's
// party, so it is stored with SUNDAY's calendar date. A bug here puts a guest
// on the wrong day. There are two copies of this logic (browser and edge
// function) that must agree - the edge copy's header says "kept in sync".

const NIGHTS = ['2026-01-31', '2026-02-28', '2028-02-28', '2027-12-31', '2026-03-08', '2026-10-31'];
const TIMES = ['00:00:00', '00:30:00', '02:30:00', '05:59:59', '06:00:00', '06:00:01', '12:00:00', '23:59:59'];

describe('bookingNight: known answers', () => {
  it.each([
    // night,        slot,       stored arrival date
    ['2026-10-03', '12:00:00', '2026-10-03'], // evening slot: same day
    ['2026-10-03', '23:59:59', '2026-10-03'],
    ['2026-10-03', '01:00:00', '2026-10-04'], // after midnight: next calendar day
    ['2026-10-03', '00:00:00', '2026-10-04'],
    ['2027-12-31', '01:00:00', '2028-01-01'], // year rollover
    ['2026-01-31', '02:30:00', '2026-02-01'], // month rollover
    ['2028-02-28', '02:30:00', '2028-02-29'], // leap day exists in 2028
    ['2026-02-28', '00:00:00', '2026-03-01'], // ...and not in 2026
  ])('night %s at %s is stored as arrival %s', (night, slot, arrival) => {
    expect(web.computeArrivalDate(night, slot)).toBe(arrival);
    expect(edge.computeArrivalDate(night, slot)).toBe(arrival);
  });

  it('the cutoff is 06:00:00: 05:59:59 still belongs to the previous night, 06:00:00 does not', () => {
    for (const m of [web, edge]) {
      expect(m.isAfterMidnightSlot('05:59:59')).toBe(true);
      expect(m.isAfterMidnightSlot('06:00:00')).toBe(false);
    }
  });
});

describe('bookingNight: the two copies agree and round-trip', () => {
  const cases = NIGHTS.flatMap((n) => TIMES.map((t) => [n, t] as const));

  it.each(cases)('%s %s', (night, slot) => {
    expect(edge.isAfterMidnightSlot(slot)).toBe(web.isAfterMidnightSlot(slot));
    expect(edge.computeArrivalDate(night, slot)).toBe(web.computeArrivalDate(night, slot));
    expect(edge.computeNightDate(night, slot)).toBe(web.computeNightDate(night, slot));
    expect(edge.formatWeekday(night)).toBe(web.formatWeekday(night));
    // arrival -> night recovers exactly what the customer originally picked
    expect(web.computeNightDate(web.computeArrivalDate(night, slot), slot)).toBe(night);
    expect(edge.computeNightDate(edge.computeArrivalDate(night, slot), slot)).toBe(night);
  });

  it('exports the same cutoff', () => {
    expect(edge.AFTER_MIDNIGHT_CUTOFF).toBe(web.AFTER_MIDNIGHT_CUTOFF);
  });
});

describe('bookingNight: formatting', () => {
  it('weekday ignores the machine timezone (2024-02-29 was a Thursday)', () => {
    expect(web.formatWeekday('2024-02-29')).toBe('Thursday');
  });
  it('month and day', () => {
    expect(web.formatMonthDay('2026-03-01')).toBe('Mar 1');
  });
  it.each([
    ['00:00:00', '12:00 AM'],
    ['00:30:00', '12:30 AM'],
    ['09:05:00', '9:05 AM'],
    ['12:00:00', '12:00 PM'],
    ['13:05:00', '1:05 PM'],
    ['23:59:00', '11:59 PM'],
  ])('time slot %s reads %s', (slot, label) => {
    expect(web.formatTimeSlot(slot)).toBe(label);
  });
});
