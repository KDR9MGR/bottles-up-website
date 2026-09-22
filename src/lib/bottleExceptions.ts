import { supabase } from '@/lib/supabase';

async function authHeader(): Promise<Record<string, string> | undefined> {
  const { data } = await supabase.auth.getSession();
  const token = data.session?.access_token;
  return token ? { Authorization: `Bearer ${token}` } : undefined;
}

// Bottle Payment Options section 9 "Cancellations" - staff-facing, works on
// either a live table (door) or the CMS booking detail sheet. Never deletes
// the line; see cancelBottleLine() in supabase/functions/_shared/bottleCancellation.ts
// for what "cancelled" actually excludes.
export async function cancelBottleLine(
  bottleLineId: string,
  reason: string,
): Promise<{ refundSuggested: boolean; lineTotalCents: number; newAmountTotalCents: number; balanceDueCents: number }> {
  const { data, error } = await supabase.functions.invoke('cancel-bottle-line', {
    body: { bottle_line_id: bottleLineId, reason },
    headers: await authHeader(),
  });
  if (error) throw error;
  if (data?.error) throw new Error(data.error);
  return {
    refundSuggested: !!data.refund_suggested,
    lineTotalCents: data.line_total_cents,
    newAmountTotalCents: data.new_amount_total_cents,
    balanceDueCents: data.balance_due_cents,
  };
}

export async function cancelTableBooking(bookingId: string, reason: string): Promise<{ refundSuggested: boolean }> {
  const { data, error } = await supabase.functions.invoke('cancel-table-booking', {
    body: { booking_id: bookingId, reason },
    headers: await authHeader(),
  });
  if (error) throw error;
  if (data?.error) throw new Error(data.error);
  return { refundSuggested: !!data.refund_suggested };
}

// Section 9 "Unavailable bottles" - staff proposes exactly one change
// (a specific replacement, or omit replacementBottleId to propose removal)
// and the customer approves or declines it by email.
export async function flagBottleUnavailable(opts: {
  bottleLineId: string;
  reason: string;
  replacementBottleId?: string | null;
}): Promise<{ substitutionId: string; emailSent: boolean }> {
  const { data, error } = await supabase.functions.invoke('flag-bottle-unavailable', {
    body: { bottle_line_id: opts.bottleLineId, reason: opts.reason, replacement_bottle_id: opts.replacementBottleId ?? null },
    headers: await authHeader(),
  });
  if (error) throw error;
  if (data?.error) throw new Error(data.error);
  return { substitutionId: data.substitution_id, emailSent: !!data.email_sent };
}

export interface BottleSubstitutionLookup {
  found: boolean;
  status?: 'pending' | 'approved' | 'declined';
  reason?: string;
  originalBottleName?: string;
  originalSize?: string | null;
  quantity?: number;
  replacementBottleName?: string | null;
  replacementSize?: string | null;
  priceDiffCents?: number;
  currency?: string;
  customerName?: string;
  confirmationCode?: string;
  venueName?: string;
}

export async function lookupBottleSubstitution(token: string): Promise<BottleSubstitutionLookup> {
  const { data, error } = await supabase.functions.invoke('lookup-bottle-substitution', { body: { token } });
  if (error) throw error;
  return data as BottleSubstitutionLookup;
}

export async function respondToBottleSubstitution(opts: {
  token: string;
  action: 'approve' | 'decline';
}): Promise<{ success: boolean; status?: string; error?: string }> {
  const { data, error } = await supabase.functions.invoke('respond-bottle-substitution', {
    body: { token: opts.token, action: opts.action },
  });
  if (error) throw error;
  return data;
}

// Section 9 "Refunds" - manager-only (is_cms_admin, enforced server-side).
// `refundType: 'online'` calls Stripe for real; `'club'` just records that
// the venue already refunded the customer directly.
export async function refundBookingPayment(opts: {
  bookingId: string;
  refundType: 'online' | 'club';
  amountCents: number;
  reason: string;
  bottleLineId?: string | null;
  posReference?: string | null;
  receiptPhotoPath?: string | null;
}): Promise<{ refundId: string; newAmountPaidCents: number }> {
  const { data, error } = await supabase.functions.invoke('refund-table-booking-payment', {
    body: {
      booking_id: opts.bookingId,
      refund_type: opts.refundType,
      amount_cents: opts.amountCents,
      reason: opts.reason,
      bottle_line_id: opts.bottleLineId ?? null,
      pos_reference: opts.posReference ?? null,
      receipt_photo_path: opts.receiptPhotoPath ?? null,
    },
    headers: await authHeader(),
  });
  if (error) throw error;
  if (data?.error) throw new Error(data.error);
  return { refundId: data.refund_id, newAmountPaidCents: data.new_amount_paid_cents };
}
