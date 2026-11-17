import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import {
  atLabel, clock12, documentForJob, eventDate, eventStatusWords, formatDollars, formatNight, kindLabel, opsBool, opsInt, opsStr, opsTime, parseConsolidatedReport, parseEventSales, parseNightReport,
  parseNightSales, safeFileName, timeOfDay, whenLabel,
} from '../../supabase/functions/_shared/reportDocs.ts';

// The server's reports must say the same thing as the app's. tests/fixtures/report_docs/*.json holds the inputs (what the database returns) and the document the APP builds from each (the vendor
// repo's test/night/report_docs_golden_test.dart writes and checks them); this builds each with the server's code and expects exactly that.

const dir = join(__dirname, '..', 'fixtures', 'report_docs');
const files = readdirSync(dir).filter((f) => f.endsWith('.json')).sort();

describe('the documents the server makes are the documents the app makes', () => {
  it('there are fixtures, covering every kind of report', () => {
    expect(files.length).toBeGreaterThanOrEqual(20);
    const kinds = new Set(files.map((f) => JSON.parse(readFileSync(join(dir, f), 'utf8')).kind));
    expect([...kinds].sort()).toEqual(['organizer_sales', 'owner_combined', 'venue_night']);
  });

  for (const f of files) {
    it(`${f.replace('.json', '')}: exactly the app's document`, () => {
      const fixture = JSON.parse(readFileSync(join(dir, f), 'utf8'));
      expect(fixture.expected, 'the expected document has not been written: run the app test with WRITE_REPORT_GOLDENS=1').not.toBeUndefined();
      const built = documentForJob({ kind: fixture.kind, time_zone: fixture.timeZone, ...fixture.input });
      expect(built).toEqual(fixture.expected);
    });
  }
});

