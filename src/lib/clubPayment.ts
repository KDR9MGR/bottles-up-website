import { supabase } from '@/lib/supabase';

export type ClubPaymentMethod = 'cash' | 'debit' | 'credit' | 'split';
export type SplitLegMethod = 'cash' | 'debit' | 'credit';

export interface SplitLeg {
  method: SplitLegMethod;
  amountCents: number;
}

export interface ClubPaymentRecord {
  id: string;
  billedAmountCents: number;
  amountPaidCents: number;
  paymentMethod: ClubPaymentMethod;
  splitBreakdown: SplitLeg[] | null;
  posReference: string | null;
  receiptPhotoPath: string | null;
  recordedAt: string;
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
}): Promise<{ newAmountPaidCents: number; balanceDueCents: number }> {
  const { data, error } = await supabase.rpc('record_club_payment', {
    p_booking_id: opts.bookingId,
    p_billed_amount_cents: opts.billedAmountCents,
    p_amount_paid_cents: opts.amountPaidCents,
    p_payment_method: opts.paymentMethod,
    p_split_breakdown: opts.splitBreakdown ?? null,
    p_pos_reference: opts.posReference ?? null,
    p_receipt_photo_path: opts.receiptPhotoPath ?? null,
  });
  if (error) throw error;
  return { newAmountPaidCents: data.new_amount_paid_cents, balanceDueCents: data.balance_due_cents };
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
  }>).map((r) => ({
    id: r.id,
    billedAmountCents: r.billed_amount_cents,
    amountPaidCents: r.amount_paid_cents,
    paymentMethod: r.payment_method,
    splitBreakdown: r.split_breakdown,
    posReference: r.pos_reference,
    receiptPhotoPath: r.receipt_photo_path,
    recordedAt: r.recorded_at,
  }));
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
