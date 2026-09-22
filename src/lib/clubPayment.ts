import { supabase } from '@/lib/supabase';

export type ClubPaymentMethod = 'cash' | 'debit' | 'credit' | 'split';
export type SplitLegMethod = 'cash' | 'debit' | 'credit';

export interface SplitLeg {
  method: SplitLegMethod;
  amountCents: number;
}

export type CustomerConfirmationStatus = 'pending' | 'confirmed' | 'disputed';

export interface ClubPaymentRecord {
  id: string;
  billedAmountCents: number;
  amountPaidCents: number;
  paymentMethod: ClubPaymentMethod;
  splitBreakdown: SplitLeg[] | null;
  posReference: string | null;
  receiptPhotoPath: string | null;
  recordedAt: string;
  customerConfirmationStatus: CustomerConfirmationStatus;
  payerName: string | null;
  payerEmail: string | null;
  managerVerifiedAt: string | null;
  managerVerifiedNote: string | null;
  correctsPaymentId: string | null;
  bottleSubtotalCents: number;
  discountCents: number;
  taxCents: number;
  gratuityCents: number;
}

// Shared by the door-staff check-in screen and the CMS booking detail sheet,
// so "record a club payment" behaves identically (and stays in sync) no
// matter which screen staff use - see record_club_payment() in the
// add_club_payment_recording migration for the server-side half.
export async function recordClubPayment(opts: {
  bookingId: string;
  billedAmountCents: number;
  amountPaidCents: number;
  paymentMethod: ClubPaymentMethod;
  splitBreakdown?: SplitLeg[] | null;
  posReference?: string | null;
  receiptPhotoPath?: string | null;
  payerName?: string | null;
  payerEmail?: string | null;
  bottleSubtotalCents?: number;
  discountCents?: number;
  taxCents?: number;
  gratuityCents?: number;
}): Promise<{ paymentId: string; newAmountPaidCents: number; balanceDueCents: number; confirmationEmailSent: boolean }> {
  const { data, error } = await supabase.rpc('record_club_payment', {
    p_booking_id: opts.bookingId,
    p_billed_amount_cents: opts.billedAmountCents,
    p_amount_paid_cents: opts.amountPaidCents,
    p_payment_method: opts.paymentMethod,
    p_split_breakdown: opts.splitBreakdown ?? null,
    p_pos_reference: opts.posReference ?? null,
    p_receipt_photo_path: opts.receiptPhotoPath ?? null,
    p_payer_name: opts.payerName ?? null,
    p_payer_email: opts.payerEmail ?? null,
    p_bottle_subtotal_cents: opts.bottleSubtotalCents ?? 0,
    p_discount_cents: opts.discountCents ?? 0,
    p_tax_cents: opts.taxCents ?? 0,
    p_gratuity_cents: opts.gratuityCents ?? 0,
  });
  if (error) throw error;

  // Section 6: let the customer confirm or dispute what was just recorded.
  // Best-effort - the payment itself is already safely recorded above either
  // way, so a failed email is reported back rather than thrown, and never
  // undoes the recording.
  let confirmationEmailSent = false;
  try {
    const { data: sessionData } = await supabase.auth.getSession();
    const token = sessionData.session?.access_token;
    const { error: emailError } = await supabase.functions.invoke('send-club-payment-confirmation', {
      body: { payment_id: data.payment_id },
      headers: token ? { Authorization: `Bearer ${token}` } : undefined,
    });
    confirmationEmailSent = !emailError;
  } catch (err) {
    console.error('send-club-payment-confirmation failed:', err);
  }

  return {
    paymentId: data.payment_id,
    newAmountPaidCents: data.new_amount_paid_cents,
    balanceDueCents: data.balance_due_cents,
    confirmationEmailSent,
  };
}

