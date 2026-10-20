// The CMS's money pages (Refunds, Discounts, Payouts): what the database functions return, turned into plain shapes, and the few pure helpers the pages share.
// Every call goes through a database function that checks the caller is a BottlesUp admin (is_cms_admin); the page never writes to a table.
import { supabase } from '@/lib/supabase';

export class CmsMoneyError extends Error {}

type DbError = { code?: string | null; message?: string | null } | null;

/** A sentence a person can read: the database's own sentence for a refusal (P0001), a fixed one for anything else. */
export function plainMessage(error: DbError): string {
  const message = (error?.message ?? '').trim();
  if (error?.code === 'P0001' && message) return message;
  if (error?.code === '42501') return 'You do not have access to this.';
  return 'This could not be done just now. Check the connection and try again.';
}

async function rpc<T>(fn: string, params?: Record<string, unknown>): Promise<T> {
  const { data, error } = await supabase.rpc(fn, params);
  if (error) throw new CmsMoneyError(plainMessage(error));
  return data as T;
}

const rows = <T>(data: unknown): T[] => (Array.isArray(data) ? (data as T[]) : []);

// ---------------------------------------------------------------- shared helpers
export const WEEKDAYS = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'] as const;

/** 123456 -> "$1,234.56". */
export function dollars(cents: number | null | undefined): string {
  const value = Number.isFinite(cents) ? (cents as number) : 0;
  const sign = value < 0 ? '-' : '';
  const abs = Math.abs(value);
  const whole = Math.floor(abs / 100).toString().replace(/\B(?=(\d{3})+(?!\d))/g, ',');
  return `${sign}$${whole}.${String(abs % 100).padStart(2, '0')}`;
}

/** The database keeps BottlesUp's share in hundredths of a percent: 1250 -> "12.5". */
export function percentFromBps(bps: number | null | undefined): string {
  if (bps === null || bps === undefined || !Number.isFinite(bps)) return '';
  return (bps / 100).toFixed(2).replace(/\.?0+$/, '');
}

/** "12.5" -> 1250. Returns null for anything that is not a number from 0 to 100 with at most two decimals. */
export function bpsFromPercent(text: string): number | null {
  const t = text.trim();
  if (!/^\d{1,3}(\.\d{1,2})?$/.test(t)) return null;
  const n = Number(t);
  return n >= 0 && n <= 100 ? Math.round(n * 100) : null;
}

const when = (iso: string | null) => (iso ? new Date(iso).toLocaleString() : '');
export { when as formatWhen };

// ---------------------------------------------------------------- refunds
export interface RefundRequestRow {
  requestId: string;
  venueName: string;
  confirmationCode: string | null;
  guestName: string;
  guestEmail: string;
  requestedBy: 'guest' | 'staff';
  reason: string;
  status: 'requested' | 'approved' | 'declined' | 'processing' | 'completed' | 'failed';
  paidCents: number;
  policyPercent: number | null;
  suggestedCents: number;
  approvedCents: number | null;
  method: 'online' | 'club' | null;
  decisionNote: string | null;
  failureNote: string | null;
  createdAt: string;
  decidedAt: string | null;
  completedAt: string | null;
  bookingId: string;
}

export const REFUND_STATUS_LABELS: Record<RefundRequestRow['status'], string> = {
  requested: 'Waiting for the venue', approved: 'Approved', declined: 'Declined', processing: 'Being returned', completed: 'Returned', failed: 'Failed',
};

export async function fetchRefundRequests(status?: RefundRequestRow['status']): Promise<RefundRequestRow[]> {
  const data = rows<Record<string, unknown>>(await rpc('cms_refund_requests', { p_status: status ?? null }));
  return data.map((r) => ({
    requestId: String(r.request_id), venueName: String(r.venue_name ?? ''), confirmationCode: (r.confirmation_code as string | null) ?? null, guestName: String(r.guest_name ?? ''),
    guestEmail: String(r.guest_email ?? ''), requestedBy: r.requested_by_kind === 'guest' ? 'guest' : 'staff', reason: String(r.reason ?? ''), status: r.status as RefundRequestRow['status'],
    paidCents: Number(r.paid_cents ?? 0), policyPercent: r.policy_percent === null || r.policy_percent === undefined ? null : Number(r.policy_percent), suggestedCents: Number(r.suggested_cents ?? 0),
    approvedCents: r.approved_cents === null || r.approved_cents === undefined ? null : Number(r.approved_cents), method: (r.method as 'online' | 'club' | null) ?? null,
    decisionNote: (r.decision_note as string | null) ?? null, failureNote: (r.failure_note as string | null) ?? null, createdAt: String(r.created_at), decidedAt: (r.decided_at as string | null) ?? null,
    completedAt: (r.completed_at as string | null) ?? null, bookingId: String(r.booking_id),
  }));
}

export interface RefundPolicyRow { venueId: string; venueName: string; hasPolicy: boolean; lines: string[]; updatedAt: string | null }