describe('what the database sends is read the way the app reads it', () => {
  it('a string is a string unless it is empty or missing', () => {
    expect([opsStr({ a: 'x' }, 'a'), opsStr({ a: '' }, 'a'), opsStr({}, 'a'), opsStr({ a: null }, 'a'), opsStr({ a: 5 }, 'a'), opsStr({ a: true }, 'a'), opsStr(null, 'a')]).toEqual(['x', null, null, null, '5', 'true', null]);
  });
  it('a whole number is a number, a whole number in text, or 0 (never a guess)', () => {
    expect([opsInt({ a: 5 }, 'a'), opsInt({ a: 5.9 }, 'a'), opsInt({ a: -5.9 }, 'a'), opsInt({ a: '12' }, 'a'), opsInt({ a: '-12' }, 'a'), opsInt({ a: '+3' }, 'a'), opsInt({ a: '12abc' }, 'a'), opsInt({ a: ' 12' }, 'a'), opsInt({ a: '1.5' }, 'a'), opsInt({ a: null }, 'a'), opsInt({}, 'a'), opsInt({ a: true }, 'a'), opsInt(undefined, 'a')])
      .toEqual([5, 5, -5, 12, -12, 3, 0, 0, 0, 0, 0, 0, 0]);
  });
  it('only true is true', () => {
    expect([opsBool({ a: true }, 'a'), opsBool({ a: 'true' }, 'a'), opsBool({ a: 1 }, 'a'), opsBool({}, 'a'), opsBool(null, 'a')]).toEqual([true, false, false, false, false]);
  });
  it('a timestamp is read with its offset, to the millisecond, or is nothing', () => {
    expect(opsTime({ t: '2026-11-18T03:52:47.697772+05:30' }, 't')?.toISOString()).toBe('2026-11-17T22:22:47.697Z');
    expect(opsTime({ t: '2026-11-15T03:12:00Z' }, 't')?.toISOString()).toBe('2026-11-15T03:12:00.000Z');
    expect([opsTime({ t: 'soon' }, 't'), opsTime({ t: 5 }, 't'), opsTime({}, 't')]).toEqual([null, null, null]);
  });
  it('a night report needs a night; sections are the ones that are objects', () => {
    expect(parseNightReport({ view: 'full' })).toBeNull();
    expect(parseNightReport('x')).toBeNull();
    expect(parseNightReport([])).toBeNull();
    const r = parseNightReport({ business_night: '2026-11-14', bookings: { count: 1 }, payments: 'no', cash: [1] })!;
    expect(Object.keys(r.sections)).toEqual(['bookings']);
    expect([r.view, r.isFinal, r.venueName, r.closedAt, r.exceptions]).toEqual(['full', false, 'Club', null, []]);
  });
  it('sales need a known source, a recorded part and a night; a report with an unknown status is left out', () => {
    expect(parseNightSales(null)).toBeNull();
    expect(parseNightSales({ source: 'pos', recorded: {}, business_night: 'x' })).toBeNull();
    expect(parseNightSales({ source: 'entries', recorded: 'x', business_night: 'x' })).toBeNull();
    expect(parseNightSales({ source: 'entries', recorded: {} })).toBeNull();
    const s = parseNightSales({ source: 'upload', business_night: '2026-11-14', recorded: {}, venue_reported: { status: 'mystery' } })!;
    expect([s.reported, s.sourceLabel, s.recorded.label]).toEqual([null, 'Closing report upload', 'Recorded sales']);
    expect(parseNightSales({ source: 'entries', business_night: 'n', recorded: { net_cents: '120' } })!.recorded.net).toBe(120);
    expect(parseNightSales({ source: 'entries', business_night: 'n', recorded: { net_cents: '1.5' } })!.recorded.net).toBe(0);
    expect(parseNightSales({ source: 'upload', business_night: 'n', recorded: {}, venue_reported: { status: 'submitted' } })!.reported!.verification).toBe('Waiting to be checked');
  });
  it('the combined report is not trusted when a club cannot be read, when the club count is wrong, or when it has no totals and does not say the currencies are mixed', () => {
    const club = { venue_id: 'v', report: { business_night: '2026-11-14' } };
    expect(parseConsolidatedReport({ business_night: 'n', venues: [club], venues_total: 1, totals: {} })).not.toBeNull();
    expect(parseConsolidatedReport({ business_night: 'n', venues: [club], venues_total: 2, totals: {} })).toBeNull();
    expect(parseConsolidatedReport({ business_night: 'n', venues: [{ venue_id: 'v' }], venues_total: 1, totals: {} })).toBeNull();
    expect(parseConsolidatedReport({ business_night: 'n', venues: ['x'], venues_total: 1, totals: {} })).toBeNull();
    expect(parseConsolidatedReport({ business_night: 'n', venues: 'x', venues_total: 0, totals: {} })).toBeNull();
    expect(parseConsolidatedReport({ venues: [], venues_total: 0, totals: {} })).toBeNull();
    expect(parseConsolidatedReport({ business_night: 'n', venues: [], venues_total: 0 })).toBeNull();
    expect(parseConsolidatedReport({ business_night: 'n', venues: [], venues_total: 0, currency_mixed: true, totals: { tables: 5 } })!.totals).toBeNull();
    expect(parseConsolidatedReport({ business_night: 'n', venues: [], venues_total: 0, totals: { tables: '7', x: 'q', y: 2.9 } })!.totals).toEqual({ tables: 7, x: 0, y: 2 });
  });
  it('an event report needs an event and tickets, and every ticket type a name; money is never kept for two currencies', () => {
    expect(parseEventSales({ event: {} })).toBeNull();
    expect(parseEventSales({ tickets: {} })).toBeNull();
    expect(parseEventSales({ event: {}, tickets: { by_tier: [{ tier: 'A' }, 5] } })).toBeNull();
    expect(parseEventSales({ event: {}, tickets: {}, venues: [{ venue_name: 'x' }] })).toBeNull();
    expect(parseEventSales({ event: {}, tickets: {}, venues: ['x'] })).toBeNull();
    const mixed = parseEventSales({ event: { title: 'E' }, tickets: { currency_mixed: true, currency: 'CAD', gross_cents: 500 } })!;
    expect([mixed.tickets.grossCents, mixed.tickets.currency, mixed.eventTitle, mixed.eventCapacity]).toEqual([null, null, 'E', null]);
    const one = parseEventSales({ event: { capacity: 0 }, tickets: { currency: 'CAD', gross_cents: 0 } })!;
    expect([one.tickets.grossCents, one.eventCapacity, one.eventTitle]).toEqual([0, 0, 'Event']);
    expect(parseEventSales({ event: {}, tickets: { currency: 'CAD' } })!.tickets.grossCents).toBeNull();
  });
  it('a grant of a kind the app does not know is dropped', () => {
    const s = parseEventSales({ event: {}, tickets: {}, venues: [{ agreement_id: 'a', in_force: true, grants: [{ key: 'weather', allowed: true }, { key: 'chat', allowed: true }, 'x'] }] })!;
    expect(s.clubs[0].grants.map((g) => g.key)).toEqual(['chat']);
  });
});