export async function listClubPayments(bookingId: string): Promise<ClubPaymentRecord[]> {
  const { data, error } = await supabase.rpc('list_club_payments', { p_booking_id: bookingId });
  if (error) throw error;
  return ((data ?? []) as Array<{
    id: string;
    billed_amount_cents: number;
    amount_paid_cents: number;
    payment_method: ClubPaymentMethod;
    split_breakdown: SplitLeg[] | null;
    pos_reference: string | null;
    receipt_photo_path: string | null;
    recorded_at: string;
    customer_confirmation_status: CustomerConfirmationStatus;
    payer_name: string | null;
    payer_email: string | null;
    manager_verified_at: string | null;
    manager_verified_note: string | null;
    corrects_payment_id: string | null;
    bottle_subtotal_cents: number;
    discount_cents: number;
    tax_cents: number;
    gratuity_cents: number;
  }>).map((r) => ({
    id: r.id,
    billedAmountCents: r.billed_amount_cents,
    amountPaidCents: r.amount_paid_cents,
    paymentMethod: r.payment_method,
    splitBreakdown: r.split_breakdown,
    posReference: r.pos_reference,
    receiptPhotoPath: r.receipt_photo_path,
    recordedAt: r.recorded_at,
    customerConfirmationStatus: r.customer_confirmation_status,
    payerName: r.payer_name,
    payerEmail: r.payer_email,
    managerVerifiedAt: r.manager_verified_at,
    managerVerifiedNote: r.manager_verified_note,
    correctsPaymentId: r.corrects_payment_id,
    bottleSubtotalCents: r.bottle_subtotal_cents,
    discountCents: r.discount_cents,
    taxCents: r.tax_cents,
    gratuityCents: r.gratuity_cents,
  }));
}

// Section 9 "Incorrect entries": always inserts a NEW row rather than
// editing the original - manager-only (is_cms_admin on the RPC side, a
// tighter gate than recordClubPayment's cms_admin-or-door_staff). Reuses the
// exact same confirmation-email step as a normal recording, since the
// corrected numbers need their own fresh customer sign-off.
export async function correctClubPayment(opts: {
  originalPaymentId: string;
  billedAmountCents: number;
  amountPaidCents: number;
  paymentMethod: ClubPaymentMethod;
  splitBreakdown?: SplitLeg[] | null;
  posReference?: string | null;
  receiptPhotoPath?: string | null;
  reason: string;
  bottleSubtotalCents?: number;
  discountCents?: number;
  taxCents?: number;
  gratuityCents?: number;
}): Promise<{ paymentId: string; newAmountPaidCents: number; balanceDueCents: number; confirmationEmailSent: boolean }> {
  const { data, error } = await supabase.rpc('correct_club_payment', {
    p_original_payment_id: opts.originalPaymentId,
    p_billed_amount_cents: opts.billedAmountCents,
    p_amount_paid_cents: opts.amountPaidCents,
    p_payment_method: opts.paymentMethod,
    p_split_breakdown: opts.splitBreakdown ?? null,
    p_pos_reference: opts.posReference ?? null,
    p_receipt_photo_path: opts.receiptPhotoPath ?? null,
    p_reason: opts.reason,
    p_bottle_subtotal_cents: opts.bottleSubtotalCents ?? 0,
    p_discount_cents: opts.discountCents ?? 0,
    p_tax_cents: opts.taxCents ?? 0,
    p_gratuity_cents: opts.gratuityCents ?? 0,
  });
  if (error) throw error;

  let confirmationEmailSent = false;
  try {
    const { data: sessionData } = await supabase.auth.getSession();
    const token = sessionData.session?.access_token;
    const { error: emailError } = await supabase.functions.invoke('send-club-payment-confirmation', {
      body: { payment_id: data.payment_id },
      headers: token ? { Authorization: `Bearer ${token}` } : undefined,
    });
    confirmationEmailSent = !emailError;
  } catch (err) {
    console.error('send-club-payment-confirmation failed:', err);
  }

  return {
    paymentId: data.payment_id,
    newAmountPaidCents: data.new_amount_paid_cents,
    balanceDueCents: data.balance_due_cents,
    confirmationEmailSent,
  };
}

export type PaymentStatus = 'payment_due' | 'payment_recorded' | 'venue_verified';

