import { supabase } from '@/lib/supabase';
import type { BottleServiceStatus } from '@/types/database';

export const BOTTLE_SERVICE_STATUS_LABELS: Record<BottleServiceStatus, string> = {
  awaiting_prep: 'Awaiting Prep',
  preparing: 'Preparing',
  ready: 'Ready',
  served: 'Served',
};

export const BOTTLE_SERVICE_STATUSES: BottleServiceStatus[] = ['awaiting_prep', 'preparing', 'ready', 'served'];

// Shared by the door-staff check-in screen and the CMS booking detail sheet -
// section 7 of Bottle Payment Options. Kept fully independent of payment
// status and the customer's club-payment confirmation, per spec: updating
// this never touches either of those, and vice versa.
export async function updateBottleServiceStatus(bottleLineId: string, status: BottleServiceStatus): Promise<void> {
  const { error } = await supabase.rpc('update_bottle_service_status', {
    p_bottle_line_id: bottleLineId,
    p_status: status,
  });
  if (error) throw error;
}
