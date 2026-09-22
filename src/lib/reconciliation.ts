import { supabase } from '@/lib/supabase';

export interface ReconciliationQueueItem {
  id: string;
  confirmationCode: string | null;
  customerName: string;
  venueName: string;
  tableTypeName: string;
  bookingDate: string;
  amountTotalCents: number;
  amountPaidCents: number;
  balanceDueCents: number;
  hasDispute: boolean;
  hasUnserved: boolean;
  closeoutRequestedAt: string | null;
}

export async function listReconciliationQueue(venueId?: string | null): Promise<ReconciliationQueueItem[]> {
  const { data, error } = await supabase.rpc('list_reconciliation_queue', { p_venue_id: venueId ?? null });
  if (error) throw error;
  return ((data ?? []) as Array<{
    id: string;
    confirmation_code: string | null;
    customer_name: string;
    venue_name: string;
    table_type_name: string;
    booking_date: string;
    amount_total_cents: number;
    amount_paid_cents: number;
    balance_due_cents: number;
    has_dispute: boolean;
    has_unserved: boolean;
    closeout_requested_at: string | null;
  }>).map((r) => ({
    id: r.id,
    confirmationCode: r.confirmation_code,
    customerName: r.customer_name,
    venueName: r.venue_name,
    tableTypeName: r.table_type_name,
    bookingDate: r.booking_date,
    amountTotalCents: r.amount_total_cents,
    amountPaidCents: r.amount_paid_cents,
    balanceDueCents: r.balance_due_cents,
    hasDispute: r.has_dispute,
    hasUnserved: r.has_unserved,
    closeoutRequestedAt: r.closeout_requested_at,
  }));
}

export interface ReconciliationBottleLine {
  id: string;
  bottleName: string;
  size: string | null;
  quantity: number;
  unitPriceCents: number;
  lineTotalCents: number;
  paymentStatus: 'paid' | 'due_at_venue' | 'pending_payment';
  serviceStatus: string;
  cancelledAt: string | null;
  cancellationReason: string | null;
}

export interface ReconciliationClubPayment {
  id: string;
  billedAmountCents: number;
  amountPaidCents: number;
  paymentMethod: string;
  posReference: string | null;
  receiptPhotoPath: string | null;
  payerName: string | null;
  payerEmail: string | null;
  recordedAt: string;
  customerConfirmationStatus: 'pending' | 'confirmed' | 'disputed';
  managerVerifiedAt: string | null;
  correctsPaymentId: string | null;
  bottleSubtotalCents: number;
  discountCents: number;
  taxCents: number;
  gratuityCents: number;
}

export interface ReconciliationRefund {
  id: string;
  refundType: 'online' | 'club';
  amountCents: number;
  reason: string;
  stripeRefundId: string | null;
  posReference: string | null;
  recordedAt: string;
}

export interface BookingReconciliation {
  found: boolean;
  id?: string;
  confirmationCode?: string | null;
  customerName?: string;
  customerEmail?: string;
  venueName?: string;
  tableTypeName?: string;
  bookingDate?: string;
  currency?: string;
  depositCents?: number;
  depositIsCredit?: boolean;
  bottleSubtotalCents?: number;
  taxCents?: number;
  bottlesupFeeCents?: number;
  discountCents?: number;
  amountTotalCents?: number;
  amountPaidCents?: number;
  balanceDueCents?: number;
  bottlesupCollectedCents?: number;
  clubCollectedCents?: number;
  onlineRefundsCents?: number;
  clubRefundsCents?: number;
  bottles?: ReconciliationBottleLine[];
  clubPayments?: ReconciliationClubPayment[];
  refunds?: ReconciliationRefund[];
  flags?: string[];
  reconciledAt?: string | null;
  reconciliationOverrideReason?: string | null;
  closeoutRequestedAt?: string | null;
  closeoutRequestedByEmail?: string | null;
}