export const PAYMENT_STATUS_LABELS: Record<PaymentStatus, string> = {
  payment_due: 'Payment Due',
  payment_recorded: 'Payment Recorded',
  venue_verified: 'Venue Verified',
};

// Section 7: a staff/manager-facing pipeline, distinct from
// customer_confirmation_status (the customer's own agree/dispute signal).
// Deliberately not a stored column - fully derivable from data that already
// exists (the booking's balance and each payment's manager_verified_at), so
// there's nothing new to keep in sync. Returns null when the balance was
// covered without any club payment at all (paid entirely online) - there's
// no club-side pipeline to show in that case.
export function derivePaymentStatus(
  balanceDueCents: number,
  payments: Array<{ managerVerifiedAt: string | null }>,
): PaymentStatus | null {
  if (balanceDueCents > 0) return 'payment_due';
  if (payments.length === 0) return null;
  return payments.every((p) => p.managerVerifiedAt) ? 'venue_verified' : 'payment_recorded';
}

// Section 9 "No customer response": lets a manager note that they checked
// the POS receipt themselves, WITHOUT ever marking the customer as having
// confirmed - customer_confirmation_status stays untouched on the server.
export async function managerVerifyClubPayment(paymentId: string, note?: string): Promise<void> {
  const { error } = await supabase.rpc('manager_verify_club_payment', {
    p_payment_id: paymentId,
    p_note: note ?? null,
  });
  if (error) throw error;
}

export interface ClubPaymentLookup {
  found: boolean;
  paymentId?: string;
  billedAmountCents?: number;
  amountPaidCents?: number;
  paymentMethod?: ClubPaymentMethod;
  recordedAt?: string;
  status?: CustomerConfirmationStatus;
  confirmedAt?: string | null;
  disputeReason?: string | null;
  customerName?: string;
  confirmationCode?: string;
  currency?: string;
  tableTypeName?: string;
  venueName?: string;
}

// Public, token-based - used by both the emailed standalone confirm page and
// the in-app dashboard banner, so there's one lookup shape either way.
export async function lookupClubPaymentByToken(token: string): Promise<ClubPaymentLookup> {
  const { data, error } = await supabase.functions.invoke('lookup-club-payment', { body: { token } });
  if (error) throw error;
  return data as ClubPaymentLookup;
}

export async function respondToClubPayment(opts: {
  token: string;
  action: 'confirm' | 'dispute';
  reason?: string;
  evidenceFile?: File | null;
}): Promise<{ success: boolean; status?: CustomerConfirmationStatus; error?: string }> {
  let evidenceBase64: string | undefined;
  if (opts.evidenceFile) {
    const buffer = await opts.evidenceFile.arrayBuffer();
    evidenceBase64 = btoa(String.fromCharCode(...new Uint8Array(buffer)));
  }

  const { data, error } = await supabase.functions.invoke('respond-club-payment', {
    body: {
      token: opts.token,
      action: opts.action,
      reason: opts.reason,
      evidence_base64: evidenceBase64,
      evidence_filename: opts.evidenceFile?.name,
    },
  });
  if (error) throw error;
  return data;
}

// club-payment-receipts is a private bucket (receipts can show partial card
// digits) - every read goes through a short-lived signed URL rather than a
// bare public one.
export async function uploadReceiptPhoto(bookingId: string, file: File): Promise<string> {
  const ext = file.name.split('.').pop() ?? 'jpg';
  const path = `${bookingId}/${crypto.randomUUID()}.${ext}`;
  const { error } = await supabase.storage.from('club-payment-receipts').upload(path, file, {
    cacheControl: '3600',
  });
  if (error) throw error;
  return path;
}

export async function getReceiptSignedUrl(path: string): Promise<string | null> {
  const { data, error } = await supabase.storage.from('club-payment-receipts').createSignedUrl(path, 300);
  if (error) {
    console.error('getReceiptSignedUrl failed:', error);
    return null;
  }
  return data.signedUrl;
}
