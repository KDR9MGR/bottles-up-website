import { recomputeTableBookingTotals } from './bookingTotals.ts';

// eslint-disable-next-line @typescript-eslint/no-explicit-any
type SupabaseClient = any;

export interface CancelBottleLineResult {
  success: boolean;
  error?: string;
  wasPaid?: boolean;
  lineTotalCents?: number;
  newAmountTotalCents?: number;
  balanceDueCents?: number;
}

// Bottle Payment Options section 9: "Cancellations - Preserve the cancelled
// items and reason. Paid items require the applicable refund process." One
// place both cancel-bottle-line (a direct staff action) and
// respond-bottle-substitution (a customer approving removal of an unavailable
// bottle) mark a line cancelled and recompute totals - so the two can't
// drift on what "cancelled" actually excludes.
export async function cancelBottleLine(
  supabase: SupabaseClient,
  opts: { bottleLineId: string; reason: string; actorId: string | null; actorEmail: string },
): Promise<CancelBottleLineResult> {
  const { data: line, error: lineError } = await supabase
    .from('site_table_booking_bottles')
    .select('id, booking_id, payment_status, cancelled_at, line_total_cents, bottle_name')
    .eq('id', opts.bottleLineId)
    .maybeSingle();

  if (lineError || !line) {
    return { success: false, error: 'Bottle line not found' };
  }
  if (line.cancelled_at) {
    return { success: false, error: 'This item is already cancelled' };
  }
  if (line.payment_status === 'pending_payment') {
    return { success: false, error: 'Cannot cancel while an online payment is still processing for this item' };
  }

  const { error: updateError } = await supabase
    .from('site_table_booking_bottles')
    .update({ cancelled_at: new Date().toISOString(), cancelled_by: opts.actorId, cancellation_reason: opts.reason })
    .eq('id', opts.bottleLineId);
  if (updateError) {
    console.error('cancelBottleLine: update failed', updateError);
    return { success: false, error: 'Failed to cancel this item' };
  }

  const totals = await recomputeTableBookingTotals(supabase, line.booking_id);
  const { data: booking, error: bookingUpdateError } = await supabase
    .from('site_table_bookings')
    .update({
      bottle_subtotal_cents: totals.bottleSubtotalCents,
      tax_cents: totals.taxCents,
      bottlesup_fee_cents: totals.bottlesupFeeCents,
      amount_total_cents: totals.amountTotalCents,
    })
    .eq('id', line.booking_id)
    .select('amount_paid_cents')
    .single();
  if (bookingUpdateError || !booking) {
    console.error('cancelBottleLine: totals update failed', bookingUpdateError);
    return { success: false, error: 'Failed to update totals' };
  }

  await supabase.from('audit_log').insert({
    actor_id: opts.actorId,
    actor_email: opts.actorEmail,
    action: 'table_booking.bottle_cancelled',
    entity_type: 'site_table_booking_bottles',
    entity_id: opts.bottleLineId,
    details: {
      booking_id: line.booking_id,
      reason: opts.reason,
      was_paid: line.payment_status === 'paid',
      line_total_cents: line.line_total_cents,
      bottle_name: line.bottle_name,
    },
  });

  return {
    success: true,
    wasPaid: line.payment_status === 'paid',
    lineTotalCents: line.line_total_cents,
    newAmountTotalCents: totals.amountTotalCents,
    balanceDueCents: Math.max(totals.amountTotalCents - booking.amount_paid_cents, 0),
  };
}
