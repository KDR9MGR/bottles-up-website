import { describe, expect, it } from 'vitest';
import {
  admittedPercent, admittedSummary, canRetryCode, defaultEvent, emptyOutcome, guestStatus, isDoorResult, needsEntryCode, normalizeScan,
  outcomeFromErrorMessage, parseDoorEvent, parseGuest, parseScanOutcome, RESULT_COPY, SAME_CODE_COOLDOWN_MS, shouldProcessScan, type DoorEvent, type ScanGate,
} from './doorScan';

const gate = (over: Partial<ScanGate> = {}): ScanGate => ({ busy: false, paused: false, last: null, now: 100_000, ...over });

describe('what a camera read should do', () => {
  it('acts on a fresh code', () => {
    expect(shouldProcessScan('T-PAID', gate())).toBe(true);
  });

  it('ignores reads while a check is running or the result card is showing', () => {
    expect(shouldProcessScan('T-PAID', gate({ busy: true }))).toBe(false);
    expect(shouldProcessScan('T-PAID', gate({ paused: true }))).toBe(false);
  });

  it('ignores the same ticket for five seconds, so one held in front of the camera is not counted twice', () => {
    const last = { code: 'T-PAID', at: 100_000 - 1000 };
    expect(shouldProcessScan('T-PAID', gate({ last }))).toBe(false);
    expect(shouldProcessScan('T-PAID', gate({ last: { code: 'T-PAID', at: 100_000 - (SAME_CODE_COOLDOWN_MS - 1) } }))).toBe(false);
  });

  it('accepts the same ticket again once the cooldown has passed', () => {
    expect(shouldProcessScan('T-PAID', gate({ last: { code: 'T-PAID', at: 100_000 - SAME_CODE_COOLDOWN_MS } }))).toBe(true);
  });

  it('never delays a DIFFERENT ticket because of the last one', () => {
    expect(shouldProcessScan('T-OTHER', gate({ last: { code: 'T-PAID', at: 100_000 - 10 } }))).toBe(true);
  });

  it.each(['', '   ', '\n\t'])('ignores an empty read (%j)', (code) => {
    expect(shouldProcessScan(code, gate())).toBe(false);
  });

  it('cleans what was scanned or typed', () => {
    expect(normalizeScan('  T-PAID \n')).toBe('T-PAID');
    expect(normalizeScan('x'.repeat(500))).toHaveLength(200);
    expect(normalizeScan('   ')).toBe('');
  });
});

describe('what each outcome tells the person at the door', () => {
  it('has a label, a next step and a tone for every outcome', () => {
    for (const [key, copy] of Object.entries(RESULT_COPY)) {
      expect(copy.label.length, key).toBeGreaterThan(3);
      expect(copy.hint.length, key).toBeGreaterThan(10);
      expect(['ok', 'warn', 'error']).toContain(copy.tone);
    }
  });

  it('only "ok" is green: nothing else can look like permission to admit', () => {
    for (const [key, copy] of Object.entries(RESULT_COPY)) {
      expect(copy.tone === 'ok', key).toBe(key === 'ok');
    }
  });

  it('amber means "one more step", red means "stop": each outcome is in the right group', () => {
    const amber = Object.entries(RESULT_COPY).filter(([, c]) => c.tone === 'warn').map(([k]) => k).sort();
    const red = Object.entries(RESULT_COPY).filter(([, c]) => c.tone === 'error').map(([k]) => k).sort();
    // Already used: check with the guest. Code required: one more step before they can be admitted.
    expect(amber).toEqual(['already_checked_in', 'code_required']);
    // Everything else is a stop. In particular an unpaid ticket must never look like a mere warning.
    expect(red).toEqual(['access_ended', 'code_expired', 'code_incorrect', 'expired', 'no_code_requested', 'not_found', 'not_paid', 'scan_error', 'wrong_event']);
  });

  it('a ticket for another event is a hard no, with its own wording', () => {
    expect(RESULT_COPY.wrong_event.tone).toBe('error');
    expect(RESULT_COPY.wrong_event.label).toMatch(/not for this event/i);
  });

  it('asks for the entry code only in the code-related outcomes', () => {
    for (const r of ['code_required', 'code_incorrect', 'code_expired', 'no_code_requested'] as const) expect(needsEntryCode(r)).toBe(true);
    for (const r of ['ok', 'already_checked_in', 'not_paid', 'not_found', 'expired', 'wrong_event', 'access_ended', 'scan_error'] as const) expect(needsEntryCode(r)).toBe(false);
  });

  it('only offers another try while the code can still work; a locked or missing code needs the guest to act', () => {
    expect(canRetryCode('code_required')).toBe(true);
    expect(canRetryCode('code_incorrect')).toBe(true);
    expect(canRetryCode('code_expired')).toBe(false);
    expect(canRetryCode('no_code_requested')).toBe(false);
  });

  it('recognises known outcomes only', () => {
    expect(isDoorResult('ok')).toBe(true);
    expect(isDoorResult('wrong_event')).toBe(true);
    expect(isDoorResult('admit')).toBe(false);
    expect(isDoorResult(undefined)).toBe(false);
  });
});