describe('figures and words', () => {
  it('dollars, grouped, with cents; and a negative amount exactly as the app writes it', () => {
    expect([formatDollars(0), formatDollars(5), formatDollars(99), formatDollars(100), formatDollars(123456), formatDollars(123456789), formatDollars(100000000)]).toEqual(['$0.00', '$0.05', '$0.99', '$1.00', '$1,234.56', '$1,234,567.89', '$1,000,000.00']);
    expect([formatDollars(-250), formatDollars(-50), formatDollars(-5)]).toEqual(['$-2.50', '$0.50', '$0.95']);
  });
  it('a night, with its weekday; a date that does not exist or is not a date is returned as it came', () => {
    expect([formatNight('2026-11-14'), formatNight('2026-10-10'), formatNight('2026-12-31'), formatNight('2026-01-01'), formatNight('2024-02-29')]).toEqual(['Saturday Nov 14', 'Saturday Oct 10', 'Thursday Dec 31', 'Thursday Jan 1', 'Thursday Feb 29']);
    expect([formatNight('2026-02-30'), formatNight('2026-13-01'), formatNight('soon'), formatNight('2026-11-1'), formatNight('')]).toEqual(['2026-02-30', '2026-13-01', 'soon', '2026-11-1', '']);
    expect([formatNight('2026-11-15'), formatNight('2026-11-16')]).toEqual(['Sunday Nov 15', 'Monday Nov 16']);
  });
  it('security kinds have their words; one that is not listed is shown as it came', () => {
    expect([kindLabel('fight'), kindLabel('intoxicated'), kindLabel('property'), kindLabel('weapon'), kindLabel('other'), kindLabel('mystery')]).toEqual(['Fight', 'Intoxicated guest', 'Property damage', 'Weapon', 'Other', 'mystery']);
  });
  it('an event status in words', () => {
    expect([eventStatusWords('draft'), eventStatusWords('published'), eventStatusWords(''), eventStatusWords('sold_out'), eventStatusWords('cancelled')]).toEqual(['Draft (private)', 'Published', 'Unknown', 'Sold out', 'Cancelled']);
  });
});

describe('times are in the club\'s time zone', () => {
  const t = new Date('2026-11-15T03:12:00Z');
  it('24-hour time, with midnight as 00 and the zone deciding', () => {
    expect([timeOfDay(t, 'UTC'), timeOfDay(t, 'America/Toronto'), timeOfDay(t, 'America/Vancouver'), timeOfDay(t, 'Asia/Kolkata')]).toEqual(['03:12', '22:12', '19:12', '08:42']);
    expect(timeOfDay(new Date('2026-11-15T05:05:00Z'), 'UTC')).toBe('05:05');
    expect(timeOfDay(new Date('2026-11-15T00:00:00Z'), 'UTC')).toBe('00:00');
    expect(timeOfDay(new Date('2026-11-15T05:00:00Z'), 'America/Toronto')).toBe('00:00');
    expect(timeOfDay(new Date('2026-11-15T23:59:00Z'), 'UTC')).toBe('23:59');
  });
  it('summer time is respected', () => {
    expect([timeOfDay(new Date('2026-07-01T02:00:00Z'), 'America/Toronto'), timeOfDay(new Date('2026-12-01T02:00:00Z'), 'America/Toronto')]).toEqual(['22:00', '21:00']);
  });
  it('weekday, month and day with the 24-hour time', () => {
    expect([whenLabel(t, 'UTC'), whenLabel(t, 'America/Toronto'), whenLabel(new Date('2026-12-05T04:30:00Z'), 'America/Toronto')]).toEqual(['Sun Nov 15, 03:12', 'Sat Nov 14, 22:12', 'Fri Dec 4, 23:30']);
  });
  it('12-hour time with AM and PM, and noon and midnight', () => {
    expect([clock12(t, 'UTC'), clock12(t, 'America/Toronto'), clock12(new Date('2026-11-15T12:00:00Z'), 'UTC'), clock12(new Date('2026-11-15T00:30:00Z'), 'UTC'), clock12(new Date('2026-11-15T13:05:00Z'), 'UTC')]).toEqual(['3:12 AM', '10:12 PM', '12:00 PM', '12:30 AM', '1:05 PM']);
  });
  it('month, day and 12-hour time', () => {
    expect([atLabel(t, 'UTC'), atLabel(t, 'America/Toronto'), atLabel(new Date('2026-11-15T13:20:00Z'), 'UTC')]).toEqual(['Nov 15, 3:12 AM', 'Nov 14, 10:12 PM', 'Nov 15, 1:20 PM']);
  });
  it('the day an event starts is the club\'s day, not the UTC day', () => {
    expect([eventDate(new Date('2026-11-15T03:30:00Z'), 'America/Toronto'), eventDate(new Date('2026-11-15T03:30:00Z'), 'UTC'), eventDate(new Date('2026-11-14T22:00:00Z'), 'Asia/Tokyo')]).toEqual(['2026-11-14', '2026-11-15', '2026-11-15']);
  });
  it('the same report says the club\'s time in the club\'s zone', () => {
    const fixture = JSON.parse(readFileSync(join(dir, 'night_final_with_times.json'), 'utf8'));
    const toronto = documentForJob({ kind: fixture.kind, time_zone: 'America/Toronto', ...fixture.input })!;
    expect(toronto.statusLine).toBe('FINAL · closed 22:12 by Mia Manager');
    const event = JSON.parse(readFileSync(join(dir, 'event_with_times.json'), 'utf8'));
    const doc = documentForJob({ kind: event.kind, time_zone: 'America/Toronto', ...event.input })!;
    expect(doc.sections[0].rows.slice(1, 3).map((r) => r.value)).toEqual(['Sat Nov 14, 17:00', 'Sat Nov 14, 23:00']);
    expect(doc.statusLine).toBe('Figures as of 20:30. Only what each club has chosen to share is included.');
    expect(doc.fileName).toBe('night-one-2026-11-14-event-report.pdf');
  });
});

