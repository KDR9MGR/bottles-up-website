// "May this person add bottles to this table?" is decided in the database (desk_may_add_bottles, 20261020150000_add_bottles_checks.sql), with the caller's own login:
// it is true for the club's manager or owner and for the server the table was given to, and otherwise raises a plain sentence. This turns that answer into what the
// add-table-booking-bottles endpoint does next:
//   * no error                                -> the caller is table staff: add the bottles (settled at the club, never a checkout)
//   * "not allowed" / "not authenticated"      -> not table staff: carry on as a customer adding to their own booking (the ownership check stays exactly as it was)
//   * any other plain sentence (P0001)         -> table staff, but not now ("this table has already been closed out", "this night has been closed, ..."): say so, add nothing
//   * anything else (no such function because the migration is not applied yet, a dropped connection, ...) -> not table staff. Never "staff" by accident.

export type TableStaffVerdict = { kind: 'staff' } | { kind: 'customer' } | { kind: 'refused'; message: string };

export function tableStaffVerdict(error: { code?: string | null; message?: string | null } | null | undefined): TableStaffVerdict {
  if (!error) return { kind: 'staff' };
  const message = (error.message ?? '').trim();
  if (error.code === 'P0001' && message && !/^(not allowed|not authenticated)\.?$/i.test(message)) {
    return { kind: 'refused', message };
  }
  return { kind: 'customer' };
}