export async function getBookingReconciliation(bookingId: string): Promise<BookingReconciliation> {
  const { data, error } = await supabase.rpc('get_booking_reconciliation', { p_booking_id: bookingId });
  if (error) throw error;
  if (!data?.found) return { found: false };

  return {
    found: true,
    id: data.id,
    confirmationCode: data.confirmation_code,
    customerName: data.customer_name,
    customerEmail: data.customer_email,
    venueName: data.venue_name,
    tableTypeName: data.table_type_name,
    bookingDate: data.booking_date,
    currency: data.currency,
    depositCents: data.deposit_cents,
    depositIsCredit: data.deposit_is_credit,
    bottleSubtotalCents: data.bottle_subtotal_cents,
    taxCents: data.tax_cents,
    bottlesupFeeCents: data.bottlesup_fee_cents,
    discountCents: data.discount_cents,
    amountTotalCents: data.amount_total_cents,
    amountPaidCents: data.amount_paid_cents,
    balanceDueCents: data.balance_due_cents,
    bottlesupCollectedCents: data.bottlesup_collected_cents,
    clubCollectedCents: data.club_collected_cents,
    onlineRefundsCents: data.online_refunds_cents,
    clubRefundsCents: data.club_refunds_cents,
    bottles: (data.bottles ?? []).map((b: Record<string, unknown>) => ({
      id: b.id,
      bottleName: b.bottle_name,
      size: b.size,
      quantity: b.quantity,
      unitPriceCents: b.unit_price_cents,
      lineTotalCents: b.line_total_cents,
      paymentStatus: b.payment_status,
      serviceStatus: b.service_status,
      cancelledAt: b.cancelled_at,
      cancellationReason: b.cancellation_reason,
    })),
    clubPayments: (data.club_payments ?? []).map((p: Record<string, unknown>) => ({
      id: p.id,
      billedAmountCents: p.billed_amount_cents,
      amountPaidCents: p.amount_paid_cents,
      paymentMethod: p.payment_method,
      posReference: p.pos_reference,
      receiptPhotoPath: p.receipt_photo_path,
      payerName: p.payer_name,
      payerEmail: p.payer_email,
      recordedAt: p.recorded_at,
      customerConfirmationStatus: p.customer_confirmation_status,
      managerVerifiedAt: p.manager_verified_at,
      correctsPaymentId: p.corrects_payment_id,
      bottleSubtotalCents: (p.bottle_subtotal_cents as number) ?? 0,
      discountCents: (p.discount_cents as number) ?? 0,
      taxCents: (p.tax_cents as number) ?? 0,
      gratuityCents: (p.gratuity_cents as number) ?? 0,
    })),
    refunds: (data.refunds ?? []).map((r: Record<string, unknown>) => ({
      id: r.id,
      refundType: r.refund_type,
      amountCents: r.amount_cents,
      reason: r.reason,
      stripeRefundId: r.stripe_refund_id,
      posReference: r.pos_reference,
      recordedAt: r.recorded_at,
    })),
    flags: data.flags ?? [],
    reconciledAt: data.reconciled_at,
    reconciliationOverrideReason: data.reconciliation_override_reason,
    closeoutRequestedAt: data.closeout_requested_at,
    closeoutRequestedByEmail: data.closeout_requested_by_email,
  };
}

export async function closeTableBookingReconciliation(
  bookingId: string,
  overrideReason?: string | null,
): Promise<{ success: boolean; flags: string[] }> {
  const { data, error } = await supabase.rpc('close_table_booking_reconciliation', {
    p_booking_id: bookingId,
    p_override_reason: overrideReason ?? null,
  });
  if (error) throw error;
  return { success: data.success, flags: data.flags ?? [] };
}

export interface VenueRevenueReport {
  bookingCount: number;
  bottleSalesCents: number;
  bottlesupCollectedCents: number;
  clubCollectedCents: number;
  bottlesupFeeCents: number;
  onlineRefundsCents: number;
  clubRefundsCents: number;
  outstandingBalanceCents: number;
  unreconciledCount: number;
}

export async function getVenueRevenueReport(
  venueId: string,
  dateFrom: string,
  dateTo: string,
): Promise<VenueRevenueReport> {
  const { data, error } = await supabase.rpc('get_venue_revenue_report', {
    p_venue_id: venueId,
    p_date_from: dateFrom,
    p_date_to: dateTo,
  });
  if (error) throw error;
  return {
    bookingCount: data.booking_count,
    bottleSalesCents: data.bottle_sales_cents,
    bottlesupCollectedCents: data.bottlesup_collected_cents,
    clubCollectedCents: data.club_collected_cents,
    bottlesupFeeCents: data.bottlesup_fee_cents,
    onlineRefundsCents: data.online_refunds_cents,
    clubRefundsCents: data.club_refunds_cents,
    outstandingBalanceCents: data.outstanding_balance_cents,
    unreconciledCount: data.unreconciled_count,
  };
}
