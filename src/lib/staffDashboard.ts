import { supabase } from '@/lib/supabase';
import type { StaffRole } from '@/types/database';
import type { PaymentStatus } from '@/lib/clubPayment';

export const STAFF_ROLE_LABELS: Record<StaffRole, string> = {
  door_staff: 'Door Staff',
  server: 'Server',
  cashier: 'Cashier',
  bartender: 'Bartender',
  manager: 'Manager',
};

export interface MyTable {
  id: string;
  confirmationCode: string | null;
  customerName: string;
  venueName: string;
  tableTypeName: string;
  bookingDate: string;
  checkedInAt: string;
  guestCount: number;
  bottleCount: number;
  dueAtVenueCount: number;
  balanceDueCents: number;
  fulfillmentStatus: string;
  paymentStatus: PaymentStatus | null;
}

export async function listMyTables(): Promise<MyTable[]> {
  const { data, error } = await supabase.rpc('list_my_tables');
  if (error) throw error;
  return ((data ?? []) as Array<Record<string, unknown>>).map((r) => ({
    id: r.id as string,
    confirmationCode: r.confirmation_code as string | null,
    customerName: r.customer_name as string,
    venueName: r.venue_name as string,
    tableTypeName: r.table_type_name as string,
    bookingDate: r.booking_date as string,
    checkedInAt: r.checked_in_at as string,
    guestCount: r.guest_count as number,
    bottleCount: r.bottle_count as number,
    dueAtVenueCount: r.due_at_venue_count as number,
    balanceDueCents: r.balance_due_cents as number,
    fulfillmentStatus: r.fulfillment_status as string,
    paymentStatus: (r.payment_status as PaymentStatus | null) ?? null,
  }));
}

export interface MyBottleOrder {
  id: string;
  bookingId: string;
  confirmationCode: string | null;
  customerName: string;
  tableTypeName: string;
  bottleName: string;
  size: string | null;
  quantity: number;
  lineTotalCents: number;
  paymentStatus: 'paid' | 'due_at_venue';
  serviceStatus: string;
}

export async function listMyBottleOrders(): Promise<MyBottleOrder[]> {
  const { data, error } = await supabase.rpc('list_my_bottle_orders');
  if (error) throw error;
  return ((data ?? []) as Array<Record<string, unknown>>).map((r) => ({
    id: r.id as string,
    bookingId: r.booking_id as string,
    confirmationCode: r.confirmation_code as string | null,
    customerName: r.customer_name as string,
    tableTypeName: r.table_type_name as string,
    bottleName: r.bottle_name as string,
    size: r.size as string | null,
    quantity: r.quantity as number,
    lineTotalCents: r.line_total_cents as number,
    paymentStatus: r.payment_status as 'paid' | 'due_at_venue',
    serviceStatus: r.service_status as string,
  }));
}

export type StaffAlert =
  | { type: 'dispute'; bookingId: string; confirmationCode: string | null; customerName: string; amountPaidCents: number; disputeReason: string | null }
  | { type: 'ready_unserved'; bookingId: string; confirmationCode: string | null; customerName: string; bottleName: string; quantity: number };

export async function listMyAlerts(): Promise<StaffAlert[]> {
  const { data, error } = await supabase.rpc('list_my_alerts');
  if (error) throw error;
  return ((data ?? []) as Array<Record<string, unknown>>).map((r) =>
    r.type === 'dispute'
      ? {
          type: 'dispute',
          bookingId: r.booking_id as string,
          confirmationCode: r.confirmation_code as string | null,
          customerName: r.customer_name as string,
          amountPaidCents: r.amount_paid_cents as number,
          disputeReason: r.dispute_reason as string | null,
        }
      : {
          type: 'ready_unserved',
          bookingId: r.booking_id as string,
          confirmationCode: r.confirmation_code as string | null,
          customerName: r.customer_name as string,
          bottleName: r.bottle_name as string,
          quantity: r.quantity as number,
        },
  );
}

export interface MyProfile {
  id: string;
  email: string;
  name: string | null;
  role: StaffRole;
  eventTitle: string | null;
  assignedTables: string | null;
  accessStartAt: string | null;
  accessEndAt: string | null;
  canRecordPayments: boolean;
}

export async function requestTablePayment(bookingId: string): Promise<void> {
  const { error } = await supabase.rpc('request_table_payment', { p_booking_id: bookingId });
  if (error) throw error;
}

// Section 11: a server flags a table as ready for a manager to review and
// close - it never closes the table itself (close_table_booking_
// reconciliation still requires is_cms_admin()). Purely a signal surfaced
// on the manager's reconciliation queue/detail view.
export async function requestTableCloseout(bookingId: string): Promise<void> {
  const { error } = await supabase.rpc('request_table_closeout', { p_booking_id: bookingId });
  if (error) throw error;
}

export async function getMyProfile(): Promise<MyProfile | null> {
  const { data: sessionData } = await supabase.auth.getSession();
  const uid = sessionData.session?.user.id;
  if (!uid) return null;

  const { data, error } = await supabase
    .from('door_staff')
    .select('id, email, name, role, assigned_tables, access_start_at, access_end_at, can_record_payments, site_events(title)')
    .eq('id', uid)
    .maybeSingle();
  if (error || !data) return null;

  const event = data.site_events as unknown as { title: string } | null;
  return {
    id: data.id,
    email: data.email,
    name: data.name,
    role: data.role,
    eventTitle: event?.title ?? null,
    assignedTables: data.assigned_tables,
    accessStartAt: data.access_start_at,
    accessEndAt: data.access_end_at,
    canRecordPayments: data.can_record_payments,
  };
}
