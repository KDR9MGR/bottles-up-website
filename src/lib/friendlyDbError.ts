// Postgres foreign-key violation. Supabase surfaces this as PostgrestError with
// code '23503' - see https://www.postgresql.org/docs/current/errcodes-appendix.html
const FK_VIOLATION = '23503';

const REFERENCING_TABLE_LABELS: Record<string, string> = {
  site_orders: 'ticket orders',
  site_table_bookings: 'table bookings',
  site_ticket_tiers: 'ticket tiers',
  site_table_types: 'table types',
  site_venue_time_slots: 'time slots',
  scan_attempts: 'scan records',
};

export interface DeleteBlockedInfo {
  referencingLabel: string;
}

/**
 * Deletes on site_events/site_venues are intentionally NOT cascaded to orders/bookings,
 * so real customer purchase history can never be silently wiped out by a CMS delete
 * click. That means a delete can fail with a raw Postgres FK error - this turns that
 * into something a non-technical admin can act on.
 */
export function describeDeleteBlockedError(error: {
  code?: string;
  details?: string | null;
}): DeleteBlockedInfo | null {
  if (error.code !== FK_VIOLATION) return null;

  const match = error.details?.match(/referenced from table "(\w+)"/);
  const referencedTable = match?.[1];
  const referencingLabel = referencedTable
    ? (REFERENCING_TABLE_LABELS[referencedTable] ?? referencedTable.replace(/^site_/, '').replace(/_/g, ' '))
    : 'other records';

  return { referencingLabel };
}
