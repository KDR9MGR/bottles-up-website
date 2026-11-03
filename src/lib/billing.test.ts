import { beforeEach, describe, expect, it, vi } from 'vitest';

const h = vi.hoisted(() => ({ call: vi.fn() }));
vi.mock('./account', async (orig) => ({ ...(await orig<typeof import('./account')>()), call: h.call }));
import {
  SOURCE_LABELS, amountToCents, fetchBillingSettings, fetchCreators, fetchCredits, fetchSubscriptions, formFrom, markCreatorPaid, markCreditPaid, parseBillingSettings, parseCreators, parseCredits,
  parseSubscriptions, saveBillingSettings, settingsProblem, type SettingsForm,
} from './billing';

beforeEach(() => h.call.mockReset());

const goodForm: SettingsForm = { monthly: '29.99', yearly: '299', priceMonthly: '', priceYearly: '', subscribedCommission: '0', referralCredit: '5', referralDays: '90', referralCap: '50', tipCommission: '5', tipMin: '2', tipMax: '500' };

describe('reading the settings', () => {
  it('reads every figure, and the Stripe prices as nothing when there are none', () => {
    const s = parseBillingSettings({ sub_monthly_cents: 2999, sub_yearly_cents: 29900, currency: 'cad', stripe_price_monthly: 'price_M', stripe_price_yearly: null, subscribed_commission_bps: 250, referral_credit_cents: 500, referral_days: 90, referral_monthly_cap: 50, tip_commission_bps: 500, tip_min_cents: 200, tip_max_cents: 50000 });
    expect(s).toEqual({ monthlyCents: 2999, yearlyCents: 29900, currency: 'cad', priceMonthly: 'price_M', priceYearly: null, subscribedCommissionBps: 250, referralCreditCents: 500, referralDays: 90, referralMonthlyCap: 50, tipCommissionBps: 500, tipMinCents: 200, tipMaxCents: 50000 });
  });

  it('falls back to the starting figures for what is missing, but keeps a real zero', () => {
    const s = parseBillingSettings(null);
    expect([s.monthlyCents, s.yearlyCents, s.currency, s.referralCreditCents, s.referralDays, s.referralMonthlyCap, s.tipCommissionBps, s.tipMinCents, s.tipMaxCents]).toEqual([2999, 29900, 'cad', 500, 90, 50, 500, 200, 50000]);
    const z = parseBillingSettings({ referral_credit_cents: 0, tip_commission_bps: 0, subscribed_commission_bps: 0 });
    expect([z.referralCreditCents, z.tipCommissionBps, z.subscribedCommissionBps]).toEqual([0, 0, 0]);
  });

  it('turns the settings into the words in the boxes', () => {
    expect(formFrom(parseBillingSettings({ sub_monthly_cents: 2999, sub_yearly_cents: 29900, stripe_price_monthly: 'price_M', subscribed_commission_bps: 250, referral_credit_cents: 500, tip_commission_bps: 500, tip_min_cents: 200, tip_max_cents: 50000 }))).toEqual({
      monthly: '29.99', yearly: '299.00', priceMonthly: 'price_M', priceYearly: '', subscribedCommission: '2.5', referralCredit: '5.00', referralDays: '90', referralCap: '50', tipCommission: '5', tipMin: '2.00', tipMax: '500.00',
    });
  });
});

