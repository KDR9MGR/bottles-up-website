import { describe, expect, it } from 'vitest';
import { contextFor, currentNight, localIsoDate, nightLabel } from './workspaceContext';
import type { Workspace } from './accountRouting';

// new Date(y, m-1, d, h, mi) is local time, which is what the context bar reads.
const at = (y: number, m: number, d: number, h: number, mi = 0, s = 0) => new Date(y, m - 1, d, h, mi, s);

describe('currentNight', () => {
  it('is the same calendar day in the evening', () => {
    expect(currentNight(at(2026, 10, 10, 22, 30))).toBe('2026-10-10');
    expect(currentNight(at(2026, 10, 10, 12, 0))).toBe('2026-10-10');
  });

  it('is still the previous night after midnight', () => {
    expect(currentNight(at(2026, 10, 11, 0, 5))).toBe('2026-10-10');
    expect(currentNight(at(2026, 10, 11, 2, 30))).toBe('2026-10-10');
    expect(currentNight(at(2026, 10, 11, 5, 59, 59))).toBe('2026-10-10');
  });

  it('a new night starts at 06:00', () => {
    expect(currentNight(at(2026, 10, 11, 6, 0, 0))).toBe('2026-10-11');
  });

  it('rolls back across month and year ends', () => {
    expect(currentNight(at(2026, 11, 1, 1, 0))).toBe('2026-10-31');
    expect(currentNight(at(2027, 1, 1, 3, 0))).toBe('2026-12-31');
    expect(currentNight(at(2028, 3, 1, 2, 0))).toBe('2028-02-29'); // leap year
  });
});

describe('labels', () => {
  it('formats the night for people', () => {
    expect(nightLabel(at(2026, 10, 10, 22, 0))).toBe('Saturday Oct 10');
    expect(nightLabel(at(2026, 10, 11, 1, 0))).toBe('Saturday Oct 10');
  });

  it('pads single digits in the date key', () => {
    expect(localIsoDate(at(2026, 3, 4, 9))).toBe('2026-03-04');
  });
});

describe('contextFor', () => {
  const w: Workspace = {
    membershipId: 'm', orgId: 'o', orgName: 'Club Co', orgKind: 'venue_owner', role: 'door',
    venueId: 'v', venueName: 'Club A', eventId: 'e', eventTitle: 'Friday Night', shiftId: 's', shiftName: 'Doors 9pm', accessEndAt: null,
  };
  it('names the business, venue, event and shift', () => {
    expect(contextFor(w)).toEqual({ business: 'Club Co', venue: 'Club A', event: 'Friday Night', shift: 'Doors 9pm' });
  });
  it('leaves out what the role is not scoped to', () => {
    expect(contextFor({ ...w, venueName: null, eventTitle: null, shiftName: null })).toEqual({ business: 'Club Co', venue: null, event: null, shift: null });
  });
});
