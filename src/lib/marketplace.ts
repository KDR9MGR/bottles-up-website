import { call } from './account';

// What BottlesUp staff use to look after hiring professionals in the customer app: disputes between a customer and a professional, the payouts BottlesUp makes to professionals, and
// the settings (commission, free cancellation, automatic confirmation). Everything here is a call to a database function that checks the caller is a BottlesUp admin
// (20261107100000_service_marketplace); the page only shows what those functions answer.

export type DisputeOutcome = 'release' | 'refund_part' | 'refund_full';
export type DisputeStatus = 'open' | 'resolved';
export type PayoutStatus = 'releasable' | 'paid';

export const OUTCOME_LABELS: Record<DisputeOutcome, string> = {
  release: 'Pay the professional in full',
  refund_part: 'Refund part to the customer',
  refund_full: 'Refund everything to the customer',
};

export const OUTCOME_HELP: Record<DisputeOutcome, string> = {
  release: 'The job counts as done. The professional is paid everything the customer paid, less the commission.',
  refund_part: 'The customer gets the amount you type back; the professional is paid the rest, less the commission.',
  refund_full: 'The booking is cancelled and everything the customer paid goes back to their card. The professional is paid nothing.',
};

export interface DisputeBooking {
  id: string;
  title: string;
  eventDate: string | null;
  totalCents: number;
  paidCents: number;
  currency: string;
  provider: string | null;
  client: { name: string; handle: string | null } | null;
}

export interface Dispute {
  id: string;
  status: DisputeStatus;
  reason: string;
  outcome: DisputeOutcome | null;
  refundCents: number | null;
  note: string | null;
  createdAt: string;
  decidedAt: string | null;
  booking: DisputeBooking;
}

export interface Payout {
  id: string;
  status: PayoutStatus;
  grossCents: number;
  commissionCents: number;
  netCents: number;
  reference: string | null;
  paidAt: string | null;
  createdAt: string;
  currency: string;
  title: string;
  eventDate: string | null;
  provider: string | null;
}

export interface MarketSettings {
  commissionBps: number;
  freeCancelDays: number;
  confirmDays: number;
}

const OUTCOMES: DisputeOutcome[] = ['release', 'refund_part', 'refund_full'];
const str = (v: unknown): string | null => (typeof v === 'string' && v !== '' ? v : null);
const num = (v: unknown): number => (typeof v === 'number' ? v : Number(v ?? 0) || 0);
const obj = (v: unknown): Record<string, unknown> | null => (typeof v === 'object' && v !== null && !Array.isArray(v) ? (v as Record<string, unknown>) : null);

/** Reads the disputes the database answers; a row that cannot be read is left out rather than shown wrong. */
export function parseDisputes(rows: unknown): Dispute[] {
  if (!Array.isArray(rows)) return [];
  const out: Dispute[] = [];
  for (const r of rows) {
    const o = obj(r);
    const b = obj(o?.booking);
    const id = str(o?.id);
    const reason = str(o?.reason);
    const createdAt = str(o?.created_at);
    const status: DisputeStatus | null = o?.status === 'open' || o?.status === 'resolved' ? o.status : null;
    const bookingId = str(b?.id);
    if (!o || !b || !id || !reason || !createdAt || !status || !bookingId) continue;
    const c = obj(b.client);
    out.push({
      id,
      status,
      reason,
      outcome: OUTCOMES.find((x) => x === o.outcome) ?? null,
      refundCents: o.refund_cents === null || o.refund_cents === undefined ? null : num(o.refund_cents),
      note: str(o.note),
      createdAt,
      decidedAt: str(o.decided_at),
      booking: {
        id: bookingId,
        title: str(b.title) ?? 'A booking',
        eventDate: str(b.event_date),
        totalCents: num(b.total_cents),
        paidCents: num(b.paid_cents),
        currency: str(b.currency) ?? 'cad',
        provider: str(b.provider),
        client: c && str(c.name) ? { name: String(c.name), handle: str(c.handle) } : null,
      },
    });
  }
  return out;
}

export function parsePayouts(rows: unknown): Payout[] {
  if (!Array.isArray(rows)) return [];
  const out: Payout[] = [];
  for (const r of rows) {
    const o = obj(r);
    const id = str(o?.id);
    const createdAt = str(o?.created_at);
    const status: PayoutStatus | null = o?.status === 'releasable' || o?.status === 'paid' ? o.status : null;
    if (!o || !id || !createdAt || !status) continue;
    out.push({
      id,
      status,
      grossCents: num(o.gross_cents),
      commissionCents: num(o.commission_cents),
      netCents: num(o.net_cents),
      reference: str(o.reference),
      paidAt: str(o.paid_at),
      createdAt,
      currency: str(o.currency) ?? 'cad',
      title: str(o.title) ?? 'A booking',
      eventDate: str(o.event_date),
      provider: str(o.provider),
    });
  }
  return out;
}

