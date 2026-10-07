import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import { AFTER_MIDNIGHT_CUTOFF, computeNightDate } from './bookingNight';
import {
  addDays, applyFilter, formatNight, groupByNight, MAX_NIGHTS, nightCount, presets, ROW_LIMIT, statusInfo, summarize, validateRange,
  type BookingRow,
} from './bookingsView';

const row = (over: Partial<BookingRow> = {}): BookingRow => ({
  bookingId: 'b', nightDate: '2026-10-10', startTime: '21:00:00', slotLabel: null, tableName: 'VIP booth', guestCount: 4,
  customerName: 'Ada', customerEmail: 'ada@test.example', customerPhone: null, status: 'paid', confirmationCode: 'C1',
  checkedInAt: null, amountTotalCents: 10000, depositCents: 0, currency: 'cad', ...over,
});

describe('what a status means to a venue', () => {
  it.each([
    ['paid', 'Confirmed', 'good', true],
    ['pending', 'Awaiting payment', 'wait', false],
    ['failed', 'Payment failed', 'bad', false],
    ['refunded', 'Refunded', 'neutral', false],
    ['cancelled', 'Cancelled', 'neutral', false],
  ] as const)('%s is "%s"', (status, label, tone, confirmed) => {
    expect(statusInfo(status)).toEqual({ label, tone, confirmed });
  });

  it('a status it has never seen is shown as it is, and is never treated as confirmed', () => {
    expect(statusInfo('on_hold')).toEqual({ label: 'On_hold', tone: 'neutral', confirmed: false });
    expect(statusInfo('')).toEqual({ label: 'Unknown', tone: 'neutral', confirmed: false });
    expect(statusInfo('PAID').confirmed).toBe(false); // stored values are lower case; anything else is not trusted
  });

  it('only a paid booking is expected', () => {
    const rows = ['paid', 'pending', 'failed', 'refunded', 'cancelled', 'weird'].map((status, i) => row({ bookingId: String(i), status }));
    expect(applyFilter(rows, 'confirmed').map((r) => r.status)).toEqual(['paid']);
    expect(applyFilter(rows, 'all')).toHaveLength(6);
  });
});

describe('grouping and counting', () => {
  const rows = [
    row({ bookingId: '1', nightDate: '2026-10-10', guestCount: 4 }),
    row({ bookingId: '2', nightDate: '2026-10-10', guestCount: 2, status: 'pending' }),
    row({ bookingId: '3', nightDate: '2026-10-10', guestCount: 3, checkedInAt: '2026-10-10T22:00:00Z' }),
    row({ bookingId: '4', nightDate: '2026-10-11', guestCount: 6, status: 'cancelled' }),
    row({ bookingId: '5', nightDate: '2026-10-11', guestCount: 5, status: 'refunded' }),
    row({ bookingId: '6', nightDate: '2026-10-12', guestCount: 8, status: 'failed' }),
    row({ bookingId: '7', nightDate: '2026-10-12', guestCount: 1 }),
  ];

  it('groups by night in the order the database sent them, and names each night', () => {
    const groups = groupByNight(rows);
    expect(groups.map((g) => [g.night, g.label, g.rows.length])).toEqual([
      ['2026-10-10', 'Saturday Oct 10', 3], ['2026-10-11', 'Sunday Oct 11', 2], ['2026-10-12', 'Monday Oct 12', 2],
    ]);
  });

  it('counts only the guests of confirmed bookings in a night (a cancelled party is not expected)', () => {
    expect(groupByNight(rows).map((g) => g.guests)).toEqual([7, 0, 1]);
  });

  it('summarises confirmed bookings, their guests, who has arrived, and unpaid ones separately', () => {
    expect(summarize(rows)).toEqual({ bookings: 3, guests: 8, checkedIn: 1, awaitingPayment: 1 });
  });

  it('an empty list is zeros, not an error', () => {
    expect(summarize([])).toEqual({ bookings: 0, guests: 0, checkedIn: 0, awaitingPayment: 0 });
    expect(groupByNight([])).toEqual([]);
  });

  it('a checked-in booking that was cancelled afterwards is not counted as arrived', () => {
    expect(summarize([row({ status: 'cancelled', checkedInAt: '2026-10-10T22:00:00Z' })]).checkedIn).toBe(0);
  });

  it('formats a night', () => {
    expect(formatNight('2026-10-10')).toBe('Saturday Oct 10');
    expect(formatNight('2028-02-29')).toBe('Tuesday Feb 29');
  });
});

