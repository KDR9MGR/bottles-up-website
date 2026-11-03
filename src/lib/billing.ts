import { call } from './account';
import { money, percentText, percentToBps } from './marketplace';

// What BottlesUp staff use to look after subscriptions, referral credits, tips and what creators are owed in the customer app: the prices and percentages, who has a subscription, the
// referral credits waiting to be paid and the creators who can be paid from tips. Everything here is a call to a database function that checks the caller is a BottlesUp admin
// (20261109100000_billing_referrals_earnings); the page only shows what those functions answer.

export { money, percentText };

export type SubscriptionStatus = 'active' | 'past_due' | 'cancelled';
export type CreditStatus = 'payable' | 'paid';

export interface BillingSettings {
  monthlyCents: number;
  yearlyCents: number;
  currency: string;
  priceMonthly: string | null;
  priceYearly: string | null;
  subscribedCommissionBps: number;
  referralCreditCents: number;
  referralDays: number;
  referralMonthlyCap: number;
  tipCommissionBps: number;
  tipMinCents: number;
  tipMaxCents: number;
}

export interface Subscription {
  id: string;
  profile: string;
  plan: 'monthly' | 'yearly';
  status: SubscriptionStatus;
  currentPeriodEnd: string | null;
  cancelAtPeriodEnd: boolean;
  payer: { name: string; handle: string | null } | null;
}

export interface ReferralCredit {
  id: string;
  amountCents: number;
  status: CreditStatus;
  source: 'ticket_order' | 'table_booking';
  reference: string | null;
  createdAt: string;
  paidAt: string | null;
  referrer: string | null;
  referrerHandle: string | null;
  person: { name: string; handle: string | null } | null;
}

export interface CreatorPayout {
  creator: string;
  name: string;
  tips: number;
  withdrawableCents: number;
  person: { name: string; handle: string | null } | null;
}

const str = (v: unknown): string | null => (typeof v === 'string' && v !== '' ? v : null);
const num = (v: unknown): number => (typeof v === 'number' ? v : Number(v ?? 0) || 0);
const obj = (v: unknown): Record<string, unknown> | null => (typeof v === 'object' && v !== null && !Array.isArray(v) ? (v as Record<string, unknown>) : null);
const person = (v: unknown): { name: string; handle: string | null } | null => {
  const o = obj(v);
  return o && str(o.name) ? { name: String(o.name), handle: str(o.handle) } : null;
};

export function parseBillingSettings(v: unknown): BillingSettings {
  const o = obj(v);
  return {
    monthlyCents: num(o?.sub_monthly_cents) || 2999,
    yearlyCents: num(o?.sub_yearly_cents) || 29900,
    currency: str(o?.currency) ?? 'cad',
    priceMonthly: str(o?.stripe_price_monthly),
    priceYearly: str(o?.stripe_price_yearly),
    subscribedCommissionBps: num(o?.subscribed_commission_bps),
    referralCreditCents: o?.referral_credit_cents === undefined ? 500 : num(o.referral_credit_cents),
    referralDays: num(o?.referral_days) || 90,
    referralMonthlyCap: num(o?.referral_monthly_cap) || 50,
    tipCommissionBps: o?.tip_commission_bps === undefined ? 500 : num(o.tip_commission_bps),
    tipMinCents: num(o?.tip_min_cents) || 200,
    tipMaxCents: num(o?.tip_max_cents) || 50000,
  };
}

export function parseSubscriptions(rows: unknown): Subscription[] {
  if (!Array.isArray(rows)) return [];
  const out: Subscription[] = [];
  for (const r of rows) {
    const o = obj(r);
    const id = str(o?.id);
    const plan = o?.plan === 'monthly' || o?.plan === 'yearly' ? o.plan : null;
    const status: SubscriptionStatus | null = o?.status === 'active' || o?.status === 'past_due' || o?.status === 'cancelled' ? o.status : null;
    if (!o || !id || !plan || !status) continue;
    out.push({ id, profile: str(o.profile) ?? 'A profile that is gone', plan, status, currentPeriodEnd: str(o.current_period_end), cancelAtPeriodEnd: o.cancel_at_period_end === true, payer: person(o.payer) });
  }
  return out;
}

export function parseCredits(rows: unknown): ReferralCredit[] {
  if (!Array.isArray(rows)) return [];
  const out: ReferralCredit[] = [];
  for (const r of rows) {
    const o = obj(r);
    const id = str(o?.id);
    const status: CreditStatus | null = o?.status === 'payable' || o?.status === 'paid' ? o.status : null;
    const source = o?.source === 'ticket_order' || o?.source === 'table_booking' ? o.source : null;
    const createdAt = str(o?.created_at);
    const amount = num(o?.amount_cents);
    if (!o || !id || !status || !source || !createdAt || amount <= 0) continue;
    const ref = obj(o.referrer);
    out.push({
      id,
      amountCents: amount,
      status,
      source,
      reference: str(o.reference),
      createdAt,
      paidAt: str(o.paid_at),
      referrer: str(ref?.display_name),
      referrerHandle: str(ref?.handle),
      person: person(o.referrer_person),
    });
  }
  return out;
}

export function parseCreators(rows: unknown): CreatorPayout[] {
  if (!Array.isArray(rows)) return [];
  const out: CreatorPayout[] = [];
  for (const r of rows) {
    const o = obj(r);
    const creator = str(o?.creator);
    const cents = num(o?.withdrawable_cents);
    if (!o || !creator || cents <= 0) continue;
    out.push({ creator, name: str(o.name) ?? 'A profile that is gone', tips: num(o.tips), withdrawableCents: cents, person: person(o.person) });
  }
  return out;
}

