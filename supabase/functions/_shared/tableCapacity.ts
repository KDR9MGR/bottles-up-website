import { createClient } from 'npm:@supabase/supabase-js@2';

// eslint-disable-next-line @typescript-eslint/no-explicit-any
type SupabaseClient = ReturnType<typeof createClient<any>>;

// How many tables of one type are taken for one arrival time. The answer comes from the database (site_table_taken_count, 20261021100000_floor_plan_and_table_states.sql),
// so a checkout, a staff walk-in and the venue's own desk all count the same way:
//   * paid bookings,
//   * checkouts started in the last 10 minutes (the checkout HOLD: a guest who is paying keeps the table while they do),
//   * the tables a manager has held or taken out of use.
// `excludeEmail` is the guest who is checking out now: their own earlier, unfinished attempt does not block them.
//
// While that migration is not applied yet (the function does not exist) this falls back to the old rule, paid bookings only, so a deploy that comes before the
// migration cannot stop bookings. Any OTHER failure is thrown: a booking is never sold on an availability answer that could not be read.

export interface TakenTablesQuery {
  typeId: string;
  slotId: string;
  arrivalDate: string; // the ARRIVAL date (after-midnight times are the next calendar day), as site_table_bookings.booking_date
  excludeEmail?: string | null;
}

const MISSING_FUNCTION = /could not find the function|does not exist/i;

export function isMissingFunction(error: { code?: string | null; message?: string | null } | null | undefined): boolean {
  if (!error) return false;
  return error.code === 'PGRST202' || error.code === '42883' || MISSING_FUNCTION.test(error.message ?? '');
}

export async function tablesTaken(supabase: SupabaseClient, q: TakenTablesQuery): Promise<number> {
  const { data, error } = await supabase.rpc('site_table_taken_count', {
    p_type: q.typeId,
    p_slot: q.slotId,
    p_date: q.arrivalDate,
    p_exclude_email: q.excludeEmail ?? null,
  });
  if (!error) {
    if (typeof data !== 'number' || !Number.isInteger(data) || data < 0) throw new Error('The table availability answer was not a count.');
    return data;
  }
  if (!isMissingFunction(error)) throw new Error(`Could not check table availability: ${error.message ?? error.code ?? 'unknown error'}`);

  const { count, error: countError } = await supabase
    .from('site_table_bookings')
    .select('id', { count: 'exact', head: true })
    .eq('table_type_id', q.typeId)
    .eq('time_slot_id', q.slotId)
    .eq('booking_date', q.arrivalDate)
    .eq('status', 'paid');
  if (countError) throw new Error(`Could not check table availability: ${countError.message ?? 'unknown error'}`);
  return count ?? 0;
}