export async function fetchRefundPolicies(): Promise<RefundPolicyRow[]> {
  const data = rows<Record<string, unknown>>(await rpc('cms_refund_policies'));
  return data.map((r) => ({ venueId: String(r.venue_id), venueName: String(r.venue_name ?? ''), hasPolicy: r.has_policy === true, lines: Array.isArray(r.lines) ? (r.lines as string[]) : [], updatedAt: (r.updated_at as string | null) ?? null }));
}

export async function processOnlineRefund(requestId: string, bookingId: string): Promise<void> {
  const { data, error } = await supabase.functions.invoke('refund-table-booking-payment', { body: { booking_id: bookingId, refund_type: 'online', request_id: requestId } });
  if (error) {
    let message = 'The refund could not be processed.';
    try {
      const body = await (error as { context?: Response }).context?.json();
      if (body?.error) message = String(body.error);
    } catch { /* keep the fixed sentence */ }
    throw new CmsMoneyError(message);
  }
  if (data && typeof data === 'object' && 'error' in data && data.error) throw new CmsMoneyError(String((data as { error: unknown }).error));
}

// ---------------------------------------------------------------- discounts and complimentary
export interface ConcessionRow {
  id: string; venueName: string; confirmationCode: string | null; kind: 'discount' | 'free_bottle'; percent: number | null; amountCents: number; bottleName: string | null; quantity: number | null;
  status: 'applied' | 'pending' | 'declined' | 'voided'; reason: string; requestedBy: string; requestedRole: string; decidedBy: string | null; decidedRole: string | null; night: string; createdAt: string;
}

export async function fetchConcessions(status?: ConcessionRow['status']): Promise<ConcessionRow[]> {
  const data = rows<Record<string, unknown>>(await rpc('cms_concessions', { p_status: status ?? null, p_limit: 300 }));
  return data.map((r) => ({
    id: String(r.concession_id), venueName: String(r.venue_name ?? ''), confirmationCode: (r.confirmation_code as string | null) ?? null, kind: r.kind === 'free_bottle' ? 'free_bottle' : 'discount',
    percent: r.percent === null || r.percent === undefined ? null : Number(r.percent), amountCents: Number(r.amount_cents ?? 0), bottleName: (r.bottle_name as string | null) ?? null,
    quantity: r.quantity === null || r.quantity === undefined ? null : Number(r.quantity), status: r.status as ConcessionRow['status'], reason: String(r.reason ?? ''),
    requestedBy: String(r.requested_by_name ?? ''), requestedRole: String(r.requested_role ?? ''), decidedBy: (r.decided_by_name as string | null) ?? null, decidedRole: (r.decided_role as string | null) ?? null,
    night: String(r.business_night ?? ''), createdAt: String(r.created_at),
  }));
}

export interface DiscountLimitsRow {
  venueId: string; venueName: string; hasLimits: boolean; serverMaxPercent: number; managerMaxPercent: number; serverFreeBottles: number; managerFreeBottles: number; allowStacking: boolean; updatedAt: string | null;
}

export async function fetchDiscountLimits(): Promise<DiscountLimitsRow[]> {
  const data = rows<Record<string, unknown>>(await rpc('cms_discount_limits'));
  return data.map((r) => ({
    venueId: String(r.venue_id), venueName: String(r.venue_name ?? ''), hasLimits: r.has_limits === true, serverMaxPercent: Number(r.server_max_percent ?? 0), managerMaxPercent: Number(r.manager_max_percent ?? 0),
    serverFreeBottles: Number(r.server_free_bottles_per_night ?? 0), managerFreeBottles: Number(r.manager_free_bottles_per_night ?? 0), allowStacking: r.allow_stacking === true, updatedAt: (r.updated_at as string | null) ?? null,
  }));
}

// ---------------------------------------------------------------- payouts
export interface PayoutSettings { method: string; weekday: number; holdDays: number; commissionBps: number; commissionSet: boolean }

export async function fetchPayoutSettings(): Promise<PayoutSettings> {
  const r = rows<Record<string, unknown>>(await rpc('cms_payout_settings'))[0];
  if (!r) throw new CmsMoneyError('The payout settings could not be loaded.');
  return { method: String(r.payout_method), weekday: Number(r.payout_weekday), holdDays: Number(r.hold_days), commissionBps: Number(r.commission_bps), commissionSet: r.commission_set === true };
}

export async function savePayoutSettings(details: { commission_bps?: number; payout_weekday?: number; hold_days?: number }): Promise<void> {
  await rpc('cms_save_payout_settings', { p_details: details });
}

export interface PayoutOverrideRow { orgId: string; orgName: string; orgKind: string; commissionBps: number | null; weekday: number | null; holdDays: number | null; note: string | null }

export async function fetchPayoutOverrides(): Promise<PayoutOverrideRow[]> {
  return rows<Record<string, unknown>>(await rpc('cms_payout_overrides')).map((r) => ({
    orgId: String(r.org_id), orgName: String(r.org_name ?? ''), orgKind: String(r.org_kind ?? ''), commissionBps: r.commission_bps === null ? null : Number(r.commission_bps),
    weekday: r.payout_weekday === null ? null : Number(r.payout_weekday), holdDays: r.hold_days === null ? null : Number(r.hold_days), note: (r.note as string | null) ?? null,
  }));
}