describe('reading the lists', () => {
  it('subscriptions: a row that cannot be read is left out', () => {
    const rows = parseSubscriptions([
      { id: 's1', profile: 'DJ Dee', plan: 'monthly', status: 'active', current_period_end: '2099-01-01T00:00:00Z', cancel_at_period_end: true, payer: { name: 'Dee', handle: 'dee' } },
      { id: 's2', plan: 'yearly', status: 'past_due', payer: null },
      { id: 's3', plan: 'weekly', status: 'active' },
      { id: 's4', plan: 'monthly', status: 'incomplete' },
      { plan: 'monthly', status: 'active' },
      'x',
    ]);
    expect(rows.map((r) => r.id)).toEqual(['s1', 's2']);
    expect(rows[0]).toMatchObject({ profile: 'DJ Dee', plan: 'monthly', status: 'active', cancelAtPeriodEnd: true, payer: { name: 'Dee', handle: 'dee' } });
    expect(rows[1]).toMatchObject({ profile: 'A profile that is gone', cancelAtPeriodEnd: false, payer: null, currentPeriodEnd: null });
    expect(parseSubscriptions(null)).toEqual([]);
  });

  it('credits: who is owed what, for what, and who to send it to', () => {
    const rows = parseCredits([
      { id: 'c1', amount_cents: 500, status: 'payable', source: 'ticket_order', created_at: '2099-01-01T00:00:00Z', referrer: { display_name: 'Ann Lee', handle: 'ann' }, referrer_person: { name: 'Ann Lee', handle: 'ann' } },
      { id: 'c2', amount_cents: 500, status: 'paid', source: 'table_booking', created_at: '2099-01-02T00:00:00Z', reference: 'etransfer 1', paid_at: '2099-01-03T00:00:00Z', referrer: null },
      { id: 'c3', amount_cents: 0, status: 'payable', source: 'ticket_order', created_at: '2099-01-01T00:00:00Z' },
      { id: 'c4', amount_cents: 500, status: 'void', source: 'ticket_order', created_at: '2099-01-01T00:00:00Z' },
      { id: 'c5', amount_cents: 500, status: 'payable', source: 'gift', created_at: '2099-01-01T00:00:00Z' },
      { id: 'c6', amount_cents: 500, status: 'payable', source: 'ticket_order' },
    ]);
    expect(rows.map((r) => r.id)).toEqual(['c1', 'c2']);
    expect(rows[0]).toMatchObject({ amountCents: 500, referrer: 'Ann Lee', referrerHandle: 'ann', person: { name: 'Ann Lee', handle: 'ann' } });
    expect(rows[1]).toMatchObject({ status: 'paid', reference: 'etransfer 1', referrer: null, person: null });
    expect(SOURCE_LABELS).toEqual({ ticket_order: 'their first ticket order', table_booking: 'their first table booking' });
  });

  it('creators: only those with something to be paid', () => {
    const rows = parseCreators([
      { creator: 'p1', name: 'DJ Dee', tips: 2, withdrawable_cents: 792, person: { name: 'Dee', handle: 'dee' } },
      { creator: 'p2', name: 'Gone', tips: 1, withdrawable_cents: 0 },
      { name: 'No id', withdrawable_cents: 100 },
      { creator: 'p3', withdrawable_cents: 300 },
    ]);
    expect(rows.map((r) => r.creator)).toEqual(['p1', 'p3']);
    expect(rows[0]).toMatchObject({ tips: 2, withdrawableCents: 792, person: { name: 'Dee', handle: 'dee' } });
    expect(rows[1].name).toBe('A profile that is gone');
  });
});

describe('what is typed in a money box', () => {
  it('is read as cents within the limits', () => {
    expect(amountToCents('29.99', 100, 1000000)).toBe(2999);
    expect(amountToCents(' 299 ', 100, 1000000)).toBe(29900);
    expect(amountToCents('1,000.5', 100, 1000000)).toBe(100050);
    expect(amountToCents('1.00', 100, 1000000)).toBe(100);
    expect(amountToCents('0.99', 100, 1000000)).toBeNull();
    expect(amountToCents('10000.00', 100, 1000000)).toBe(1000000);
    expect(amountToCents('10000.01', 100, 1000000)).toBeNull();
    expect(amountToCents('0', 0, 100)).toBe(0);
    for (const bad of ['', 'abc', '-5', '1.234', '1e3', '$5']) expect(amountToCents(bad, 0, 1000000)).toBeNull();
  });
});

