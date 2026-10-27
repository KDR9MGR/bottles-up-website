// Hiring professionals (customer app, M7; database: 20261107100000_service_marketplace.sql). The customer pays the deposit and the balance on Stripe's hosted page; the money is counted
// against the booking by the database (pro_payment_paid) and paid back through Stripe when a booking is cancelled, a dispute is decided for the customer, or a payment could not be used.
//
// What does not need the network is plain code so it is tested; the Stripe and database clients are passed in (the same small shapes as splitting a bill).
import { refusalSentence, type DbLike, type StripeLike } from './splitPayments.ts';

export { refusalSentence, type DbLike, type StripeLike };

export interface ProBegin {
  payment_id: string;
  kind: 'deposit' | 'balance' | 'full';
  amount_cents: number;
  currency: string;
  title: string | null;
  event_date: string | null;
  provider: string | null;
  pending_session: string | null;
}

/** A payment page lives half an hour (Stripe's shortest is 30 minutes). */
export const PRO_SESSION_MINUTES = 31;

const clean = (s: string | null | undefined, max: number) => Array.from(s ?? '', (c) => (c.charCodeAt(0) < 32 || c.charCodeAt(0) === 127 ? ' ' : c)).join('').replace(/\s+/g, ' ').trim().slice(0, max);

/** What Stripe's page calls the charge. */
export function proProductName(b: Pick<ProBegin, 'kind' | 'title' | 'event_date' | 'provider'>): string {
  const what = b.kind === 'deposit' ? 'Deposit' : b.kind === 'balance' ? 'Balance' : 'Payment';
  const title = clean(b.title, 60) || clean(b.provider, 60) || 'a booking';
  const day = clean(b.event_date, 10);
  return day ? `${what} for ${title} (${day})` : `${what} for ${title}`;
}

/** The Stripe Checkout session for one payment: one line, exactly the amount the database asked for, no fee and no tax on top, a page that lapses in 31 minutes. */
export function proSessionParams(b: ProBegin, email: string, siteUrl: string, nowMs: number): Record<string, unknown> {
  return {
    mode: 'payment',
    customer_email: email,
    line_items: [{ price_data: { currency: b.currency, product_data: { name: proProductName(b) }, unit_amount: b.amount_cents }, quantity: 1 }],
    adaptive_pricing: { enabled: false },
    metadata: { kind: 'pro_payment', payment_id: b.payment_id },
    payment_intent_data: { metadata: { kind: 'pro_payment', payment_id: b.payment_id }, description: proProductName(b) },
    expires_at: Math.floor(nowMs / 1000) + PRO_SESSION_MINUTES * 60,
    success_url: `${siteUrl}/pay/booking-thanks?session_id={CHECKOUT_SESSION_ID}`,
    cancel_url: `${siteUrl}/pay/booking-thanks?cancelled=1`,
  };
}

/** Stripe has taken the money for a booking's session: tell the database (idempotent), and pay back at once whatever could not be used. */
export async function fulfillProPayment(
  db: DbLike,
  stripe: StripeLike | null,
  sessionId: string,
  paymentIntentId: string | null,
  amountCents: number,
): Promise<{ result: string; refundCents: number }> {
  const { data, error } = await db.rpc('pro_payment_paid', { p_session: sessionId, p_payment_intent: paymentIntentId, p_amount: amountCents });
  if (error) {
    console.error('fulfillProPayment: pro_payment_paid failed', sessionId, error.message);
    return { result: 'error', refundCents: 0 };
  }
  const answer = (data ?? {}) as { result?: string; refund_cents?: number };
  const refundCents = typeof answer.refund_cents === 'number' ? answer.refund_cents : 0;
  if (answer.result === 'unknown') console.error('fulfillProPayment: no payment has this session', sessionId);
  if (refundCents > 0 && stripe) await refundDuePayments(db, stripe, {});
  return { result: answer.result ?? 'error', refundCents };
}

/**
 * Pays back what the database says is due (all of it, or only one booking's). One Stripe refund per payment and amount: the idempotency key makes a repeat the same refund, and the
 * database records a refund id once. A failure on one payment is logged and the rest go on; it is tried again at the next run.
 */
export async function refundDuePayments(db: DbLike, stripe: StripeLike, only: { bookingId?: string }): Promise<{ refunded: number; failed: number }> {
  const { data, error } = await db.rpc('pro_refunds_due');
  if (error) {
    console.error('refundDuePayments: pro_refunds_due failed', error.message);
    return { refunded: 0, failed: 0 };
  }
  const rows = (Array.isArray(data) ? data : []) as { payment_id: string; booking_id: string; stripe_payment_intent_id: string; cents: number }[];
  let refunded = 0;
  let failed = 0;
  for (const row of rows) {
    if (only.bookingId && row.booking_id !== only.bookingId) continue;
    if (!row.payment_id || !row.stripe_payment_intent_id || !Number.isInteger(row.cents) || row.cents <= 0) continue;
    try {
      const refund = await stripe.refunds.create(
        { payment_intent: row.stripe_payment_intent_id, amount: row.cents, metadata: { kind: 'pro_payment', payment_id: row.payment_id } },
        { idempotencyKey: `pro-payment-${row.payment_id}-${row.cents}` },
      );
      const recorded = await db.rpc('pro_payment_refunded', { p_payment: row.payment_id, p_refund_id: refund.id, p_cents: row.cents });
      if (recorded.error) {
        console.error('refundDuePayments: pro_payment_refunded failed', row.payment_id, recorded.error.message);
        failed++;
      } else {
        refunded++;
      }
    } catch (err) {
      console.error('refundDuePayments: Stripe refused the refund', row.payment_id, (err as { code?: string })?.code ?? 'no code');
      failed++;
    }
  }
  return { refunded, failed };
}
