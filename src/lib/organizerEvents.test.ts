import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import {
  EMPTY_EVENT_FORM,
  eventFormFrom,
  eventPayload,
  EVENT_LIMITS,
  formatEventWhen,
  groupEvents,
  hasEnded,
  localToIso,
  parseOrgEvent,
  sentence,
  statusNote,
  STATUS_LABEL,
  toDatetimeLocal,
  validateEventForm,
  type EventForm,
  type OrgEvent,
} from './organizerEvents';

const ev = (over: Partial<OrgEvent> = {}): OrgEvent => ({
  eventId: 'e1', title: 'Rooftop Party', description: 'Dancing', venueName: 'The Roof', address: '1 King St W',
  startDate: '2031-10-24T22:00:00Z', endDate: '2031-10-25T04:00:00Z', category: 'Party', capacity: 250, coverImageUrl: null,
  status: 'draft', ticketTierCount: 0, ...over,
});

const good: EventForm = { ...EMPTY_EVENT_FORM, title: 'Party', description: 'Fun', venueName: 'The Roof', startsAt: '2031-10-24T22:00' };
const problemsOf = (over: Partial<EventForm>) => validateEventForm({ ...good, ...over });

describe('reading a list_org_events row', () => {
  const row = {
    event_id: 'e1', title: 'Rooftop Party', description: 'Dancing', venue_name: 'The Roof', address: '1 King St W', start_date: '2031-10-24T22:00:00+00:00',
    end_date: null, category: 'Party', capacity: 250, cover_image_url: 'https://img.example/a.jpg', status: 'draft', ticket_tier_count: 2,
  };

  it('keeps what it needs', () => {
    expect(parseOrgEvent(row)).toEqual({
      eventId: 'e1', title: 'Rooftop Party', description: 'Dancing', venueName: 'The Roof', address: '1 King St W', startDate: '2031-10-24T22:00:00+00:00',
      endDate: null, category: 'Party', capacity: 250, coverImageUrl: 'https://img.example/a.jpg', status: 'draft', ticketTierCount: 2,
    });
  });

  it('drops a row with no id, no title or no start', () => {
    for (const key of ['event_id', 'title', 'start_date']) expect(parseOrgEvent({ ...row, [key]: null })).toBeNull();
    expect(parseOrgEvent({ ...row, title: '' })).toBeNull();
  });

  it('only exactly "draft" is a draft: an unknown status must never unlock editing or removing', () => {
    expect(parseOrgEvent({ ...row, status: 'draft' })?.status).toBe('draft');
    for (const s of ['published', 'cancelled', 'DRAFT', '', null, undefined, 3]) expect(parseOrgEvent({ ...row, status: s })?.status).toBe('published');
  });

  it('is forgiving about the optional parts', () => {
    const e = parseOrgEvent({ event_id: 'e1', title: 't', start_date: '2031-10-24T22:00:00Z', capacity: 1.5, ticket_tier_count: 'x', description: null, venue_name: null });
    expect([e?.capacity, e?.ticketTierCount, e?.description, e?.venueName, e?.address, e?.endDate]).toEqual([null, 0, '', '', null, null]);
  });
});

describe('the date boxes', () => {
  it('a time typed into a box and shown again is the same time, in whatever zone this runs (no drifting)', () => {
    for (const local of ['2031-01-15T09:00', '2031-03-09T12:30', '2031-06-30T22:45', '2031-10-24T22:00', '2031-11-02T12:00', '2031-12-31T23:59', '2032-02-29T12:00']) {
      const iso = localToIso(local);
      expect(iso, local).not.toBeNull();
      expect(toDatetimeLocal(iso), local).toBe(local);
    }
  });

  it('opening a saved event and saving it unchanged sends the same instants back', () => {
    const e = ev();
    const payload = eventPayload(eventFormFrom(e));
    expect(new Date(payload.start_date as string).getTime()).toBe(new Date(e.startDate).getTime());
    expect(new Date(payload.end_date as string).getTime()).toBe(new Date(e.endDate as string).getTime());
  });

  it('the instant sent carries its time zone (the database refuses one without)', () => {
    expect(localToIso('2031-10-24T22:00')).toMatch(/Z$/);
  });

  it('what is not a real date and time is null', () => {
    for (const bad of ['', '  ', 'tomorrow', '2031-02-30T10:00', '2031-13-01T10:00', '2031-10-24T25:00', '2031-10-24T10:60', '2031-10-24 22:00', '2031-10-24', '2031-10-24T22:00:00']) {
      expect(localToIso(bad), JSON.stringify(bad)).toBeNull();
    }
  });

  it('a stored value that is not a date shows as an empty box', () => {
    expect(toDatetimeLocal(null)).toBe('');
    expect(toDatetimeLocal('not a date')).toBe('');
  });
});

