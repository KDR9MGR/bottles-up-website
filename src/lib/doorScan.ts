// The rules behind the door scanner (website brief section 5): what each scan outcome means to the person at the door,
// when a camera read should be acted on, and how to read what the database returns. Pure functions, so they are tested
// without a camera or a browser. Who may admit whom is decided by the database (door_scan_ticket); nothing here grants it.

export type DoorResult =
  | 'ok'
  | 'already_checked_in'
  | 'not_paid'
  | 'not_found'
  | 'expired'
  | 'code_required'
  | 'code_incorrect'
  | 'code_expired'
  | 'no_code_requested'
  | 'wrong_event'
  // Raised by the screen, not the database:
  | 'access_ended'
  | 'scan_error';

export type Tone = 'ok' | 'warn' | 'error';

export interface ResultCopy {
  label: string;
  /** One sentence telling the person what to do next. */
  hint: string;
  tone: Tone;
}

export const RESULT_COPY: Record<DoorResult, ResultCopy> = {
  ok: { label: 'Admit', hint: 'Let them in.', tone: 'ok' },
  already_checked_in: { label: 'Already checked in', hint: 'This ticket has already been used. Check with the guest.', tone: 'warn' },
  not_paid: { label: 'Not paid', hint: 'This order was never paid, or was refunded. Do not admit.', tone: 'error' },
  not_found: { label: 'Ticket not found', hint: 'This code is not a BottlesUp ticket. Try again or search by name.', tone: 'error' },
  expired: { label: 'Event has ended', hint: 'This ticket is for an event that is over.', tone: 'error' },
  code_required: { label: 'Entry code required', hint: 'This ticket is non-transferable. Ask the guest for the 6-digit code from their email.', tone: 'warn' },
  code_incorrect: { label: 'Code is incorrect', hint: 'Check the code with the guest and try again.', tone: 'error' },
  code_expired: { label: 'Code expired or locked', hint: 'Ask the guest to request a new code from their ticket email.', tone: 'error' },
  no_code_requested: { label: 'No code requested yet', hint: 'Ask the guest to request their entry code from their ticket email.', tone: 'error' },
  wrong_event: { label: 'Not for this event', hint: 'This ticket is for a different event. Do not admit it here.', tone: 'error' },
  access_ended: { label: 'Your access has ended', hint: 'Your shift or invitation is over, or you were signed out. Sign in again or ask your manager.', tone: 'error' },
  scan_error: { label: 'Scan failed', hint: 'Something went wrong. Try again.', tone: 'error' },
};

const DB_RESULTS: readonly string[] = [
  'ok', 'already_checked_in', 'not_paid', 'not_found', 'expired', 'code_required',
  'code_incorrect', 'code_expired', 'no_code_requested', 'wrong_event',
];

export function isDoorResult(value: unknown): value is DoorResult {
  return typeof value === 'string' && value in RESULT_COPY;
}

/** The outcomes after which the guest should be asked for their entry code. */
export function needsEntryCode(result: DoorResult): boolean {
  return result === 'code_required' || result === 'code_incorrect' || result === 'code_expired' || result === 'no_code_requested';
}

/** Only an outcome where the guest is not let in again with the same code needs the code box; a final one does not. */
export function canRetryCode(result: DoorResult): boolean {
  return result === 'code_required' || result === 'code_incorrect';
}

// ---------------------------------------------------------------------------
// What a camera read should do
// ---------------------------------------------------------------------------

/** Ignore an identical read for this long, so a ticket still in front of the camera after "Scan next" is not counted twice. */
export const SAME_CODE_COOLDOWN_MS = 5000;

export interface ScanGate {
  /** A check is already in flight. */
  busy: boolean;
  /** The result card is showing: the camera keeps reading but must not act. */
  paused: boolean;
  last: { code: string; at: number } | null;
  now: number;
}

export function shouldProcessScan(code: string, gate: ScanGate, cooldownMs: number = SAME_CODE_COOLDOWN_MS): boolean {
  if (gate.busy || gate.paused) return false;
  if (normalizeScan(code) === '') return false;
  if (gate.last && gate.last.code === code && gate.now - gate.last.at < cooldownMs) return false;
  return true;
}

/** What was scanned or typed, cleaned up: surrounding spaces removed and a sane length. Empty means nothing to check. */
export function normalizeScan(raw: string): string {
  return raw.trim().slice(0, 200);
}

// ---------------------------------------------------------------------------
// Reading what the database returns
// ---------------------------------------------------------------------------

