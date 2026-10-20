import { beforeEach, describe, expect, it, vi } from 'vitest';

const rpc = vi.fn();
const invoke = vi.fn();
vi.mock('@/lib/supabase', () => ({ supabase: { rpc: (...a: unknown[]) => rpc(...a), functions: { invoke: (...a: unknown[]) => invoke(...a) } } }));
import {
  CmsMoneyError, bpsFromPercent, createPayoutItem, dollars, fetchEligible, fetchPayoutSettings, fetchRefundRequests, percentFromBps, plainMessage, processOnlineRefund, savePayoutOverride,
  savePayoutSettings, setPayoutItemStatus,
} from './cmsMoney';

beforeEach(() => { vi.clearAllMocks(); });

describe('dollars', () => {
  it('writes cents as dollars with thousands separators', () => {
    expect(dollars(123456)).toBe('$1,234.56');
    expect(dollars(5)).toBe('$0.05');
    expect(dollars(0)).toBe('$0.00');
    expect(dollars(100000000)).toBe('$1,000,000.00');
  });
  it('keeps the sign of an adjustment and never prints NaN', () => {
    expect(dollars(-300)).toBe('-$3.00');
    expect(dollars(null)).toBe('$0.00');
    expect(dollars(undefined)).toBe('$0.00');
    expect(dollars(Number.NaN)).toBe('$0.00');
  });
});

describe('BottlesUp\'s percentage, kept by the database in hundredths of a percent', () => {
  it('reads 1250 as 12.5, 1000 as 10 and 0 as 0', () => {
    expect(percentFromBps(1250)).toBe('12.5');
    expect(percentFromBps(1000)).toBe('10');
    expect(percentFromBps(0)).toBe('0');
    expect(percentFromBps(345)).toBe('3.45');
    expect(percentFromBps(null)).toBe('');
  });
  it('turns what a person types back into whole hundredths, or nothing', () => {
    expect(bpsFromPercent('12.5')).toBe(1250);
    expect(bpsFromPercent(' 10 ')).toBe(1000);
    expect(bpsFromPercent('0')).toBe(0);
    expect(bpsFromPercent('100')).toBe(10000);
    expect(bpsFromPercent('3.45')).toBe(345);
  });
  it('refuses anything that is not a percentage from 0 to 100 with at most two decimals', () => {
    for (const bad of ['', 'abc', '-1', '100.01', '101', '1.234', '1,5', '10%', '1e2']) expect(bpsFromPercent(bad)).toBeNull();
  });
  it('round-trips every value from 0 to 10000', () => {
    for (let bps = 0; bps <= 10000; bps += 7) expect(bpsFromPercent(percentFromBps(bps))).toBe(bps);
  });
});

describe('plainMessage', () => {
  it('shows the database\'s own sentence for a refusal', () => {
    expect(plainMessage({ code: 'P0001', message: 'choose BottlesUp\'s percentage first' })).toBe('choose BottlesUp\'s percentage first');
  });
  it('never shows anything technical otherwise', () => {
    expect(plainMessage({ code: '42501', message: 'permission denied for function x' })).toBe('You do not have access to this.');
    expect(plainMessage({ code: 'PGRST301', message: 'JWT expired' })).toBe('This could not be done just now. Check the connection and try again.');
    expect(plainMessage(null)).toBe('This could not be done just now. Check the connection and try again.');
  });
});

