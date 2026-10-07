import { describe, expect, it } from 'vitest';
import { describeDeleteBlockedError } from './friendlyDbError';

// Deleting an event or venue is intentionally blocked when customers have
// orders against it, so purchase history can't be wiped by a stray click.
describe('describeDeleteBlockedError', () => {
  const fk = (details?: string | null) => ({ code: '23503', details });

  it('ignores errors that are not foreign-key violations', () => {
    expect(describeDeleteBlockedError({ code: '42501' })).toBeNull();
    expect(describeDeleteBlockedError({})).toBeNull();
  });
  it('names the blocking records in plain words for known tables', () => {
    expect(describeDeleteBlockedError(fk('Key (id)=(1) is still referenced from table "site_orders".'))).toEqual({
      referencingLabel: 'ticket orders',
      referencedTable: 'site_orders',
    });
    expect(describeDeleteBlockedError(fk('... referenced from table "site_table_bookings".'))?.referencingLabel).toBe('table bookings');
    expect(describeDeleteBlockedError(fk('... referenced from table "scan_attempts".'))?.referencingLabel).toBe('scan records');
  });
  it('turns an unknown site_ table name into readable words', () => {
    expect(describeDeleteBlockedError(fk('... referenced from table "site_guest_passes".'))).toEqual({
      referencingLabel: 'guest passes',
      referencedTable: 'site_guest_passes',
    });
  });
  it('falls back to a generic label when the details are missing or unparseable', () => {
    expect(describeDeleteBlockedError(fk(undefined))).toEqual({ referencingLabel: 'other records', referencedTable: null });
    expect(describeDeleteBlockedError(fk('something else entirely'))).toEqual({ referencingLabel: 'other records', referencedTable: null });
  });
});
