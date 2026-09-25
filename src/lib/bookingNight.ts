// Nightlife venues' "night" often runs past midnight - a table booked for
// 1:00 AM is a guest arriving Sunday morning during Saturday night's party,
// not a booking for early Saturday morning before the party has even
// started. Any time slot starting before this cutoff is treated as the tail
// end of the PREVIOUS calendar day's night, not the start of a new one.
// Every real slot in this app's data falls cleanly into 00:00-02:30, so a
// single cutoff is unambiguous today; if a venue ever wants a slot near the
// boundary to behave differently, that's a deliberate follow-up, not
// something to pre-build for.
export const AFTER_MIDNIGHT_CUTOFF = '06:00:00';

export function isAfterMidnightSlot(startTime: string): boolean {
  return startTime < AFTER_MIDNIGHT_CUTOFF;
}

function shiftDate(isoDate: string, deltaDays: number): string {
  const [y, m, d] = isoDate.split('-').map(Number);
  const dt = new Date(Date.UTC(y, m - 1, d));
  dt.setUTCDate(dt.getUTCDate() + deltaDays);
  return dt.toISOString().slice(0, 10);
}

// The customer picks a "night" (e.g. clicks Saturday on the calendar) and a
// time slot. This computes the calendar date that should actually be stored
// as the arrival date - the next day for an after-midnight slot, unchanged
// otherwise.
export function computeArrivalDate(nightDate: string, startTime: string): string {
  return isAfterMidnightSlot(startTime) ? shiftDate(nightDate, 1) : nightDate;
}

// Inverse: given the stored arrival date and the slot it was booked under,
// recover which "night" (the venue's own business-day label) it belongs to.
export function computeNightDate(arrivalDate: string, startTime: string): string {
  return isAfterMidnightSlot(startTime) ? shiftDate(arrivalDate, -1) : arrivalDate;
}

export function formatWeekday(isoDate: string): string {
  return new Date(`${isoDate}T00:00:00Z`).toLocaleDateString('en-US', { weekday: 'long', timeZone: 'UTC' });
}

export function formatMonthDay(isoDate: string): string {
  return new Date(`${isoDate}T00:00:00Z`).toLocaleDateString('en-US', { month: 'short', day: 'numeric', timeZone: 'UTC' });
}

export function formatTimeSlot(startTime: string): string {
  const [h, m] = startTime.split(':').map((v) => parseInt(v, 10));
  const period = h >= 12 ? 'PM' : 'AM';
  const hour12 = h % 12 === 0 ? 12 : h % 12;
  return `${hour12}:${m.toString().padStart(2, '0')} ${period}`;
}