describe('dates', () => {
  it('adds days across month, year and leap-day boundaries', () => {
    expect(addDays('2026-10-31', 1)).toBe('2026-11-01');
    expect(addDays('2026-12-31', 1)).toBe('2027-01-01');
    expect(addDays('2028-02-28', 1)).toBe('2028-02-29');
    expect(addDays('2026-02-28', 1)).toBe('2026-03-01');
    expect(addDays('2026-03-01', -1)).toBe('2026-02-28');
    expect(addDays('2026-10-10', 0)).toBe('2026-10-10');
  });

  it('refuses something that is not a date, rather than inventing one', () => {
    for (const bad of ['', '2026-13-01', '2026-02-30', 'tomorrow', '2026-1-1']) expect(() => addDays(bad, 1)).toThrow();
  });

  it('counts nights with both ends included', () => {
    expect(nightCount({ from: '2026-10-10', to: '2026-10-10' })).toBe(1);
    expect(nightCount({ from: '2026-10-10', to: '2026-10-16' })).toBe(7);
    expect(nightCount({ from: '2026-12-30', to: '2027-01-02' })).toBe(4);
    expect(nightCount({ from: 'nope', to: '2026-10-10' })).toBe(0);
  });

  it('validates a range in plain words', () => {
    expect(validateRange({ from: '2026-10-10', to: '2026-10-10' })).toBeNull();
    expect(validateRange({ from: '', to: '2026-10-10' })).toBe('Choose a start and an end date.');
    expect(validateRange({ from: '2026-10-10', to: '2026-02-30' })).toBe('Choose a start and an end date.');
    expect(validateRange({ from: '2026-10-10', to: '2026-10-09' })).toBe('The end date is before the start date.');
    expect(validateRange({ from: '2026-10-10', to: addDays('2026-10-10', MAX_NIGHTS - 1) })).toBeNull();
    expect(validateRange({ from: '2026-10-10', to: addDays('2026-10-10', MAX_NIGHTS) })).toBe(`Choose at most ${MAX_NIGHTS} nights at a time.`);
  });
});

describe('ready-made ranges, in business nights', () => {
  it('counts the evening as that night', () => {
    const p = presets(new Date(2026, 9, 10, 21, 30)); // Saturday 21:30 local
    expect(p.find((x) => x.id === 'tonight')?.range).toEqual({ from: '2026-10-10', to: '2026-10-10' });
  });

  it('counts 1:30 AM as still the previous night: Sunday 01:30 is Saturday night', () => {
    const p = presets(new Date(2026, 9, 11, 1, 30));
    expect(p.find((x) => x.id === 'tonight')?.range).toEqual({ from: '2026-10-10', to: '2026-10-10' });
    expect(p.find((x) => x.id === 'next7')?.range.from).toBe('2026-10-10');
  });

  it('06:00 is the start of the new night', () => {
    expect(presets(new Date(2026, 9, 11, 5, 59, 59))[0].range.from).toBe('2026-10-10');
    expect(presets(new Date(2026, 9, 11, 6, 0, 0))[0].range.from).toBe('2026-10-11');
  });

  it('has the right number of nights, and the past ones end the night before tonight', () => {
    const p = presets(new Date(2026, 9, 10, 21, 0));
    const byId = Object.fromEntries(p.map((x) => [x.id, x.range]));
    expect(nightCount(byId.tonight)).toBe(1);
    expect(nightCount(byId.next7)).toBe(7);
    expect(nightCount(byId.next30)).toBe(30);
    expect(byId.last7).toEqual({ from: '2026-10-03', to: '2026-10-09' });
    expect(nightCount(byId.last7)).toBe(7);
  });

  it('every preset can actually be asked for', () => {
    for (const now of [new Date(2026, 0, 31, 23, 0), new Date(2028, 1, 28, 3, 0), new Date(2026, 11, 31, 1, 0)]) {
      for (const preset of presets(now)) expect(validateRange(preset.range), `${preset.id} at ${now.toISOString()}`).toBeNull();
    }
  });
});

// The same night rule exists in three places: the browser, the edge functions, and the database function that returns the
// bookings. The first two are compared in tests/edge/bookingNight.test.ts; this ties the database to the browser.
describe('the database and the browser agree', () => {
  const sql = readFileSync(join(__dirname, '..', '..', 'supabase', 'migrations', '20261011100000_venue_bookings.sql'), 'utf8');

  it('uses the same 06:00 cutoff for the business night', () => {
    expect(sql).toContain(`p_start < time '${AFTER_MIDNIGHT_CUTOFF}'`);
    expect(computeNightDate('2026-10-11', '05:59:59')).toBe('2026-10-10');
    expect(computeNightDate('2026-10-11', AFTER_MIDNIGHT_CUTOFF)).toBe('2026-10-11');
  });

  it('allows the same number of nights, and returns the same number of rows, as the screen expects', () => {
    expect(sql).toContain(`if p_to - p_from > ${MAX_NIGHTS - 1} then`);
    expect(sql).toContain(`at most ${MAX_NIGHTS} nights`);
    expect(sql).toContain(`limit ${ROW_LIMIT};`);
  });

  it('reads only columns the committed migrations define for a booking (production-only columns are not guessed at)', () => {
    const productionOnly = ['amount_paid_cents', 'discount_cents', 'cancelled_at', 'cancellation_reason', 'reconciled_at', 'bottle_payment_choice', 'service_status'];
    for (const column of productionOnly) expect(sql.replace(/--.*$/gm, '')).not.toContain(column);
  });
});