describe('the form', () => {
  it('a new form needs a title, a description, a venue and a start, and says so', () => {
    expect(validateEventForm(EMPTY_EVENT_FORM)).toEqual([
      'Give the event a title.',
      'Describe the event for your guests.',
      'Say where it is held: the venue or place name.',
      'Choose when it starts.',
    ]);
  });

  it('the smallest valid form needs nothing else', () => {
    expect(validateEventForm(good)).toEqual([]);
  });

  it.each([
    [{ title: '   ' }, 'Give the event a title.'],
    [{ title: 'x'.repeat(121) }, 'The title must be 120 characters or fewer.'],
    [{ description: ' ' }, 'Describe the event for your guests.'],
    [{ description: 'x'.repeat(5001) }, 'The description must be 5000 characters or fewer.'],
    [{ venueName: '' }, 'Say where it is held: the venue or place name.'],
    [{ venueName: 'x'.repeat(121) }, 'The venue name must be 120 characters or fewer.'],
    [{ address: 'x'.repeat(201) }, 'The address must be 200 characters or fewer.'],
    [{ category: 'x'.repeat(41) }, 'The category must be 40 characters or fewer.'],
    [{ startsAt: '' }, 'Choose when it starts.'],
    [{ startsAt: '2031-02-30T10:00' }, 'The start is not a real date and time.'],
    [{ endsAt: '2031-02-30T10:00' }, 'The end is not a real date and time.'],
    [{ endsAt: '2031-10-24T21:00' }, 'The end must be after the start.'],
    [{ endsAt: '2031-10-24T22:00' }, 'The end must be after the start.'],
    [{ capacity: '-1' }, 'Capacity must be a whole number from 0 to 100000, or left empty.'],
    [{ capacity: '1.5' }, 'Capacity must be a whole number from 0 to 100000, or left empty.'],
    [{ capacity: 'lots' }, 'Capacity must be a whole number from 0 to 100000, or left empty.'],
    [{ capacity: '100001' }, 'Capacity must be a whole number from 0 to 100000, or left empty.'],
  ] as [Partial<EventForm>, string][])('%j is refused: %s', (over, message) => {
    expect(problemsOf(over)).toContain(message);
  });

  it('the limits are inclusive', () => {
    expect(problemsOf({ title: 'x'.repeat(120), description: 'x'.repeat(5000), venueName: 'x'.repeat(120), address: 'x'.repeat(200), category: 'x'.repeat(40) })).toEqual([]);
    expect(problemsOf({ capacity: '0' })).toEqual([]);
    expect(problemsOf({ capacity: '100000' })).toEqual([]);
    expect(problemsOf({ endsAt: '2031-10-24T22:01' })).toEqual([]);
  });

  it('an end is not checked against a start that is itself wrong (one problem at a time)', () => {
    expect(problemsOf({ startsAt: '', endsAt: '2031-10-24T21:00' })).toEqual(['Choose when it starts.']);
  });
});

