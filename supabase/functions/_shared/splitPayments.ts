// Splitting a table's bill (customer app, M6; database: 20261106100000_split_payments.sql). A friend pays their share on Stripe's hosted page; the money is added to the booking's
// paid amount by the database (split_share_paid), and paid back by Stripe when a split is cancelled, a booking is cancelled or refunded, or the money could not be applied.
//
// Everything here that does not need the network is plain code so it is tested; the Stripe and database clients are passed in.

export interface BeginResult {
  id: string;
  amount_cents: number;
  currency: string;
  booking_id: string;
  venue: string | null;
  booking_date: string | null;
  start_time: string | null;
  host: string | null;
  pending_session: string | null;
}

// The smallest part of the Stripe and database clients used here, so a test can stand in for them.
export interface StripeLike {
  checkout: {
    sessions: {
      create(params: Record<string, unknown>): Promise<{ id: string; url: string | null }>;
      retrieve(id: string): Promise<{ id: string; url?: string | null; status?: string | null; payment_status?: string | null; payment_intent?: string | { id: string } | null; amount_total?: number | null }>;
    };
  };
  refunds: { create(params: Record<string, unknown>, options?: Record<string, unknown>): Promise<{ id: string }> };
}
export interface DbLike {
  rpc(name: string, args?: Record<string, unknown>): PromiseLike<{ data: unknown; error: { message: string; code?: string } | null }>;
}

/** A payment page lives half an hour (Stripe's shortest is 30 minutes). */
export const SESSION_MINUTES = 31;

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** The id of the request or split named in a body, or null. The sentence is what the app shows. */
export function parseId(body: unknown, key: 'share_id' | 'split_id' | 'booking_id'): { ok: true; id: string } | { ok: false; error: string } {
  const value = typeof body === 'object' && body !== null ? (body as Record<string, unknown>)[key] : undefined;
  if (typeof value !== 'string' || !UUID.test(value)) return { ok: false, error: key === 'share_id' ? 'Choose a request to pay.' : key === 'booking_id' ? 'Choose a booking.' : 'Choose a split.' };
  return { ok: true, id: value.toLowerCase() };
}

/** Which Stripe key to use: the live one only when the website's payments mode says live (the same rule as the booking checkout). */
export function pickStripeKey(paymentsMode: string | null | undefined, env: (name: string) => string | undefined): string | undefined {
  return paymentsMode === 'live'
    ? (env('STRIPE_SECRET_KEY_LIVE') ?? env('STRIPE_SECRET_KEY'))
    : (env('STRIPE_SECRET_KEY_TEST') ?? env('test_SK') ?? env('STRIPE_SECRET_KEY'));
}

const isControl = (c: string) => c.charCodeAt(0) < 32 || c.charCodeAt(0) === 127;
const clean = (s: string | null | undefined, max: number) => Array.from(s ?? '', (c) => (isControl(c) ? ' ' : c)).join('').replace(/\s+/g, ' ').trim().slice(0, max);

/** What Stripe's page calls the charge. */
export function productName(b: Pick<BeginResult, 'venue' | 'booking_date' | 'host'>): string {
  const venue = clean(b.venue, 60) || 'a table';
  const night = clean(b.booking_date, 10);
  return night ? `Your share of the table at ${venue} (${night})` : `Your share of the table at ${venue}`;
}

/** The Stripe Checkout session for one share: one line, the share's exact amount, no fee and no tax (those are already in the booking's total), a page that lapses in 31 minutes. */
export function sessionParams(b: BeginResult, email: string, siteUrl: string, nowMs: number): Record<string, unknown> {
  return {
    mode: 'payment',
    customer_email: email,
    line_items: [{ price_data: { currency: b.currency, product_data: { name: productName(b) }, unit_amount: b.amount_cents }, quantity: 1 }],
    adaptive_pricing: { enabled: false },
    metadata: { kind: 'split_share', share_id: b.id },
    payment_intent_data: { metadata: { kind: 'split_share', share_id: b.id }, description: productName(b) },
    expires_at: Math.floor(nowMs / 1000) + SESSION_MINUTES * 60,
    success_url: `${siteUrl}/pay/share-thanks?session_id={CHECKOUT_SESSION_ID}`,
    cancel_url: `${siteUrl}/pay/share-thanks?cancelled=1`,
  };
}

/** The sentence a database refusal carries (the functions raise plain sentences), or null for anything else, which is never shown. */
export function refusalSentence(error: { message: string; code?: string } | null | undefined): string | null {
  if (!error || error.code !== 'P0001') return null;
  const said = (error.message ?? '').trim();
  return said !== '' && said.length <= 300 ? said : null;
}

/** Stripe has taken the money for a share's session: tell the database (it is idempotent), and pay back at once whatever could not be applied. */
export async function fulfillSplitShare(
  db: DbLike,
  stripe: StripeLike | null,
  sessionId: string,
  paymentIntentId: string | null,
  amountCents: number,
): Promise<{ result: string; refundCents: number }> {
  const { data, error } = await db.rpc('split_share_paid', { p_session: sessionId, p_payment_intent: paymentIntentId, p_amount: amountCents });
  if (error) {
    console.error('fulfillSplitShare: split_share_paid failed', sessionId, error.message);
    return { result: 'error', refundCents: 0 };
  }
  const answer = (data ?? {}) as { result?: string; refund_cents?: number };
  const refundCents = typeof answer.refund_cents === 'number' ? answer.refund_cents : 0;
  if (answer.result === 'unknown') console.error('fulfillSplitShare: no share has this session', sessionId);
  if (refundCents > 0 && stripe) await refundDueShares(db, stripe, {});
  return { result: answer.result ?? 'error', refundCents };
}

/**
 * Pays back what the database says is due (all of it, or only one split's). One Stripe refund per share and amount: the idempotency key makes a repeat the same refund, and the
 * database records a refund id once. A failure on one share is logged and the rest go on; it is tried again at the next run.
 */
export async function refundDueShares(db: DbLike, stripe: StripeLike, only: { splitId?: string }): Promise<{ refunded: number; failed: number }> {
  const { data, error } = await db.rpc('split_refunds_due');
  if (error) {
    console.error('refundDueShares: split_refunds_due failed', error.message);
    return { refunded: 0, failed: 0 };
  }
  const rows = (Array.isArray(data) ? data : []) as { share_id: string; split_id: string; stripe_payment_intent_id: string; cents: number }[];
  let refunded = 0;
  let failed = 0;
  for (const row of rows) {
    if (only.splitId && row.split_id !== only.splitId) continue;
    if (!row.share_id || !row.stripe_payment_intent_id || !Number.isInteger(row.cents) || row.cents <= 0) continue;
    try {
      const refund = await stripe.refunds.create(
        { payment_intent: row.stripe_payment_intent_id, amount: row.cents, metadata: { kind: 'split_share', share_id: row.share_id } },
        { idempotencyKey: `split-share-${row.share_id}-${row.cents}` },
      );
      const recorded = await db.rpc('split_share_refunded', { p_share: row.share_id, p_refund_id: refund.id, p_cents: row.cents });
      if (recorded.error) {
        console.error('refundDueShares: split_share_refunded failed', row.share_id, recorded.error.message);
        failed++;
      } else {
        refunded++;
      }
    } catch (err) {
      console.error('refundDueShares: Stripe refused the refund', row.share_id, (err as { code?: string })?.code ?? 'no code');
      failed++;
    }
  }
  return { refunded, failed };
}