describe('a job\'s data becomes a document, or nothing', () => {
  it('no data, data of an unknown kind and data in the wrong shape give nothing', () => {
    expect([documentForJob(null), documentForJob('x'), documentForJob({}), documentForJob({ kind: 'mystery', report: {} }), documentForJob({ kind: 'venue_night' }), documentForJob({ kind: 'owner_combined', report: [] }), documentForJob({ kind: 'organizer_sales', report: {} })]).toEqual([null, null, null, null, null, null, null]);
  });
  it('a time zone that does not exist gives nothing; one that is missing is Toronto', () => {
    const fixture = JSON.parse(readFileSync(join(dir, 'night_final_with_times.json'), 'utf8'));
    expect(documentForJob({ kind: fixture.kind, time_zone: 'Mars/Olympus', ...fixture.input })).toBeNull();
    expect(documentForJob({ kind: fixture.kind, ...fixture.input })!.statusLine).toBe('FINAL · closed 22:12 by Mia Manager');
    expect(documentForJob({ kind: fixture.kind, time_zone: '', ...fixture.input })!.statusLine).toBe('FINAL · closed 22:12 by Mia Manager');
  });
  it('a file name the delivery log would refuse is made acceptable', () => {
    expect(safeFileName('club-a-2026-11-14-full-final.pdf')).toBe('club-a-2026-11-14-full-final.pdf');
    expect(safeFileName(`${'a'.repeat(120)}.pdf`)).toBe(`${'a'.repeat(95)}.pdf`);
    expect(safeFileName('bad<name>.pdf')).toBe('bad-name.pdf');
    expect(safeFileName('???.pdf')).toBe('report.pdf');
    expect(safeFileName('')).toBe('report.pdf');
    expect(safeFileName(`${'a'.repeat(94)}--x.pdf`)).toMatch(/^[A-Za-z0-9 _.()-]{1,95}\.pdf$/);
  });
  it('a club with a very long name still gets a usable file name', () => {
    const fixture = JSON.parse(readFileSync(join(dir, 'night_full_final.json'), 'utf8'));
    const long = { ...fixture.input, report: { ...fixture.input.report, venue_name: 'The Extraordinarily Long Named Night Club And Lounge Of The Entire Downtown District '.repeat(3) } };
    const doc = documentForJob({ kind: fixture.kind, ...long })!;
    expect(doc.fileName).toMatch(/^[A-Za-z0-9 _.()-]{1,95}\.pdf$/);
  });
});
