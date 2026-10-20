import { supabase } from '@/lib/supabase';
import type { BottleServiceStatus } from '@/types/database';

export const BOTTLE_SERVICE_STATUS_LABELS: Record<BottleServiceStatus, string> = {
  awaiting_prep: 'Awaiting Prep',
  accepted: 'Accepted',
  preparing: 'Preparing',
  ready: 'Ready',
  picked_up: 'Picked Up',
  served: 'Served',
};

// In the order an order moves: Submitted (awaiting prep), Accepted, Preparing, Ready (to collect), On the way (picked up), Delivered (served). 'Accepted' exists since
// 20261022100000_order_accepted_stage.sql; the app and the website's staff pages both read it.
export const BOTTLE_SERVICE_STATUSES: BottleServiceStatus[] = ['awaiting_prep', 'accepted', 'preparing', 'ready', 'picked_up', 'served'];

// Shared by the door-staff check-in screen and the CMS booking detail sheet -
// section 7 of Bottle Payment Options, extended with a "Picked Up" state in
// section 9 of the Server and Pay-at-Club system. Kept fully independent of
// payment status and the customer's club-payment confirmation, per spec:
// updating this never touches either of those, and vice versa - except the
// one new hard rule server-side (not enforced here on the client): a
// due-at-venue bottle can't move to "served" until a receipt-backed club
// payment covers the balance.
export async function updateBottleServiceStatus(bottleLineId: string, status: BottleServiceStatus): Promise<void> {
  const { error } = await supabase.rpc('update_bottle_service_status', {
    p_bottle_line_id: bottleLineId,
    p_status: status,
  });
  if (error) throw error;
}
