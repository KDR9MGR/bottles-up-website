// The organizer's own events (client feedback, 10 Oct 2026: "Event organizer page needs a create event"). Pure rules, no database
// and no React, so they can be tested. Each check mirrors the database function that finally decides (save_org_event in
// supabase/migrations/20261013100000_organizer_events.sql): the form says what is wrong in plain words before anything is sent, and
// the database still refuses whatever gets past it.
//
// What an organizer can do: create a DRAFT, change it, remove it. What it cannot: publish (the BottlesUp team does, in the CMS),
// change or remove a published event (tickets may have been sold), or touch another business's events. The form below has no
// status field for that reason, and the payload never carries one.

export const EVENT_LIMITS = {
  title: 120,
  description: 5000,
  venueName: 120,
  address: 200,
  category: 40,
  capacityMax: 100000,
  /** Events one business can hold, drafts included. */
  perBusiness: 200,
} as const;

export type OrgEventStatus = 'draft' | 'published';

export interface OrgEvent {
  eventId: string;
  title: string;
  description: string;
  venueName: string;
  address: string | null;
  /** ISO timestamp with its time zone, as the database returns it. */
  startDate: string;
  endDate: string | null;
  category: string | null;
  capacity: number | null;
  coverImageUrl: string | null;
  status: OrgEventStatus;
  ticketTierCount: number;
}

const text = (v: unknown): string | null => (typeof v === 'string' && v !== '' ? v : null);
const int = (v: unknown): number | null => (typeof v === 'number' && Number.isInteger(v) ? v : null);

/**
 * One list_org_events row. A row without an id, a title or a start is dropped. Anything that is not exactly 'draft' is read as
 * published: drafts are the only events the organizer may change or remove, so an unknown status must never unlock that.
 */
export function parseOrgEvent(row: Record<string, unknown>): OrgEvent | null {
  const eventId = text(row.event_id);
  const title = text(row.title);
  const startDate = text(row.start_date);
  if (!eventId || !title || !startDate) return null;
  return {
    eventId,
    title,
    description: typeof row.description === 'string' ? row.description : '',
    venueName: typeof row.venue_name === 'string' ? row.venue_name : '',
    address: text(row.address),
    startDate,
    endDate: text(row.end_date),
    category: text(row.category),
    capacity: int(row.capacity),
    coverImageUrl: text(row.cover_image_url),
    status: row.status === 'draft' ? 'draft' : 'published',
    ticketTierCount: int(row.ticket_tier_count) ?? 0,
  };
}

export const STATUS_LABEL: Record<OrgEventStatus, string> = {
  draft: 'Draft',
  published: 'Published',
};

/** What the status means for the organizer, in one line. */
export function statusNote(status: OrgEventStatus): string {
  return status === 'draft'
    ? 'Only you can see this. The BottlesUp team publishes it when it is ready.'
    : 'Live on the website. Contact BottlesUp to change it.';
}

// ---------------------------------------------------------------------------
// The form
// ---------------------------------------------------------------------------

/** Everything is a string, as typed into the boxes. `startsAt` and `endsAt` are "YYYY-MM-DDTHH:mm" in the person's own time. */
export interface EventForm {
  title: string;
  description: string;
  venueName: string;
  address: string;
  startsAt: string;
  endsAt: string;
  category: string;
  capacity: string;
  coverImageUrl: string;
}

export const EMPTY_EVENT_FORM: EventForm = {
  title: '', description: '', venueName: '', address: '', startsAt: '', endsAt: '', category: '', capacity: '', coverImageUrl: '',
};

const pad = (n: number) => String(n).padStart(2, '0');

/**
 * A stored instant as the wall-clock time the person sees, for a datetime-local box. This goes through Date's LOCAL getters on
 * purpose: slicing the ISO string would show the UTC time, and saving it back unedited would move the event by the person's
 * offset every time (the "date keeps drifting" bug the CMS form had).
 */
export function toDatetimeLocal(iso: string | null): string {
  if (!iso) return '';
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return '';
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

/** The wall-clock time typed into a box as an ISO instant with its time zone, or null when it is not a real date and time. */
export function localToIso(local: string): string | null {
  const m = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})$/.exec(local.trim());
  if (!m) return null;
  const [y, mo, d, h, mi] = m.slice(1).map(Number);
  const date = new Date(y, mo - 1, d, h, mi);
  // new Date rolls 31 February into March: a date that did not survive the round trip was not a real one.
  if (date.getFullYear() !== y || date.getMonth() !== mo - 1 || date.getDate() !== d || date.getHours() !== h || date.getMinutes() !== mi) return null;
  return date.toISOString();
}

export function eventFormFrom(e: OrgEvent): EventForm {
  return {
    title: e.title,
    description: e.description,
    venueName: e.venueName,
    address: e.address ?? '',
    startsAt: toDatetimeLocal(e.startDate),
    endsAt: toDatetimeLocal(e.endDate),
    category: e.category ?? '',
    capacity: e.capacity === null ? '' : String(e.capacity),
    coverImageUrl: e.coverImageUrl ?? '',
  };
}