export async function savePayoutOverride(orgId: string, details: { commission_bps?: number | null; payout_weekday?: number | null; hold_days?: number | null; note?: string | null }): Promise<void> {
  await rpc('cms_save_payout_override', { p_org: orgId, p_details: details });
}

export type PayoutAccountStatus = 'incomplete' | 'under_review' | 'ready' | 'action_required';
export const ACCOUNT_STATUS_LABELS: Record<PayoutAccountStatus, string> = { incomplete: 'Incomplete', under_review: 'Under review', ready: 'Ready', action_required: 'Action required' };

export interface PayoutAccountRow { orgId: string; orgName: string; orgKind: string; status: PayoutAccountStatus; holder: string | null; masked: string | null; note: string | null; updatedAt: string | null }

export async function fetchPayoutAccounts(): Promise<PayoutAccountRow[]> {
  return rows<Record<string, unknown>>(await rpc('cms_payout_accounts')).map((r) => ({
    orgId: String(r.org_id), orgName: String(r.org_name ?? ''), orgKind: String(r.org_kind ?? ''), status: r.status as PayoutAccountStatus, holder: (r.account_holder as string | null) ?? null,
    masked: (r.masked_account as string | null) ?? null, note: (r.note as string | null) ?? null, updatedAt: (r.updated_at as string | null) ?? null,
  }));
}

export async function savePayoutAccount(orgId: string, details: { status?: PayoutAccountStatus; account_holder?: string | null; masked_account?: string | null; note?: string | null }): Promise<void> {
  await rpc('cms_save_payout_account', { p_org: orgId, p_details: details });
}

export interface EligibleRow { orgId: string; orgName: string; bookings: number; grossCents: number; commissionBps: number; commissionCents: number; netCents: number; commissionSet: boolean }

export async function fetchEligible(from: string, to: string): Promise<EligibleRow[]> {
  return rows<Record<string, unknown>>(await rpc('cms_payout_eligible', { p_from: from, p_to: to })).map((r) => ({
    orgId: String(r.org_id), orgName: String(r.org_name ?? ''), bookings: Number(r.bookings), grossCents: Number(r.gross_cents), commissionBps: Number(r.commission_bps),
    commissionCents: Number(r.commission_cents), netCents: Number(r.net_cents), commissionSet: r.commission_set === true,
  }));
}

export async function createPayoutItem(orgId: string, from: string, to: string, adjustmentCents: number, adjustmentNote: string): Promise<string> {
  return String(await rpc('cms_create_payout_item', { p_org: orgId, p_from: from, p_to: to, p_adjustment_cents: adjustmentCents, p_adjustment_note: adjustmentNote.trim() === '' ? null : adjustmentNote }));
}

export type PayoutItemStatus = 'pending' | 'processing' | 'paid' | 'failed' | 'cancelled';
export const PAYOUT_STATUS_LABELS: Record<PayoutItemStatus, string> = { pending: 'Pending', processing: 'Processing', paid: 'Paid', failed: 'Failed', cancelled: 'Cancelled' };

export interface PayoutItemRow {
  id: string; orgName: string; periodStart: string; periodEnd: string; grossCents: number; commissionBps: number; commissionCents: number; adjustmentsCents: number; adjustmentNote: string | null;
  netCents: number; status: PayoutItemStatus; expectedOn: string | null; reference: string | null; paidAt: string | null; failureNote: string | null; bookings: number; createdAt: string;
}

export async function fetchPayoutItems(status?: PayoutItemStatus): Promise<PayoutItemRow[]> {
  return rows<Record<string, unknown>>(await rpc('cms_payout_items', { p_status: status ?? null, p_org: null })).map((r) => ({
    id: String(r.item_id), orgName: String(r.org_name ?? ''), periodStart: String(r.period_start), periodEnd: String(r.period_end), grossCents: Number(r.gross_cents), commissionBps: Number(r.commission_bps),
    commissionCents: Number(r.commission_cents), adjustmentsCents: Number(r.adjustments_cents), adjustmentNote: (r.adjustment_note as string | null) ?? null, netCents: Number(r.net_cents),
    status: r.status as PayoutItemStatus, expectedOn: (r.expected_on as string | null) ?? null, reference: (r.reference as string | null) ?? null, paidAt: (r.paid_at as string | null) ?? null,
    failureNote: (r.failure_note as string | null) ?? null, bookings: Number(r.bookings), createdAt: String(r.created_at),
  }));
}

export async function setPayoutItemStatus(itemId: string, status: Exclude<PayoutItemStatus, 'pending'>, reference?: string, note?: string): Promise<void> {
  await rpc('cms_set_payout_item_status', { p_item: itemId, p_status: status, p_reference: reference?.trim() || null, p_note: note?.trim() || null });
}
