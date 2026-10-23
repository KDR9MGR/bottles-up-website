// What a guest is told about refunds before they pay, and how they ask for one afterwards. Both go through database functions that need no sign-in
// (public_venue_refund_policy, guest_request_refund; 20261023100000_refund_policy_and_requests.sql). Neither can break a page: when the policy cannot be read (the
// migration is not applied yet, a lost connection) the page simply shows nothing about it.
import { supabase } from '@/lib/supabase';

const db = supabase as unknown as {
  rpc: (fn: string, args?: Record<string, unknown>) => PromiseLike<{ data: unknown; error: { code?: string | null; message?: string | null } | null }>;
};

export interface PublicRefundPolicy {
  hasPolicy: boolean;
  lines: string[];
}

/** The venue's refund policy as plain sentences, or null when it cannot be read. */
export async function fetchPublicRefundPolicy(venueId: string): Promise<PublicRefundPolicy | null> {
  try {
    const { data, error } = await db.rpc('public_venue_refund_policy', { p_venue: venueId });
    if (error || !Array.isArray(data) || data.length === 0) return null;
    const row = data[0] as { has_policy?: boolean; lines?: unknown };
    const lines = Array.isArray(row.lines) ? row.lines.filter((l): l is string => typeof l === 'string' && l.trim() !== '') : [];
    return lines.length === 0 ? null : { hasPolicy: row.has_policy === true, lines };
  } catch {
    return null;
  }
}

export class RefundRequestError extends Error {}

/** A guest asks for their money back with the booking code and the e-mail the booking was made with. Resolves with the sentence to show; throws a sentence. */
export async function requestRefund(code: string, email: string, reason: string): Promise<string> {
  const { data, error } = await db.rpc('guest_request_refund', { p_code: code.trim(), p_email: email.trim(), p_reason: reason.trim() });
  if (error) {
    const message = (error.message ?? '').trim();
    throw new RefundRequestError(error.code === 'P0001' && message ? message : 'Your request could not be sent just now. Try again in a moment.');
  }
  return typeof data === 'string' && data !== '' ? data : 'Your request has been sent to the venue.';
}
