import { call } from './account';
import type { BookingRow } from './bookingsView';

// The owner's read-only view of table bookings, over list_venue_bookings in 20261011100000_venue_bookings.sql. The database
// checks the signed-in person owns or manages THIS venue and decides which night each booking belongs to.

const num = (v: unknown): number => (typeof v === 'number' ? v : Number(v ?? 0) || 0);
const text = (v: unknown): string | null => (typeof v === 'string' && v !== '' ? v : null);

/** Bookings for the business nights `from` to `to` (yyyy-mm-dd, both included). */
export async function listVenueBookings(venueId: string, from: string, to: string): Promise<BookingRow[]> {
  const rows = await call<Record<string, unknown>[] | null>('list_venue_bookings', { p_venue: venueId, p_from: from, p_to: to });
  return (rows ?? []).map((r) => ({
    bookingId: String(r.booking_id),
    nightDate: String(r.night_date),
    startTime: String(r.start_time ?? ''),
    slotLabel: text(r.slot_label),
    tableName: String(r.table_name ?? ''),
    guestCount: num(r.guest_count),
    customerName: String(r.customer_name ?? ''),
    customerEmail: String(r.customer_email ?? ''),
    customerPhone: text(r.customer_phone),
    status: String(r.status ?? ''),
    confirmationCode: text(r.confirmation_code),
    checkedInAt: text(r.checked_in_at),
    amountTotalCents: num(r.amount_total_cents),
    depositCents: num(r.deposit_cents),
    currency: text(r.currency) ?? 'cad',
  }));
}