export function parseSettings(v: unknown): MarketSettings {
  const o = obj(v);
  return { commissionBps: num(o?.commission_bps) || 500, freeCancelDays: o?.free_cancel_days === undefined ? 7 : num(o.free_cancel_days), confirmDays: num(o?.confirm_days) || 3 };
}

/** "1,000.00" for 100000 cents. */
export function money(cents: number, currency = 'cad'): string {
  const abs = Math.abs(Math.trunc(cents));
  const whole = String(Math.floor(abs / 100)).replace(/\B(?=(\d{3})+(?!\d))/g, ',');
  return `${cents < 0 ? '-' : ''}${currency.toUpperCase()} ${whole}.${String(abs % 100).padStart(2, '0')}`;
}

/** "5%" for 500 basis points, "2.5%" for 250. */
export function percentText(bps: number): string {
  const p = bps / 100;
  return `${Number.isInteger(p) ? p : p.toFixed(2).replace(/0$/, '')}%`;
}

/** Turns what was typed into the percentage box ("5", "2.5") into basis points, or null when it is not between 0 and 50 with at most two decimals. */
export function percentToBps(text: string): number | null {
  const t = text.trim().replace(/%$/, '').trim();
  if (!/^\d{1,2}(\.\d{1,2})?$/.test(t)) return null;
  const bps = Math.round(parseFloat(t) * 100);
  return bps >= 0 && bps <= 5000 ? bps : null;
}

/** The sentence for what is wrong with these settings, or null. The database checks the same limits. */
export function settingsProblem(commissionText: string, freeCancelDays: number, confirmDays: number): string | null {
  if (percentToBps(commissionText) === null) return 'The commission must be a percentage between 0 and 50.';
  if (!Number.isInteger(freeCancelDays) || freeCancelDays < 0 || freeCancelDays > 60) return 'Free cancellation must be between 0 and 60 days before the job.';
  if (!Number.isInteger(confirmDays) || confirmDays < 1 || confirmDays > 30) return 'Automatic confirmation must be 1 to 30 days after the job is marked done.';
  return null;
}

/** Turns what was typed into the refund box ("400", "400.50") into cents, or null. */
export function refundToCents(text: string): number | null {
  const m = /^(\d{1,7})(?:\.(\d{1,2}))?$/.exec(text.trim().replace(/,/g, ''));
  return m ? parseInt(m[1], 10) * 100 + (m[2] ? parseInt(m[2].padEnd(2, '0'), 10) : 0) : null;
}

/** The sentence for what is wrong with a decision, or null. A note is always needed; a part refund is more than nothing and less than everything paid. */
export function decisionProblem(outcome: DisputeOutcome | null, refundText: string, paidCents: number, note: string): string | null {
  if (!outcome) return 'Choose what to do.';
  if (note.trim() === '') return 'Write a note: the customer and the professional can be shown it.';
  if (note.trim().length > 500) return 'Keep the note to 500 characters.';
  if (outcome === 'refund_part') {
    const cents = refundToCents(refundText);
    if (cents === null || cents <= 0 || cents >= paidCents) return `A part refund must be more than nothing and less than everything paid (${money(paidCents)}).`;
  }
  return null;
}

export async function fetchDisputes(status: DisputeStatus | 'all' = 'open'): Promise<Dispute[]> {
  return parseDisputes(await call('cms_pro_disputes', { p_status: status }));
}

export async function resolveDispute(id: string, outcome: DisputeOutcome, refundCents: number | null, note: string): Promise<void> {
  await call('cms_pro_dispute_resolve', { p_dispute: id, p_outcome: outcome, p_refund_cents: outcome === 'refund_part' ? refundCents : null, p_note: note.trim() });
}

export async function fetchPayouts(status: PayoutStatus | 'all' = 'releasable'): Promise<Payout[]> {
  return parsePayouts(await call('cms_pro_payouts', { p_status: status }));
}

export async function markPayoutPaid(id: string, reference: string): Promise<void> {
  await call('cms_pro_payout_paid', { p_payout: id, p_reference: reference.trim() });
}

export async function fetchSettings(): Promise<MarketSettings> {
  return parseSettings(await call('cms_pro_settings'));
}

export async function saveSettings(commissionText: string, freeCancelDays: number, confirmDays: number): Promise<MarketSettings> {
  const bps = percentToBps(commissionText);
  if (bps === null) throw new Error('The commission must be a percentage between 0 and 50.');
  return parseSettings(await call('cms_pro_settings_set', { p_commission_bps: bps, p_free_cancel_days: freeCancelDays, p_confirm_days: confirmDays }));
}
