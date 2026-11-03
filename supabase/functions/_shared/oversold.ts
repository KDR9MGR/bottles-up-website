import { createClient } from 'npm:@supabase/supabase-js@2';
import { isMissingFunction } from './tableCapacity.ts';

// eslint-disable-next-line @typescript-eslint/no-explicit-any
type SupabaseClient = ReturnType<typeof createClient<any>>;

// After a table booking is marked paid: was the table already gone? A guest keeps the table for 10 minutes while they pay; if they pay later, another guest may have taken
// it, and Stripe has already taken the money. The database (site_flag_oversold_booking, 20261113100000_oversold_booking_queue.sql) counts the paid bookings and the tables a
// manager is holding, opens a conflict for the club's manager when there are more than the club has, and keeps saying yes for that booking until the manager has dealt with it.
// The caller must then NOT send the guest a confirmation that promises a table.
//
// While that migration is not applied yet (the function does not exist) this says no, so a deploy that comes before the migration changes nothing. Any OTHER failure is
// thrown: the payment is then reported as not handled and Stripe tries again, instead of a table being confirmed on an answer that could not be read.
export async function bookingIsOversold(supabase: SupabaseClient, bookingId: string): Promise<boolean> {
  const { data, error } = await supabase.rpc('site_flag_oversold_booking', { p_booking: bookingId });
  if (!error) {
    if (typeof data !== 'boolean') throw new Error('The oversold check did not answer yes or no.');
    return data;
  }
  if (isMissingFunction(error)) return false;
  throw new Error(`Could not check the table: ${error.message ?? error.code ?? 'unknown error'}`);
}

// Read only: is there an OPEN conflict for this booking? The booking-success page uses it so a guest whose table could not be kept is not shown a confirmation (no code, no QR).
// A database without the table (the migration is not applied yet) has no conflicts. Any other failure is thrown, so the page keeps saying "still confirming" and the guest is
// never shown a confirmation on an answer that could not be read.
export async function bookingHeldForReview(supabase: SupabaseClient, bookingId: string): Promise<boolean> {
  const { data, error } = await supabase
    .from('site_booking_conflicts')
    .select('id')
    .eq('booking_id', bookingId)
    .eq('status', 'open')
    .maybeSingle();
  if (!error) return data != null;
  if (isMissingTable(error)) return false;
  throw new Error(`Could not check the booking: ${error.message ?? error.code ?? 'unknown error'}`);
}

function isMissingTable(error: { code?: string | null; message?: string | null }): boolean {
  return error.code === 'PGRST205' || error.code === '42P01' || /could not find the table|does not exist/i.test(error.message ?? '');
}