describe('what is sent', () => {
  it('the smallest form: required fields, everything optional empty as "none"', () => {
    expect(eventPayload(good)).toEqual({
      title: 'Party', description: 'Fun', venue_name: 'The Roof', address: null, start_date: localToIso('2031-10-24T22:00'), end_date: null,
      category: null, capacity: null, cover_image_url: null,
    });
  });

  it('text is trimmed and a blank optional field is sent as null so it can be cleared', () => {
    const p = eventPayload({ ...good, title: '  Party ', address: '   ', category: ' Club night ', capacity: ' 120 ', coverImageUrl: ' https://img.example/a.jpg ' });
    expect([p.title, p.address, p.category, p.capacity, p.cover_image_url]).toEqual(['Party', null, 'Club night', 120, 'https://img.example/a.jpg']);
  });

  it('never carries a status, a business, a slug or anything else an organizer must not set', () => {
    const keys = Object.keys(eventPayload(good));
    for (const forbidden of ['status', 'org_id', 'slug', 'organizer_name', 'organizer_verified', 'venue_id', 'banner_image_url', 'gallery', 'lineup']) {
      expect(keys).not.toContain(forbidden);
    }
  });

  it('opening a saved event and saving it unchanged sends the same text and numbers back', () => {
    const e = ev({ coverImageUrl: 'https://img.example/a.jpg' });
    const p = eventPayload(eventFormFrom(e));
    expect([p.title, p.description, p.venue_name, p.address, p.category, p.capacity, p.cover_image_url]).toEqual(['Rooftop Party', 'Dancing', 'The Roof', '1 King St W', 'Party', 250, 'https://img.example/a.jpg']);
    expect(validateEventForm(eventFormFrom(e))).toEqual([]);
  });

  it('an event with nothing optional opens with empty boxes', () => {
    const f = eventFormFrom(ev({ address: null, endDate: null, category: null, capacity: null, coverImageUrl: null }));
    expect([f.address, f.endsAt, f.category, f.capacity, f.coverImageUrl]).toEqual(['', '', '', '', '']);
  });
});

describe('the list', () => {
  const now = new Date('2031-10-24T12:00:00Z');
  const draftLate = ev({ eventId: 'd2', status: 'draft', startDate: '2031-12-01T22:00:00Z', endDate: null });
  const draftSoon = ev({ eventId: 'd1', status: 'draft', startDate: '2031-11-01T22:00:00Z', endDate: null });
  const draftPast = ev({ eventId: 'd0', status: 'draft', startDate: '2031-01-01T22:00:00Z', endDate: null });
  const soon = ev({ eventId: 'p1', status: 'published', startDate: '2031-10-30T22:00:00Z', endDate: null });
  const later = ev({ eventId: 'p2', status: 'published', startDate: '2031-12-30T22:00:00Z', endDate: null });
  const old = ev({ eventId: 'p3', status: 'published', startDate: '2031-06-01T22:00:00Z', endDate: '2031-06-02T04:00:00Z' });
  const older = ev({ eventId: 'p4', status: 'published', startDate: '2030-06-01T22:00:00Z', endDate: null });

  it('drafts first (soonest first, even a past one: it still needs the organizer), then upcoming soonest first, then past most recent first', () => {
    const g = groupEvents([later, old, draftLate, soon, older, draftPast, draftSoon], now);
    expect(g.drafts.map((e) => e.eventId)).toEqual(['d0', 'd1', 'd2']);
    expect(g.upcoming.map((e) => e.eventId)).toEqual(['p1', 'p2']);
    expect(g.past.map((e) => e.eventId)).toEqual(['p3', 'p4']);
  });

  it('every event is in exactly one group', () => {
    const all = [later, old, draftLate, soon, older, draftPast, draftSoon];
    const g = groupEvents(all, now);
    expect(g.drafts.length + g.upcoming.length + g.past.length).toBe(all.length);
  });

  it('an event with no end lasts 12 hours, so an overnight party is not past at midnight; with an end, the end counts', () => {
    const party = ev({ status: 'published', startDate: '2031-10-24T22:00:00Z', endDate: null });
    expect(hasEnded(party, new Date('2031-10-25T08:00:00Z'))).toBe(false);
    expect(hasEnded(party, new Date('2031-10-25T10:01:00Z'))).toBe(true);
    const ends = ev({ status: 'published', startDate: '2031-10-24T22:00:00Z', endDate: '2031-10-25T02:00:00Z' });
    expect(hasEnded(ends, new Date('2031-10-25T01:59:00Z'))).toBe(false);
    expect(hasEnded(ends, new Date('2031-10-25T02:01:00Z'))).toBe(true);
  });

  it('an empty list has empty groups', () => {
    expect(groupEvents([], now)).toEqual({ drafts: [], upcoming: [], past: [] });
  });

  it('does not reorder what it was given', () => {
    const input = [later, soon];
    groupEvents(input, now);
    expect(input.map((e) => e.eventId)).toEqual(['p2', 'p1']);
  });

  it('says what each status means for the organizer', () => {
    expect(STATUS_LABEL).toEqual({ draft: 'Draft', published: 'Published' });
    expect(statusNote('draft')).toMatch(/Only you can see this/);
    expect(statusNote('published')).toMatch(/Contact BottlesUp/);
  });
});

