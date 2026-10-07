// The owner's Tables & Bookings view (client brief, section 4): which nights to look at, how a booking's status reads, and how
// a night's bookings are grouped and counted. Pure functions, tested without a browser. The database decides who may see what
// and which night a booking belongs to (list_venue_bookings); nothing here grants access.

import { formatMonthDay, formatWeekday } from './bookingNight';
import { currentNight } from './workspaceContext';

export interface BookingRow {
  bookingId: string;
  /** The business night, not the calendar date it is stored under: a 1:00 AM table belongs to the night before. */
  nightDate: string;
  /** "21:00:00" */
  startTime: string;
  slotLabel: string | null;
  tableName: string;
  guestCount: number;
  customerName: string;
  customerEmail: string;
  customerPhone: string | null;
  /** As stored: paid, pending, failed, refunded, cancelled. */
  status: string;
  confirmationCode: string | null;
  checkedInAt: string | null;
  amountTotalCents: number;
  depositCents: number;
  currency: string;
}

// ---------------------------------------------------------------------------
// Status
// ---------------------------------------------------------------------------

export type StatusTone = 'good' | 'wait' | 'bad' | 'neutral';

export interface StatusInfo {
  label: string;
  tone: StatusTone;
  /** Counts as a booking the venue should expect: paid, and not cancelled or refunded. */
  confirmed: boolean;
}

/** What a stored status means to a venue. A status this code has not seen is shown as it is, never as confirmed. */
export function statusInfo(status: string): StatusInfo {
  switch (status) {
    case 'paid': return { label: 'Confirmed', tone: 'good', confirmed: true };
    case 'pending': return { label: 'Awaiting payment', tone: 'wait', confirmed: false };
    case 'failed': return { label: 'Payment failed', tone: 'bad', confirmed: false };
    case 'refunded': return { label: 'Refunded', tone: 'neutral', confirmed: false };
    case 'cancelled': return { label: 'Cancelled', tone: 'neutral', confirmed: false };
    default: return { label: status ? status.charAt(0).toUpperCase() + status.slice(1) : 'Unknown', tone: 'neutral', confirmed: false };
  }
}

export type BookingFilter = 'confirmed' | 'all';

export function applyFilter(rows: readonly BookingRow[], filter: BookingFilter): BookingRow[] {
  return filter === 'all' ? [...rows] : rows.filter((r) => statusInfo(r.status).confirmed);
}

// ---------------------------------------------------------------------------
// Grouping and counting
// ---------------------------------------------------------------------------

export interface NightGroup {
  night: string;
  /** "Saturday Oct 10" */
  label: string;
  rows: BookingRow[];
  /** Guests in the confirmed bookings of this night. */
  guests: number;
}

export function formatNight(isoDate: string): string {
  return `${formatWeekday(isoDate)} ${formatMonthDay(isoDate)}`;
}

/** Rows grouped by night, in the order they arrive (the database already sorts them). */
export function groupByNight(rows: readonly BookingRow[]): NightGroup[] {
  const groups: NightGroup[] = [];
  for (const row of rows) {
    let group = groups.find((g) => g.night === row.nightDate);
    if (!group) {
      group = { night: row.nightDate, label: formatNight(row.nightDate), rows: [], guests: 0 };
      groups.push(group);
    }
    group.rows.push(row);
    if (statusInfo(row.status).confirmed) group.guests += row.guestCount;
  }
  return groups;
}

export interface Summary {
  /** Confirmed bookings. */
  bookings: number;
  /** Guests across the confirmed bookings. */
  guests: number;
  /** Confirmed bookings whose guests have already arrived. */
  checkedIn: number;
  /** Started but not paid. These may be abandoned checkouts, so they are not counted as bookings. */
  awaitingPayment: number;
}

export function summarize(rows: readonly BookingRow[]): Summary {
  const s: Summary = { bookings: 0, guests: 0, checkedIn: 0, awaitingPayment: 0 };
  for (const r of rows) {
    if (statusInfo(r.status).confirmed) {
      s.bookings += 1;
      s.guests += r.guestCount;
      if (r.checkedInAt) s.checkedIn += 1;
    } else if (r.status === 'pending') {
      s.awaitingPayment += 1;
    }
  }
  return s;
}

// ---------------------------------------------------------------------------
// Which nights
// ---------------------------------------------------------------------------

export const MAX_NIGHTS = 93;

export interface NightRange {
  from: string;
  to: string;
}

const ISO = /^\d{4}-\d{2}-\d{2}$/;

function parseIso(iso: string): Date | null {
  if (!ISO.test(iso)) return null;
  const d = new Date(`${iso}T00:00:00Z`);
  return Number.isNaN(d.getTime()) || d.toISOString().slice(0, 10) !== iso ? null : d;
}

export function addDays(iso: string, days: number): string {
  const d = parseIso(iso);
  if (!d) throw new Error(`not a date: ${iso}`);
  d.setUTCDate(d.getUTCDate() + days);
  return d.toISOString().slice(0, 10);
}

/** Number of nights from `from` to `to`, both included. */
export function nightCount(range: NightRange): number {
  const a = parseIso(range.from);
  const b = parseIso(range.to);
  if (!a || !b) return 0;
  return Math.round((b.getTime() - a.getTime()) / 86_400_000) + 1;
}

/** A sentence about what is wrong with the range, or null when it can be asked for. */
export function validateRange(range: NightRange): string | null {
  if (!parseIso(range.from) || !parseIso(range.to)) return 'Choose a start and an end date.';
  if (range.to < range.from) return 'The end date is before the start date.';
  if (nightCount(range) > MAX_NIGHTS) return `Choose at most ${MAX_NIGHTS} nights at a time.`;
  return null;
}

export interface Preset {
  id: 'tonight' | 'next7' | 'next30' | 'last7';
  label: string;
  range: NightRange;
}

/** Ready-made ranges, counted in business nights: before 06:00 it is still the previous night. */
export function presets(now: Date): Preset[] {
  const tonight = currentNight(now);
  return [
    { id: 'tonight', label: 'Tonight', range: { from: tonight, to: tonight } },
    { id: 'next7', label: 'Next 7 nights', range: { from: tonight, to: addDays(tonight, 6) } },
    { id: 'next30', label: 'Next 30 nights', range: { from: tonight, to: addDays(tonight, 29) } },
    { id: 'last7', label: 'Last 7 nights', range: { from: addDays(tonight, -7), to: addDays(tonight, -1) } },
  ];
}

/** The database returns at most this many rows; reaching it means there may be more than are shown. */
export const ROW_LIMIT = 1000;
