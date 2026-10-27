// Subscriptions and tips (customer app, M9; database: 20261109100000_billing_referrals_earnings.sql). A subscription is Stripe Billing on Stripe's hosted page; a tip is a one-off payment on
// the same kind of page. The database writes what Stripe says (sub_apply and tip_paid set a state, so hearing a message twice changes nothing).
//
// What does not need the network is plain code so it is tested; the Stripe and database clients are passed in.
import { refusalSentence, type DbLike } from './splitPayments.ts';

export { refusalSentence, type DbLike };

export interface SubBegin {
  subscription_id: string;
  plan: 'monthly' | 'yearly';
  currency: string;
  amount_cents: number;
  price: string | null;
  customer: string | null;
  profile_name: string | null;
}

export interface TipBegin {
  tip_id: string;
  amount_cents: number;
  currency: string;
  creator_name: string | null;
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** The id named in a body under [key], or the sentence to show. */
export function parseUuid(body: unknown, key: string, sentence: string): { ok: true; id: string } | { ok: false; error: string } {
  const value = typeof body === 'object' && body !== null ? (body as Record<string, unknown>)[key] : undefined;
  return typeof value === 'string' && UUID.test(value) ? { ok: true, id: value.toLowerCase() } : { ok: false, error: sentence };
}

/** `monthly` or `yearly`, or null. */
export function parsePlan(body: unknown): 'monthly' | 'yearly' | null {
  const v = typeof body === 'object' && body !== null ? (body as Record<string, unknown>).plan : undefined;
  return v === 'monthly' || v === 'yearly' ? v : null;
}

/** A whole number of cents, or null. */
export function parseCents(body: unknown, key: string): number | null {
  const v = typeof body === 'object' && body !== null ? (body as Record<string, unknown>)[key] : undefined;
  return typeof v === 'number' && Number.isInteger(v) && v > 0 && v <= 100000000 ? v : null;
}

/** The note on a tip: text up to 200 characters, or null when there is none. */
export function parseNote(body: unknown): string | null {
  const v = typeof body === 'object' && body !== null ? (body as Record<string, unknown>).message : undefined;
  return typeof v === 'string' && v.trim() !== '' ? v.trim().slice(0, 200) : null;
}

const isControl = (c: string) => c.charCodeAt(0) < 32 || c.charCodeAt(0) === 127;
const clean = (s: string | null | undefined, max: number) => Array.from(s ?? '', (c) => (isControl(c) ? ' ' : c)).join('').replace(/\s+/g, ' ').trim().slice(0, max);

/** What Stripe's page calls a subscription. */
export function subscriptionName(b: Pick<SubBegin, 'plan' | 'profile_name'>): string {
  return `BottlesUp ${b.plan === 'monthly' ? 'monthly' : 'yearly'} subscription for ${clean(b.profile_name, 60) || 'your profile'}`;
}

/**
 * The Stripe Checkout session for a subscription: one recurring line at the price the website set (a Stripe price id when the CMS has one, otherwise the amount with its interval),
 * the subscription's own id on both the session and the subscription so Stripe's later messages can be matched. An existing Stripe customer is reused.
 */
export function subscriptionSessionParams(b: SubBegin, email: string, siteUrl: string): Record<string, unknown> {
  const meta = { kind: 'subscription', subscription_id: b.subscription_id };
  const line = b.price
    ? { price: b.price, quantity: 1 }
    : { price_data: { currency: b.currency, product_data: { name: subscriptionName(b) }, unit_amount: b.amount_cents, recurring: { interval: b.plan === 'monthly' ? 'month' : 'year' } }, quantity: 1 };
  return {
    mode: 'subscription',
    ...(b.customer ? { customer: b.customer } : { customer_email: email }),
    line_items: [line],
    metadata: meta,
    subscription_data: { metadata: meta },
    success_url: `${siteUrl}/pay/subscription-thanks?session_id={CHECKOUT_SESSION_ID}`,
    cancel_url: `${siteUrl}/pay/subscription-thanks?cancelled=1`,
  };
}

/** A tip's page lives half an hour (Stripe's shortest is 30 minutes). */
export const TIP_SESSION_MINUTES = 31;

export function tipName(b: Pick<TipBegin, 'creator_name'>): string {
  return `Tip for ${clean(b.creator_name, 60) || 'a creator'}`;
}

/** The Stripe Checkout session for one tip: exactly the amount asked for, no fee and no tax on top. */
export function tipSessionParams(b: TipBegin, email: string, siteUrl: string, nowMs: number): Record<string, unknown> {
  return {
    mode: 'payment',
    customer_email: email,
    line_items: [{ price_data: { currency: b.currency, product_data: { name: tipName(b) }, unit_amount: b.amount_cents }, quantity: 1 }],
    adaptive_pricing: { enabled: false },
    metadata: { kind: 'tip', tip_id: b.tip_id },
    payment_intent_data: { metadata: { kind: 'tip', tip_id: b.tip_id }, description: tipName(b) },
    expires_at: Math.floor(nowMs / 1000) + TIP_SESSION_MINUTES * 60,
    success_url: `${siteUrl}/pay/tip-thanks?session_id={CHECKOUT_SESSION_ID}`,
    cancel_url: `${siteUrl}/pay/tip-thanks?cancelled=1`,
  };
}

export interface StripeSubscriptionLike {
  id: string;
  status: string;
  customer?: string | { id: string } | null;
  current_period_end?: number | null;
  cancel_at_period_end?: boolean | null;
  metadata?: Record<string, string> | null;
}

/** Tell the database what Stripe says about a subscription. Safe to repeat. */
export async function applySubscription(db: DbLike, sub: StripeSubscriptionLike, fallbackSubscriptionId?: string | null): Promise<{ result: string }> {
  const customer = typeof sub.customer === 'string' ? sub.customer : (sub.customer?.id ?? null);
  const end = typeof sub.current_period_end === 'number' ? new Date(sub.current_period_end * 1000).toISOString() : null;
  const { data, error } = await db.rpc('sub_apply', {
    p_stripe_subscription: sub.id,
    p_customer: customer,
    p_status: sub.status,
    p_period_end: end,
    p_cancel_at_end: sub.cancel_at_period_end === true,
    p_sub: sub.metadata?.subscription_id ?? fallbackSubscriptionId ?? null,
  });
  if (error) {
    console.error('applySubscription: sub_apply failed', sub.id, error.message);
    return { result: 'error' };
  }
  const answer = (data ?? {}) as { result?: string };
  if (answer.result === 'unknown') console.error('applySubscription: no subscription of ours matches', sub.id);
  return { result: answer.result ?? 'error' };
}

/** A subscription's Checkout page was completed: ask Stripe for the subscription it made, and write it. */
export async function fulfillSubscriptionCheckout(
  db: DbLike,
  stripe: { subscriptions: { retrieve(id: string): Promise<StripeSubscriptionLike> } },
  session: { id: string; subscription?: string | { id: string } | null; metadata?: Record<string, string> | null },
): Promise<{ result: string }> {
  const id = typeof session.subscription === 'string' ? session.subscription : session.subscription?.id;
  if (!id) {
    console.error('fulfillSubscriptionCheckout: the session has no subscription', session.id);
    return { result: 'error' };
  }
  try {
    const sub = await stripe.subscriptions.retrieve(id);
    return await applySubscription(db, sub, session.metadata?.subscription_id ?? null);
  } catch (err) {
    console.error('fulfillSubscriptionCheckout: Stripe would not give the subscription', id, (err as { code?: string })?.code ?? 'no code');
    return { result: 'error' };
  }
}

/** Stripe has taken a tip: tell the database (idempotent). */
export async function fulfillTip(db: DbLike, sessionId: string, paymentIntentId: string | null, amountCents: number): Promise<{ result: string }> {
  const { data, error } = await db.rpc('tip_paid', { p_session: sessionId, p_payment_intent: paymentIntentId, p_amount: amountCents });
  if (error) {
    console.error('fulfillTip: tip_paid failed', sessionId, error.message);
    return { result: 'error' };
  }
  const answer = (data ?? {}) as { result?: string };
  if (answer.result === 'unknown') console.error('fulfillTip: no tip has this session', sessionId);
  return { result: answer.result ?? 'error' };
}