describe('how a time reads', () => {
  const tz = 'America/Toronto';

  it('in the zone it is asked for, with the day', () => {
    const s = formatEventWhen('2031-10-24T22:00:00Z', null, tz);
    expect(s).toMatch(/Fri/);
    expect(s).toMatch(/Oct 24, 2031/);
    expect(s).toMatch(/6:00/);
  });

  it('a same-evening end shows only a clock time; an end on another day shows the day too', () => {
    const same = formatEventWhen('2031-10-24T22:00:00Z', '2031-10-25T02:30:00Z', tz);
    expect(same).toMatch(/ to 10:30/);
    expect(same).not.toMatch(/ to .*Oct/);
    const next = formatEventWhen('2031-10-24T22:00:00Z', '2031-10-25T14:00:00Z', tz);
    expect(next).toMatch(/ to .*Sat.*Oct 25/);
  });

  it('a value that is not a date is an empty string, never "Invalid Date"', () => {
    expect(formatEventWhen('nope', null, tz)).toBe('');
    expect(formatEventWhen('2031-10-24T22:00:00Z', 'nope', tz)).toMatch(/Oct 24/);
  });
});

describe('a database message for a person', () => {
  it('capitalises and ends with a full stop', () => {
    expect(sentence('this event is published, so only BottlesUp can change it')).toBe('This event is published, so only BottlesUp can change it.');
    expect(sentence('Already a sentence.')).toBe('Already a sentence.');
    expect(sentence('  title is required  ')).toBe('Title is required.');
    expect(sentence('')).toBe('Please try again.');
  });
});

// The form and the database must agree on which fields exist and how long they may be: the database refuses a key it does not
// know, so a field added to the form and forgotten in the SQL would fail for every organizer. Read from the migration so the two
// cannot drift apart.
describe('agrees with the database', () => {
  const sql = readFileSync(join(__dirname, '..', '..', 'supabase', 'migrations', '20261013100000_organizer_events.sql'), 'utf8');

  it('every field the form sends is one the database accepts, and every field the database accepts is sent', () => {
    const list = /org_event_only_keys\(p_details,\s*array\[([^\]]*)\]\)/.exec(sql)?.[1] ?? '';
    const allowed = [...list.matchAll(/'(\w+)'/g)].map((m) => m[1]).sort();
    expect(allowed.length).toBeGreaterThan(5);
    expect(Object.keys(eventPayload(good)).sort()).toEqual(allowed);
  });

  it('the limits on the form are the database limits', () => {
    expect(sql).toContain(`'title', 'title', ${EVENT_LIMITS.title}, true`);
    expect(sql).toContain(`'description', 'description', ${EVENT_LIMITS.description}, true`);
    expect(sql).toContain(`'venue_name', 'venue name', ${EVENT_LIMITS.venueName}, true`);
    expect(sql).toContain(`'address', 'address', ${EVENT_LIMITS.address}, false`);
    expect(sql).toContain(`'category', 'category', ${EVENT_LIMITS.category}, false`);
    expect(sql).toContain(`'capacity', 'capacity', 0, ${EVENT_LIMITS.capacityMax}`);
    expect(sql).toContain(`v_n >= ${EVENT_LIMITS.perBusiness}`);
    expect(sql).toContain(`${EVENT_LIMITS.perBusiness} events at most`);
  });

  it('the fields the database requires on creation are the ones the form requires', () => {
    const required = [...sql.matchAll(/org_event_(?:text|time)\(p_details, '(\w+)', '[^']+'(?:, \d+)?, true\)/g)].map((m) => m[1]);
    expect([...new Set(required)].sort()).toEqual(['description', 'start_date', 'title', 'venue_name']);
  });

  it('the function names and argument names the app uses are the ones the database defines', () => {
    for (const signature of ['list_org_events(p_org uuid)', 'save_org_event(p_org uuid, p_event uuid, p_details jsonb)', 'remove_org_event(p_org uuid, p_event uuid)']) {
      expect(sql).toContain(`create function public.${signature}`);
    }
  });

  it('an organizer cannot publish: the database field list has no status, business or slug', () => {
    const list = /org_event_only_keys\(p_details,\s*array\[([^\]]*)\]\)/.exec(sql)?.[1] ?? '';
    for (const forbidden of ['status', 'org_id', 'slug', 'organizer_name', 'organizer_verified', 'venue_id']) expect(list).not.toContain(`'${forbidden}'`);
  });
});