describe('reading what the database returns', () => {
  it('reads a scan outcome', () => {
    expect(parseScanOutcome({ result: 'ok', customer_name: 'Ada', event_title: 'Friday', tier_name: 'General', quantity: 2 })).toEqual({
      result: 'ok', customerName: 'Ada', eventTitle: 'Friday', tierName: 'General', quantity: 2, attemptsRemaining: null,
    });
    expect(parseScanOutcome({ result: 'code_incorrect', attempts_remaining: 2 }).attemptsRemaining).toBe(2);
  });

  it('treats an unknown, missing or malformed result as a failed scan, never as ok', () => {
    expect(parseScanOutcome({ result: 'approved' }).result).toBe('scan_error');
    expect(parseScanOutcome({}).result).toBe('scan_error');
    expect(parseScanOutcome(undefined).result).toBe('scan_error');
    expect(parseScanOutcome(null).result).toBe('scan_error');
    expect(parseScanOutcome({ result: 'access_ended' }).result).toBe('scan_error'); // not something the database says
  });

  it('keeps a wrong-event answer free of guest details', () => {
    const o = parseScanOutcome({ result: 'wrong_event', customer_name: null, event_title: null, tier_name: null, quantity: null });
    expect(o).toMatchObject({ result: 'wrong_event', customerName: null, tierName: null, quantity: null });
  });

  const eventRow = { event_id: 'e1', title: 'Friday', venue_name: 'Club A', start_date: '2026-10-10T22:00:00Z', end_date: null, scope: 'venue', guests_expected: 80, guests_admitted: 12 };

  it('reads an event', () => {
    expect(parseDoorEvent(eventRow)).toMatchObject({ eventId: 'e1', title: 'Friday', scope: 'venue', guestsExpected: 80, guestsAdmitted: 12, endDate: null });
    expect(parseDoorEvent({ ...eventRow, scope: 'event' })?.scope).toBe('event');
  });

  it('drops an event with missing identifiers and defaults missing counts to zero', () => {
    expect(parseDoorEvent({ ...eventRow, event_id: undefined })).toBeNull();
    expect(parseDoorEvent({ ...eventRow, title: 5 })).toBeNull();
    expect(parseDoorEvent({ ...eventRow, guests_expected: undefined, guests_admitted: undefined })).toMatchObject({ guestsExpected: 0, guestsAdmitted: 0 });
  });

  it('reads a guest', () => {
    expect(parseGuest({ order_id: 'o1', customer_name: 'Ada', ticket_code: 'T-1', tier_name: 'General', quantity: 2, checked_in_at: null, needs_code: false })).toEqual({
      orderId: 'o1', name: 'Ada', ticketCode: 'T-1', tierName: 'General', quantity: 2, checkedInAt: null, needsCode: false,
    });
    expect(parseGuest({ order_id: 'o1', ticket_code: 'T-1' })).toMatchObject({ name: 'Guest', quantity: 1 });
    expect(parseGuest({ order_id: 'o1' })).toBeNull();
    expect(parseGuest({ ticket_code: 'T-1' })).toBeNull();
  });
});

describe('wording and defaults', () => {
  const ev = (over: Partial<DoorEvent>): DoorEvent => ({
    eventId: 'e', title: 'T', venueName: 'V', startDate: '2026-10-10T22:00:00Z', endDate: null, scope: 'venue', guestsExpected: 0, guestsAdmitted: 0, ...over,
  });

  it('summarises how many are in', () => {
    expect(admittedSummary(ev({ guestsAdmitted: 12, guestsExpected: 80 }))).toBe('12 of 80 guests in');
    expect(admittedSummary(ev({ guestsAdmitted: 0, guestsExpected: 1 }))).toBe('0 of 1 guest in');
  });

  it('gives a percentage that is never over 100 and is 0 when nobody is expected', () => {
    expect(admittedPercent(ev({ guestsAdmitted: 12, guestsExpected: 80 }))).toBe(15);
    expect(admittedPercent(ev({ guestsAdmitted: 0, guestsExpected: 0 }))).toBe(0);
    expect(admittedPercent(ev({ guestsAdmitted: 9, guestsExpected: 5 }))).toBe(100);
  });

  it('starts on the event that is already running, otherwise the next one', () => {
    const now = new Date('2026-10-10T23:00:00Z');
    const live = ev({ eventId: 'live', startDate: '2026-10-10T21:00:00Z' });
    const later = ev({ eventId: 'later', startDate: '2026-10-11T02:00:00Z' });
    expect(defaultEvent([later, live], now)?.eventId).toBe('live');
    expect(defaultEvent([later], now)?.eventId).toBe('later');
    expect(defaultEvent([], now)).toBeNull();
  });

  it('labels guests by whether they are in, waiting, or need their code', () => {
    expect(guestStatus({ checkedInAt: '2026-10-10T22:00:00Z', needsCode: true })).toBe('in');
    expect(guestStatus({ checkedInAt: null, needsCode: true })).toBe('needs_code');
    expect(guestStatus({ checkedInAt: null, needsCode: false })).toBe('waiting');
  });
});

describe('what a failed call means at the door', () => {
  it.each([
    ['not authorized', 'access_ended'],
    ['Not Authorised', 'access_ended'],
    ['Your access has ended, or you are signed out.', 'access_ended'],
    ['JWT expired: signed out', 'access_ended'],
    ['network request failed', 'scan_error'],
    ['relation "site_orders" does not exist', 'scan_error'],
    ['', 'scan_error'],
  ])('%j -> %s', (message, expected) => {
    expect(outcomeFromErrorMessage(message)).toBe(expected);
  });

  it('an empty outcome carries no guest details', () => {
    expect(emptyOutcome('scan_error')).toEqual({ result: 'scan_error', customerName: null, eventTitle: null, tierName: null, quantity: null, attemptsRemaining: null });
  });
});