export interface ScanOutcome {
  result: DoorResult;
  customerName: string | null;
  eventTitle: string | null;
  tierName: string | null;
  quantity: number | null;
  attemptsRemaining: number | null;
}

const str = (v: unknown): string | null => (typeof v === 'string' && v !== '' ? v : null);

/** One door_scan_ticket / door_verify_ticket_code row. A result this code does not know is treated as a failed scan, never as "ok". */
export function parseScanOutcome(row: Record<string, unknown> | undefined | null): ScanOutcome {
  const known = row && typeof row.result === 'string' && DB_RESULTS.includes(row.result);
  return {
    result: known ? (row.result as DoorResult) : 'scan_error',
    customerName: str(row?.customer_name),
    eventTitle: str(row?.event_title),
    tierName: str(row?.tier_name),
    quantity: typeof row?.quantity === 'number' ? row.quantity : null,
    attemptsRemaining: typeof row?.attempts_remaining === 'number' ? row.attempts_remaining : null,
  };
}

/**
 * What a failed call means at the door. "Not authorized" is the database saying this person no longer holds a door role
 * (the shift ended, they were removed, or they are signed out); anything else is a failed scan to retry.
 */
export function outcomeFromErrorMessage(message: string): DoorResult {
  return /not authori[sz]ed|access has ended|signed out/i.test(message) ? 'access_ended' : 'scan_error';
}

export function emptyOutcome(result: DoorResult): ScanOutcome {
  return { result, customerName: null, eventTitle: null, tierName: null, quantity: null, attemptsRemaining: null };
}

export interface DoorEvent {
  eventId: string;
  title: string;
  venueName: string;
  startDate: string;
  endDate: string | null;
  scope: 'event' | 'venue';
  guestsExpected: number;
  guestsAdmitted: number;
}

export function parseDoorEvent(row: Record<string, unknown>): DoorEvent | null {
  if (typeof row.event_id !== 'string' || typeof row.title !== 'string' || typeof row.start_date !== 'string') return null;
  return {
    eventId: row.event_id,
    title: row.title,
    venueName: str(row.venue_name) ?? '',
    startDate: row.start_date,
    endDate: str(row.end_date),
    scope: row.scope === 'event' ? 'event' : 'venue',
    guestsExpected: typeof row.guests_expected === 'number' ? row.guests_expected : 0,
    guestsAdmitted: typeof row.guests_admitted === 'number' ? row.guests_admitted : 0,
  };
}

export interface Guest {
  orderId: string;
  name: string;
  ticketCode: string;
  tierName: string;
  quantity: number;
  checkedInAt: string | null;
  needsCode: boolean;
}

export function parseGuest(row: Record<string, unknown>): Guest | null {
  if (typeof row.order_id !== 'string' || typeof row.ticket_code !== 'string') return null;
  return {
    orderId: row.order_id,
    name: str(row.customer_name) ?? 'Guest',
    ticketCode: row.ticket_code,
    tierName: str(row.tier_name) ?? '',
    quantity: typeof row.quantity === 'number' ? row.quantity : 1,
    checkedInAt: str(row.checked_in_at),
    needsCode: row.needs_code === true,
  };
}

// ---------------------------------------------------------------------------
// Wording
// ---------------------------------------------------------------------------

/** "12 of 80 guests in". */
export function admittedSummary(e: Pick<DoorEvent, 'guestsAdmitted' | 'guestsExpected'>): string {
  return `${e.guestsAdmitted} of ${e.guestsExpected} guest${e.guestsExpected === 1 ? '' : 's'} in`;
}

/** 0-100, whole number, never above 100 and 0 when nobody is expected. */
export function admittedPercent(e: Pick<DoorEvent, 'guestsAdmitted' | 'guestsExpected'>): number {
  if (e.guestsExpected <= 0) return 0;
  return Math.min(100, Math.round((e.guestsAdmitted / e.guestsExpected) * 100));
}

/** The event a screen should start on: one that is already running, otherwise the next to start. */
export function defaultEvent(events: readonly DoorEvent[], now: Date = new Date()): DoorEvent | null {
  if (events.length === 0) return null;
  const running = events.find((e) => new Date(e.startDate) <= now);
  return running ?? events[0];
}

/** A guest admitted, or someone still to come, for the guest list. */
export function guestStatus(g: Pick<Guest, 'checkedInAt' | 'needsCode'>): 'in' | 'needs_code' | 'waiting' {
  if (g.checkedInAt) return 'in';
  return g.needsCode ? 'needs_code' : 'waiting';
}
