import { describe, expect, it } from 'vitest';
import { decisionProblem, money, parseDisputes, parsePayouts, parseSettings, percentText, percentToBps, refundToCents, settingsProblem } from './marketplace';

const dispute = (over: Record<string, unknown> = {}) => ({
  id: 'd1', status: 'open', reason: 'The DJ did not turn up', outcome: null, refund_cents: null, note: null, created_at: '2026-11-01T10:00:00Z', decided_at: null,
  booking: { id: 'b1', title: 'Wedding DJ set', event_date: '2026-10-30', total_cents: 100000, paid_cents: 100000, currency: 'cad', provider: 'DJ Dee', client: { name: 'Bob Ray', handle: 'bob' } },
  ...over,
});

describe('reading the disputes', () => {
  it('reads a dispute with its booking, the professional and the customer', () => {
    const [d] = parseDisputes([dispute()]);
    expect(d).toMatchObject({ id: 'd1', status: 'open', reason: 'The DJ did not turn up', outcome: null, refundCents: null });
    expect(d.booking).toEqual({ id: 'b1', title: 'Wedding DJ set', eventDate: '2026-10-30', totalCents: 100000, paidCents: 100000, currency: 'cad', provider: 'DJ Dee', client: { name: 'Bob Ray', handle: 'bob' } });
  });

  it('reads a decision', () => {
    const [d] = parseDisputes([dispute({ status: 'resolved', outcome: 'refund_part', refund_cents: 40000, note: 'Two hours late', decided_at: '2026-11-02T10:00:00Z' })]);
    expect(d).toMatchObject({ status: 'resolved', outcome: 'refund_part', refundCents: 40000, note: 'Two hours late', decidedAt: '2026-11-02T10:00:00Z' });
  });

  it('leaves out a row it cannot read instead of showing it wrong', () => {
    const rows = [dispute({ id: null }), dispute({ reason: '' }), dispute({ status: 'weird' }), dispute({ created_at: null }), dispute({ booking: null }), dispute({ booking: { title: 'x' } }), 'junk', null, dispute({ id: 'ok' })];
    expect(parseDisputes(rows).map((d) => d.id)).toEqual(['ok']);
    expect(parseDisputes(null)).toEqual([]);
    expect(parseDisputes({})).toEqual([]);
  });

  it('copes with a customer whose account is gone, an unknown outcome and a missing title', () => {
    const [d] = parseDisputes([dispute({ outcome: 'mystery', booking: { id: 'b1', client: null, title: null, currency: null } })]);
    expect(d.outcome).toBeNull();
    expect(d.booking.client).toBeNull();
    expect(d.booking.title).toBe('A booking');
    expect(d.booking.currency).toBe('cad');
  });
});

describe('reading the payouts', () => {
  const row = (over: Record<string, unknown> = {}) => ({ id: 'p1', status: 'releasable', gross_cents: 100000, commission_cents: 5000, net_cents: 95000, reference: null, paid_at: null, created_at: '2026-11-01T10:00:00Z', currency: 'cad', title: 'Wedding DJ set', event_date: '2026-10-30', provider: 'DJ Dee', ...over });

  it('reads what is owed to a professional, less the commission', () => {
    const [p] = parsePayouts([row()]);
    expect(p).toMatchObject({ id: 'p1', status: 'releasable', grossCents: 100000, commissionCents: 5000, netCents: 95000, title: 'Wedding DJ set', provider: 'DJ Dee', reference: null });
  });

  it('reads one that has been paid, with its reference', () => {
    const [p] = parsePayouts([row({ status: 'paid', reference: 'etransfer 7788', paid_at: '2026-11-03T10:00:00Z' })]);
    expect(p).toMatchObject({ status: 'paid', reference: 'etransfer 7788', paidAt: '2026-11-03T10:00:00Z' });
  });

  it('leaves out what it cannot read', () => {
    expect(parsePayouts([row({ id: null }), row({ status: 'held' }), row({ created_at: null }), 'x', row({ id: 'ok' })]).map((p) => p.id)).toEqual(['ok']);
    expect(parsePayouts(undefined)).toEqual([]);
  });
});