describe('checking the settings before saving', () => {
  const with_ = (change: Partial<SettingsForm>) => settingsProblem({ ...goodForm, ...change });
  it('the starting figures are fine', () => expect(settingsProblem(goodForm)).toBeNull());
  it('says what is wrong, in the order of the form', () => {
    expect(with_({ monthly: '0.50' })).toBe('The monthly price must be between 1.00 and 10,000.00.');
    expect(with_({ monthly: '10000.01' })).toBe('The monthly price must be between 1.00 and 10,000.00.');
    expect(with_({ yearly: '100000.01' })).toBe('The yearly price must be between 1.00 and 100,000.00.');
    expect(with_({ priceMonthly: 'monthly' })).toBe('The monthly Stripe price id looks like price_123.');
    expect(with_({ priceYearly: 'yearly' })).toBe('The yearly Stripe price id looks like price_123.');
    expect(with_({ priceMonthly: ' price_123 ', priceYearly: 'price_456' })).toBeNull();
    expect(with_({ subscribedCommission: '51' })).toBe('The commission of a subscribed profile must be a percentage between 0 and 50.');
    expect(with_({ referralCredit: '1000.01' })).toBe('A referral credit must be between 0 and 1,000.00.');
    expect(with_({ referralCredit: '0' })).toBeNull();
    expect(with_({ referralDays: '0' })).toBe('A referral counts for 1 to 730 days.');
    expect(with_({ referralDays: '731' })).toBe('A referral counts for 1 to 730 days.');
    expect(with_({ referralDays: '1.5' })).toBe('A referral counts for 1 to 730 days.');
    expect(with_({ referralCap: '0' })).toBe('The monthly cap must be 1 to 10,000 credits.');
    expect(with_({ referralCap: '10001' })).toBe('The monthly cap must be 1 to 10,000 credits.');
    expect(with_({ tipCommission: 'lots' })).toBe('The commission on tips must be a percentage between 0 and 50.');
    expect(with_({ tipMin: '0.99' })).toBe('The smallest tip must be between 1.00 and 1,000.00.');
    expect(with_({ tipMin: '1000.01' })).toBe('The smallest tip must be between 1.00 and 1,000.00.');
    expect(with_({ tipMin: '10', tipMax: '9.99' })).toBe('The biggest tip must be at least the smallest, and at most 10,000.00.');
    expect(with_({ tipMax: '10000.01' })).toBe('The biggest tip must be at least the smallest, and at most 10,000.00.');
    expect(with_({ tipMin: '10', tipMax: '10' })).toBeNull();
  });
});

describe('talking to the database', () => {
  it('reads and saves the settings, sending the figures the database wants', async () => {
    h.call.mockResolvedValueOnce({ sub_monthly_cents: 2999 });
    expect((await fetchBillingSettings()).monthlyCents).toBe(2999);
    expect(h.call).toHaveBeenCalledWith('cms_billing_settings');
    h.call.mockResolvedValueOnce({ sub_monthly_cents: 1999 });
    const saved = await saveBillingSettings({ ...goodForm, monthly: '19.99', priceMonthly: ' price_M1 ', subscribedCommission: '2.5' });
    expect(saved.monthlyCents).toBe(1999);
    expect(h.call).toHaveBeenLastCalledWith('cms_billing_settings_set', {
      p_monthly_cents: 1999, p_yearly_cents: 29900, p_price_monthly: 'price_M1', p_price_yearly: null, p_subscribed_commission_bps: 250, p_referral_credit_cents: 500,
      p_referral_days: 90, p_referral_monthly_cap: 50, p_tip_commission_bps: 500, p_tip_min_cents: 200, p_tip_max_cents: 50000,
    });
  });

  it('does not send settings it knows are wrong', async () => {
    await expect(saveBillingSettings({ ...goodForm, monthly: '0' })).rejects.toThrow('The monthly price must be between 1.00 and 10,000.00.');
    expect(h.call).not.toHaveBeenCalled();
  });

  it('asks for the lists by status, and records payments with a trimmed reference', async () => {
    h.call.mockResolvedValue([]);
    await fetchSubscriptions();
    await fetchSubscriptions('past_due');
    await fetchCredits();
    await fetchCredits('paid');
    await fetchCreators();
    await markCreditPaid('c1', '  etransfer 1 ');
    await markCreatorPaid('p1', ' etransfer 2 ');
    expect(h.call.mock.calls).toEqual([
      ['cms_subscriptions', { p_status: 'active' }],
      ['cms_subscriptions', { p_status: 'past_due' }],
      ['cms_referral_credits', { p_status: 'payable' }],
      ['cms_referral_credits', { p_status: 'paid' }],
      ['cms_creator_payouts'],
      ['cms_referral_credit_paid', { p_credit: 'c1', p_reference: 'etransfer 1' }],
      ['cms_creator_payout_paid', { p_creator: 'p1', p_reference: 'etransfer 2' }],
    ]);
  });
});
