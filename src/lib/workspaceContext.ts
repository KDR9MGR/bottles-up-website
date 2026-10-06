// What the workspace top bar shows (client brief, section 3: "always show the current venue, event
// and night"). The night follows the same rule as bookings: before 06:00 it is still the previous
// night. Per-venue time zones are not modelled yet, so this uses the device's local clock.

import { computeNightDate, formatMonthDay, formatWeekday } from './bookingNight';
import type { Workspace } from './accountRouting';

const pad = (n: number) => String(n).padStart(2, '0');

export function localIsoDate(d: Date): string {
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
}

export function localTime(d: Date): string {
  return `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
}

/** The business night (as yyyy-mm-dd) that `now` belongs to. */
export function currentNight(now: Date): string {
  return computeNightDate(localIsoDate(now), localTime(now));
}

/** "Saturday Oct 10". */
export function nightLabel(now: Date): string {
  const night = currentNight(now);
  return `${formatWeekday(night)} ${formatMonthDay(night)}`;
}

export interface ContextLine {
  business: string;
  venue: string | null;
  event: string | null;
  shift: string | null;
}

/** The business, venue, event and shift a workspace is scoped to, for the context bar. */
export function contextFor(w: Workspace): ContextLine {
  return { business: w.orgName, venue: w.venueName, event: w.eventTitle, shift: w.shiftName };
}