describe('settings and money in words', () => {
  it('reads the settings, with the usual ones when something is missing', () => {
    expect(parseSettings({ commission_bps: 800, free_cancel_days: 0, confirm_days: 5 })).toEqual({ commissionBps: 800, freeCancelDays: 0, confirmDays: 5 });
    expect(parseSettings(null)).toEqual({ commissionBps: 500, freeCancelDays: 7, confirmDays: 3 });
  });

  it('writes money with its currency and thousands', () => {
    expect(money(100000)).toBe('CAD 1,000.00');
    expect(money(5)).toBe('CAD 0.05');
    expect(money(123456789, 'usd')).toBe('USD 1,234,567.89');
    expect(money(-250)).toBe('-CAD 2.50');
  });

  it('writes a commission as a percentage', () => {
    expect(percentText(500)).toBe('5%');
    expect(percentText(250)).toBe('2.5%');
    expect(percentText(0)).toBe('0%');
    expect(percentText(5000)).toBe('50%');
    expect(percentText(125)).toBe('1.25%');
  });

  it('reads a typed percentage between 0 and 50 with at most two decimals', () => {
    expect(percentToBps('5')).toBe(500);
    expect(percentToBps(' 2.5% ')).toBe(250);
    expect(percentToBps('0')).toBe(0);
    expect(percentToBps('50')).toBe(5000);
    expect(percentToBps('1.25')).toBe(125);
    for (const bad of ['', 'abc', '50.01', '51', '-1', '1.234', '5 percent', '100']) expect(percentToBps(bad)).toBeNull();
  });

  it('says what is wrong with settings, in the database\'s own limits', () => {
    expect(settingsProblem('5', 7, 3)).toBeNull();
    expect(settingsProblem('x', 7, 3)).toMatch(/commission/);
    expect(settingsProblem('5', -1, 3)).toMatch(/Free cancellation/);
    expect(settingsProblem('5', 61, 3)).toMatch(/Free cancellation/);
    expect(settingsProblem('5', 60, 3)).toBeNull();
    expect(settingsProblem('5', 7.5, 3)).toMatch(/Free cancellation/);
    expect(settingsProblem('5', 7, 0)).toMatch(/Automatic confirmation/);
    expect(settingsProblem('5', 7, 31)).toMatch(/Automatic confirmation/);
    expect(settingsProblem('5', 7, 30)).toBeNull();
    expect(settingsProblem('5', 0, 1)).toBeNull();
  });
});

describe('deciding a dispute', () => {
  it('reads a typed refund', () => {
    expect(refundToCents('400')).toBe(40000);
    expect(refundToCents('400.5')).toBe(40050);
    expect(refundToCents('1,250.25')).toBe(125025);
    expect(refundToCents('0.01')).toBe(1);
    for (const bad of ['', 'abc', '-5', '1.234', '12345678']) expect(refundToCents(bad)).toBeNull();
  });

  it('needs an outcome and a note', () => {
    expect(decisionProblem(null, '', 100000, 'x')).toBe('Choose what to do.');
    expect(decisionProblem('release', '', 100000, '   ')).toMatch(/Write a note/);
    expect(decisionProblem('release', '', 100000, 'n'.repeat(501))).toMatch(/500 characters/);
    expect(decisionProblem('release', '', 100000, 'n'.repeat(500))).toBeNull();
    expect(decisionProblem('refund_full', '', 100000, 'No one came')).toBeNull();
  });

  it('a part refund is more than nothing and less than everything paid', () => {
    expect(decisionProblem('refund_part', '', 100000, 'half')).toMatch(/more than nothing/);
    expect(decisionProblem('refund_part', '0', 100000, 'half')).toMatch(/more than nothing/);
    expect(decisionProblem('refund_part', '1000', 100000, 'half')).toMatch(/less than everything paid \(CAD 1,000.00\)/);
    expect(decisionProblem('refund_part', '1500', 100000, 'half')).toMatch(/less than everything/);
    expect(decisionProblem('refund_part', '999.99', 100000, 'half')).toBeNull();
    expect(decisionProblem('refund_part', '0.01', 100000, 'half')).toBeNull();
  });
});