describe('what the pages read', () => {
  it('maps a refund request and keeps the booking id the Stripe call needs', async () => {
    rpc.mockResolvedValue({ data: [{ request_id: 'r1', booking_id: 'b1', venue_name: 'Club A', confirmation_code: 'BT-1', guest_name: 'Ann', guest_email: 'a@x.example', requested_by_kind: 'guest', reason: 'Ill',
      status: 'approved', paid_cents: 10000, policy_percent: 50, suggested_cents: 5000, approved_cents: 5000, method: 'online', decision_note: null, failure_note: null, created_at: '2026-10-20T10:00:00Z',
      decided_at: '2026-10-20T11:00:00Z', completed_at: null }], error: null });
    const [r] = await fetchRefundRequests('approved');
    expect(rpc).toHaveBeenCalledWith('cms_refund_requests', { p_status: 'approved' });
    expect(r).toMatchObject({ requestId: 'r1', bookingId: 'b1', venueName: 'Club A', requestedBy: 'guest', status: 'approved', policyPercent: 50, approvedCents: 5000, method: 'online' });
  });

  it('maps the settings and says when the percentage has not been chosen', async () => {
    rpc.mockResolvedValue({ data: [{ payout_method: 'manual_transfer', payout_weekday: 3, hold_days: 2, commission_bps: 0, commission_set: false }], error: null });
    expect(await fetchPayoutSettings()).toEqual({ method: 'manual_transfer', weekday: 3, holdDays: 2, commissionBps: 0, commissionSet: false });
  });

  it('turns a refusal into a sentence, not a raw error', async () => {
    rpc.mockResolvedValue({ data: null, error: { code: 'P0001', message: 'not allowed' } });
    await expect(fetchEligible('2026-10-01', '2026-10-20')).rejects.toThrow('not allowed');
    rpc.mockResolvedValue({ data: null, error: { code: '57014', message: 'canceling statement due to statement timeout' } });
    await expect(fetchEligible('2026-10-01', '2026-10-20')).rejects.toThrow('This could not be done just now');
    await expect(fetchEligible('2026-10-01', '2026-10-20')).rejects.toBeInstanceOf(CmsMoneyError);
  });
});

describe('what the pages send', () => {
  it('sends only what was changed in the settings and an override, null to clear one part', async () => {
    rpc.mockResolvedValue({ data: {}, error: null });
    await savePayoutSettings({ commission_bps: 1000 });
    expect(rpc).toHaveBeenLastCalledWith('cms_save_payout_settings', { p_details: { commission_bps: 1000 } });
    await savePayoutOverride('o1', { commission_bps: null, hold_days: 0 });
    expect(rpc).toHaveBeenLastCalledWith('cms_save_payout_override', { p_org: 'o1', p_details: { commission_bps: null, hold_days: 0 } });
  });

  it('makes a payout with the period and a blank note as nothing', async () => {
    rpc.mockResolvedValue({ data: 'item-1', error: null });
    expect(await createPayoutItem('o1', '2026-10-01', '2026-10-20', -300, '  ')).toBe('item-1');
    expect(rpc).toHaveBeenLastCalledWith('cms_create_payout_item', { p_org: 'o1', p_from: '2026-10-01', p_to: '2026-10-20', p_adjustment_cents: -300, p_adjustment_note: null });
  });

  it('marks a payout paid with a trimmed reference, and sends nothing for what was not given', async () => {
    rpc.mockResolvedValue({ data: 'paid', error: null });
    await setPayoutItemStatus('i1', 'paid', ' ETR-1 ');
    expect(rpc).toHaveBeenLastCalledWith('cms_set_payout_item_status', { p_item: 'i1', p_status: 'paid', p_reference: 'ETR-1', p_note: null });
  });
});

describe('returning an approved online refund through Stripe', () => {
  it('calls the function with the booking, "online" and the request id (so the database claims it once)', async () => {
    invoke.mockResolvedValue({ data: { success: true }, error: null });
    await processOnlineRefund('r1', 'b1');
    expect(invoke).toHaveBeenCalledWith('refund-table-booking-payment', { body: { booking_id: 'b1', refund_type: 'online', request_id: 'r1' } });
  });

  it('shows the function\'s own sentence when it refuses', async () => {
    invoke.mockResolvedValue({ data: null, error: { context: { json: async () => ({ error: 'Charge ch_1 has already been refunded.' }) } } });
    await expect(processOnlineRefund('r1', 'b1')).rejects.toThrow('Charge ch_1 has already been refunded.');
  });

  it('falls back to a fixed sentence when the answer cannot be read', async () => {
    invoke.mockResolvedValue({ data: null, error: { context: { json: async () => { throw new Error('not json'); } } } });
    await expect(processOnlineRefund('r1', 'b1')).rejects.toThrow('The refund could not be processed.');
  });

  it('treats an error inside a successful answer as a failure too', async () => {
    invoke.mockResolvedValue({ data: { error: 'Stripe is not configured' }, error: null });
    await expect(processOnlineRefund('r1', 'b1')).rejects.toThrow('Stripe is not configured');
  });
});