/** Plain-language problems with the form; an empty list means it can be sent. */
export function validateEventForm(f: EventForm): string[] {
  const p: string[] = [];
  const len = (s: string) => s.trim().length;

  if (len(f.title) === 0) p.push('Give the event a title.');
  else if (len(f.title) > EVENT_LIMITS.title) p.push(`The title must be ${EVENT_LIMITS.title} characters or fewer.`);

  if (len(f.description) === 0) p.push('Describe the event for your guests.');
  else if (len(f.description) > EVENT_LIMITS.description) p.push(`The description must be ${EVENT_LIMITS.description} characters or fewer.`);

  if (len(f.venueName) === 0) p.push('Say where it is held: the venue or place name.');
  else if (len(f.venueName) > EVENT_LIMITS.venueName) p.push(`The venue name must be ${EVENT_LIMITS.venueName} characters or fewer.`);

  if (len(f.address) > EVENT_LIMITS.address) p.push(`The address must be ${EVENT_LIMITS.address} characters or fewer.`);
  if (len(f.category) > EVENT_LIMITS.category) p.push(`The category must be ${EVENT_LIMITS.category} characters or fewer.`);

  const start = f.startsAt.trim() === '' ? null : localToIso(f.startsAt);
  if (f.startsAt.trim() === '') p.push('Choose when it starts.');
  else if (start === null) p.push('The start is not a real date and time.');

  if (f.endsAt.trim() !== '') {
    const end = localToIso(f.endsAt);
    if (end === null) p.push('The end is not a real date and time.');
    else if (start !== null && new Date(end).getTime() <= new Date(start).getTime()) p.push('The end must be after the start.');
  }

  if (f.capacity.trim() !== '') {
    const n = /^\d{1,9}$/.test(f.capacity.trim()) ? Number(f.capacity.trim()) : null;
    if (n === null || n > EVENT_LIMITS.capacityMax) p.push(`Capacity must be a whole number from 0 to ${EVENT_LIMITS.capacityMax}, or left empty.`);
  }
  return p;
}

/**
 * What is sent: every field the form shows, and nothing it does not. In particular never a status, a business or a slug: the
 * database refuses those, and an organizer cannot publish. Only call this when validateEventForm returned nothing.
 */
export function eventPayload(f: EventForm): Record<string, unknown> {
  const opt = (s: string) => (s.trim() === '' ? null : s.trim());
  return {
    title: f.title.trim(),
    description: f.description.trim(),
    venue_name: f.venueName.trim(),
    address: opt(f.address),
    start_date: localToIso(f.startsAt),
    end_date: f.endsAt.trim() === '' ? null : localToIso(f.endsAt),
    category: opt(f.category),
    capacity: f.capacity.trim() === '' ? null : Number(f.capacity.trim()),
    cover_image_url: opt(f.coverImageUrl),
  };
}

// ---------------------------------------------------------------------------
// The list
// ---------------------------------------------------------------------------

/** An event with no end is treated as lasting this long, so an overnight party is not "past" at midnight. */
export const OPEN_ENDED_HOURS = 12;

export function hasEnded(e: OrgEvent, now: Date): boolean {
  const end = e.endDate ? new Date(e.endDate).getTime() : new Date(e.startDate).getTime() + OPEN_ENDED_HOURS * 3_600_000;
  return end < now.getTime();
}

export interface EventGroups {
  drafts: OrgEvent[];
  upcoming: OrgEvent[];
  past: OrgEvent[];
}

/**
 * Drafts first (they are the ones that need the organizer), then what is coming up soonest first, then what has happened
 * most recent first.
 */
export function groupEvents(events: OrgEvent[], now: Date): EventGroups {
  const byStart = (a: OrgEvent, b: OrgEvent) => new Date(a.startDate).getTime() - new Date(b.startDate).getTime();
  const drafts = events.filter((e) => e.status === 'draft').sort(byStart);
  const live = events.filter((e) => e.status !== 'draft');
  return {
    drafts,
    upcoming: live.filter((e) => !hasEnded(e, now)).sort(byStart),
    past: live.filter((e) => hasEnded(e, now)).sort((a, b) => byStart(b, a)),
  };
}

/** "Fri, Oct 24, 2031, 6:00 PM" and, when there is an end, "to 12:00 AM" (or the other date when it ends on another day). */
export function formatEventWhen(startIso: string, endIso: string | null, timeZone?: string): string {
  const start = new Date(startIso);
  if (Number.isNaN(start.getTime())) return '';
  const full = new Intl.DateTimeFormat('en-CA', { weekday: 'short', month: 'short', day: 'numeric', year: 'numeric', hour: 'numeric', minute: '2-digit', timeZone });
  const clock = new Intl.DateTimeFormat('en-CA', { hour: 'numeric', minute: '2-digit', timeZone });
  const day = new Intl.DateTimeFormat('en-CA', { year: 'numeric', month: '2-digit', day: '2-digit', timeZone });
  const base = full.format(start);
  if (!endIso) return base;
  const end = new Date(endIso);
  if (Number.isNaN(end.getTime())) return base;
  return day.format(start) === day.format(end) ? `${base} to ${clock.format(end)}` : `${base} to ${full.format(end)}`;
}

/** The database writes short lower-case sentences for developers. This makes one a sentence for a person. */
export function sentence(message: string): string {
  const t = message.trim();
  if (t === '') return 'Please try again.';
  const s = t.charAt(0).toUpperCase() + t.slice(1);
  return /[.!?]$/.test(s) ? s : `${s}.`;
}