/** What the credit is for, in a few words. */
export const SOURCE_LABELS: Record<ReferralCredit['source'], string> = { ticket_order: 'their first ticket order', table_booking: 'their first table booking' };

/** Turns what was typed into a money box ("29.99", "299") into cents between [min] and [max], or null. */
export function amountToCents(text: string, min: number, max: number): number | null {
  const m = /^(\d{1,7})(?:\.(\d{1,2}))?$/.exec(text.trim().replace(/,/g, ''));
  if (!m) return null;
  const cents = parseInt(m[1], 10) * 100 + (m[2] ? parseInt(m[2].padEnd(2, '0'), 10) : 0);
  return cents >= min && cents <= max ? cents : null;
}

export interface SettingsForm {
  monthly: string;
  yearly: string;
  priceMonthly: string;
  priceYearly: string;
  subscribedCommission: string;
  referralCredit: string;
  referralDays: string;
  referralCap: string;
  tipCommission: string;
  tipMin: string;
  tipMax: string;
}

export function formFrom(s: BillingSettings): SettingsForm {
  const d = (c: number) => (c / 100).toFixed(2);
  return {
    monthly: d(s.monthlyCents),
    yearly: d(s.yearlyCents),
    priceMonthly: s.priceMonthly ?? '',
    priceYearly: s.priceYearly ?? '',
    subscribedCommission: String(s.subscribedCommissionBps / 100),
    referralCredit: d(s.referralCreditCents),
    referralDays: String(s.referralDays),
    referralCap: String(s.referralMonthlyCap),
    tipCommission: String(s.tipCommissionBps / 100),
    tipMin: d(s.tipMinCents),
    tipMax: d(s.tipMaxCents),
  };
}

/** The sentence for what is wrong with these settings, or null. The database checks the same limits. */
export function settingsProblem(f: SettingsForm): string | null {
  if (amountToCents(f.monthly, 100, 1000000) === null) return 'The monthly price must be between 1.00 and 10,000.00.';
  if (amountToCents(f.yearly, 100, 10000000) === null) return 'The yearly price must be between 1.00 and 100,000.00.';
  if (f.priceMonthly.trim() !== '' && !/^price_[A-Za-z0-9]+$/.test(f.priceMonthly.trim())) return 'The monthly Stripe price id looks like price_123.';
  if (f.priceYearly.trim() !== '' && !/^price_[A-Za-z0-9]+$/.test(f.priceYearly.trim())) return 'The yearly Stripe price id looks like price_123.';
  if (percentToBps(f.subscribedCommission) === null) return 'The commission of a subscribed profile must be a percentage between 0 and 50.';
  if (amountToCents(f.referralCredit, 0, 100000) === null) return 'A referral credit must be between 0 and 1,000.00.';
  const days = Number(f.referralDays);
  if (!Number.isInteger(days) || days < 1 || days > 730) return 'A referral counts for 1 to 730 days.';
  const cap = Number(f.referralCap);
  if (!Number.isInteger(cap) || cap < 1 || cap > 10000) return 'The monthly cap must be 1 to 10,000 credits.';
  if (percentToBps(f.tipCommission) === null) return 'The commission on tips must be a percentage between 0 and 50.';
  const min = amountToCents(f.tipMin, 100, 100000);
  if (min === null) return 'The smallest tip must be between 1.00 and 1,000.00.';
  const max = amountToCents(f.tipMax, min, 1000000);
  if (max === null) return 'The biggest tip must be at least the smallest, and at most 10,000.00.';
  return null;
}

export async function fetchBillingSettings(): Promise<BillingSettings> {
  return parseBillingSettings(await call('cms_billing_settings'));
}

export async function saveBillingSettings(f: SettingsForm): Promise<BillingSettings> {
  const problem = settingsProblem(f);
  if (problem) throw new Error(problem);
  return parseBillingSettings(
    await call('cms_billing_settings_set', {
      p_monthly_cents: amountToCents(f.monthly, 100, 1000000),
      p_yearly_cents: amountToCents(f.yearly, 100, 10000000),
      p_price_monthly: f.priceMonthly.trim() === '' ? null : f.priceMonthly.trim(),
      p_price_yearly: f.priceYearly.trim() === '' ? null : f.priceYearly.trim(),
      p_subscribed_commission_bps: percentToBps(f.subscribedCommission),
      p_referral_credit_cents: amountToCents(f.referralCredit, 0, 100000),
      p_referral_days: Number(f.referralDays),
      p_referral_monthly_cap: Number(f.referralCap),
      p_tip_commission_bps: percentToBps(f.tipCommission),
      p_tip_min_cents: amountToCents(f.tipMin, 100, 100000),
      p_tip_max_cents: amountToCents(f.tipMax, 100, 1000000),
    }),
  );
}

export async function fetchSubscriptions(status: SubscriptionStatus | 'all' = 'active'): Promise<Subscription[]> {
  return parseSubscriptions(await call('cms_subscriptions', { p_status: status }));
}

export async function fetchCredits(status: CreditStatus | 'all' = 'payable'): Promise<ReferralCredit[]> {
  return parseCredits(await call('cms_referral_credits', { p_status: status }));
}

export async function markCreditPaid(id: string, reference: string): Promise<void> {
  await call('cms_referral_credit_paid', { p_credit: id, p_reference: reference.trim() });
}

export async function fetchCreators(): Promise<CreatorPayout[]> {
  return parseCreators(await call('cms_creator_payouts'));
}

export async function markCreatorPaid(creator: string, reference: string): Promise<void> {
  await call('cms_creator_payout_paid', { p_creator: creator, p_reference: reference.trim() });
}
