import { beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';
import Stripe from 'stripe';

// The webhook calls these three; we only care that it routes to the right one
// with the right arguments. What they do is covered in fulfillment.test.ts.
vi.mock('../../supabase/functions/_shared/fulfillment.ts', () => ({
  fulfillTicketOrder: vi.fn(async () => {}),
  fulfillTableBooking: vi.fn(async () => {}),
  fulfillBottleAddon: vi.fn(async () => {}),
}));
import * as fulfillment from '../../supabase/functions/_shared/fulfillment.ts';

// A friend's share of a table's bill goes to its own function (tested in splitPayments.test.ts).
vi.mock('../../supabase/functions/_shared/splitPayments.ts', () => ({
  fulfillSplitShare: vi.fn(async () => ({ result: 'applied', refundCents: 0 })),
}));
import * as splitPayments from '../../supabase/functions/_shared/splitPayments.ts';

const TEST_SECRET = 'whsec_test_secret';
const LIVE_SECRET = 'whsec_live_secret';

let env: Record<string, string | undefined> = {};
let handler: (req: Request) => Promise<Response>;
const stripeForSigning = new Stripe('sk_test_unused');

// The edge function registers itself with Deno.serve() at import time, so we
// provide a fake Deno that captures the handler and serves env vars.
beforeAll(async () => {
  (globalThis as any).Deno = {
    serve: (h: (req: Request) => Promise<Response>) => { handler = h; },
    env: { get: (k: string) => env[k] },
  };
  await import('../../supabase/functions/site-stripe-webhook/index.ts');
});

beforeEach(() => {
  vi.clearAllMocks();
  vi.spyOn(console, 'error').mockImplementation(() => {});
  env = {
    STRIPE_SECRET_KEY: 'sk_test_x',
    STRIPE_WEBHOOK_SECRET_TEST: TEST_SECRET,
    SUPABASE_URL: 'http://db.test',
    SUPABASE_SERVICE_ROLE_KEY: 'service-key',
  };
});

function sessionEvent(session: Record<string, unknown>, type = 'checkout.session.completed') {
  return JSON.stringify({ id: 'evt_1', object: 'event', type, data: { object: { id: 'cs_1', object: 'checkout.session', ...session } } });
}
function signedRequest(payload: string, secret = TEST_SECRET, opts: { method?: string; header?: string | null } = {}) {
  const header = opts.header === undefined ? stripeForSigning.webhooks.generateTestHeaderString({ payload, secret }) : opts.header;
  return new Request('http://localhost/webhook', {
    method: opts.method ?? 'POST',
    body: opts.method === 'GET' ? undefined : payload,
    headers: header ? { 'stripe-signature': header } : {},
  });
}
const none = () => {
  expect(fulfillment.fulfillTicketOrder).not.toHaveBeenCalled();
  expect(fulfillment.fulfillTableBooking).not.toHaveBeenCalled();
  expect(fulfillment.fulfillBottleAddon).not.toHaveBeenCalled();
};

describe('site-stripe-webhook: request validation', () => {
  it('rejects anything but POST', async () => {
    const res = await handler(signedRequest('{}', TEST_SECRET, { method: 'GET' }));
    expect(res.status).toBe(405);
    none();
  });

  it('fails loudly (500) when no Stripe key is configured, so Stripe retries', async () => {
    env = { STRIPE_WEBHOOK_SECRET_TEST: TEST_SECRET };
    const res = await handler(signedRequest(sessionEvent({ metadata: { order_id: 'o1' } })));
    expect(res.status).toBe(500);
    none();
  });

  it('rejects a request with no signature header', async () => {
    const res = await handler(signedRequest(sessionEvent({ metadata: { order_id: 'o1' } }), TEST_SECRET, { header: null }));
    expect(res.status).toBe(400);
    none();
  });

  it('rejects a signature made with the wrong secret', async () => {
    const res = await handler(signedRequest(sessionEvent({ metadata: { order_id: 'o1' } }), 'whsec_attacker'));
    expect(res.status).toBe(400);
    none();
  });

  it('rejects a payload that was changed after signing', async () => {
    const original = sessionEvent({ metadata: { order_id: 'o1' } });
    const header = stripeForSigning.webhooks.generateTestHeaderString({ payload: original, secret: TEST_SECRET });
    const tampered = sessionEvent({ metadata: { order_id: 'SOMEONE-ELSES-ORDER' } });
    const res = await handler(signedRequest(tampered, TEST_SECRET, { header }));
    expect(res.status).toBe(400);
    none();
  });

  it('accepts a signature made with any configured secret (test OR live)', async () => {
    env.STRIPE_WEBHOOK_SECRET_LIVE = LIVE_SECRET;
    const res = await handler(signedRequest(sessionEvent({ metadata: { order_id: 'o1' } }), LIVE_SECRET));
    expect(res.status).toBe(200);
    expect(fulfillment.fulfillTicketOrder).toHaveBeenCalledTimes(1);
  });

  it('rejects everything when no webhook secret is configured at all', async () => {
    delete env.STRIPE_WEBHOOK_SECRET_TEST;
    const res = await handler(signedRequest(sessionEvent({ metadata: { order_id: 'o1' } })));
    expect(res.status).toBe(400);
    none();
  });
});

describe('site-stripe-webhook: routing a completed checkout', () => {
  it('ticket order -> fulfillTicketOrder(client, orderId, paymentIntentId)', async () => {
    const res = await handler(signedRequest(sessionEvent({ payment_intent: 'pi_123', metadata: { order_id: 'ord_1' } })));
    expect(res.status).toBe(200);
    expect(fulfillment.fulfillTicketOrder).toHaveBeenCalledWith(expect.objectContaining({ __stubClient: true }), 'ord_1', 'pi_123');
    expect(fulfillment.fulfillTableBooking).not.toHaveBeenCalled();
  });

  it('table booking -> fulfillTableBooking(client, bookingId, paymentIntentId)', async () => {
    const res = await handler(signedRequest(sessionEvent({ payment_intent: 'pi_9', metadata: { booking_id: 'bk_1' } })));
    expect(res.status).toBe(200);
    expect(fulfillment.fulfillTableBooking).toHaveBeenCalledWith(expect.objectContaining({ __stubClient: true }), 'bk_1', 'pi_9');
    expect(fulfillment.fulfillTicketOrder).not.toHaveBeenCalled();
  });

  it('bottle add-on -> fulfillBottleAddon with the session id and the amount Stripe charged, NOT the table path', async () => {
    const res = await handler(
      signedRequest(sessionEvent({ id: 'cs_addon', amount_total: 12500, payment_intent: 'pi_x', metadata: { booking_id: 'bk_1', kind: 'bottle_addon' } })),
    );
    expect(res.status).toBe(200);
    expect(fulfillment.fulfillBottleAddon).toHaveBeenCalledWith(expect.objectContaining({ __stubClient: true }), 'bk_1', 'cs_addon', 12500);
    expect(fulfillment.fulfillTableBooking).not.toHaveBeenCalled();
  });

  it('a booking id wins over an order id if both are present', async () => {
    await handler(signedRequest(sessionEvent({ metadata: { order_id: 'ord_1', booking_id: 'bk_1' } })));
    expect(fulfillment.fulfillTableBooking).toHaveBeenCalledTimes(1);
    expect(fulfillment.fulfillTicketOrder).not.toHaveBeenCalled();
  });

  it('reads the payment intent id whether Stripe sends a string or an expanded object', async () => {
    await handler(signedRequest(sessionEvent({ payment_intent: { id: 'pi_obj' }, metadata: { order_id: 'o1' } })));
    expect(fulfillment.fulfillTicketOrder).toHaveBeenLastCalledWith(expect.anything(), 'o1', 'pi_obj');
    await handler(signedRequest(sessionEvent({ payment_intent: null, metadata: { order_id: 'o2' } })));
    expect(fulfillment.fulfillTicketOrder).toHaveBeenLastCalledWith(expect.anything(), 'o2', null);
  });

  it('a session this site did not create (no metadata) is acknowledged and ignored, so Stripe does not retry forever', async () => {
    const res = await handler(signedRequest(sessionEvent({ metadata: {} })));
    expect(res.status).toBe(200);
    none();
    const res2 = await handler(signedRequest(sessionEvent({})));
    expect(res2.status).toBe(200);
    none();
  });

  it('other event types are acknowledged and ignored', async () => {
    const res = await handler(signedRequest(sessionEvent({ metadata: { order_id: 'o1' } }, 'payment_intent.succeeded')));
    expect(res.status).toBe(200);
    none();
  });

  it('does NOT swallow a fulfillment failure: the handler rejects so the platform answers 5xx and Stripe retries', async () => {
    (fulfillment.fulfillTicketOrder as any).mockRejectedValueOnce(new Error('db down'));
    await expect(handler(signedRequest(sessionEvent({ metadata: { order_id: 'o1' } })))).rejects.toThrow('db down');
  });
});

describe('site-stripe-webhook: a friend\'s share of a table', () => {
  it('goes to fulfillSplitShare with the session, the payment and what Stripe took, and to nothing else', async () => {
    const res = await handler(signedRequest(sessionEvent({ id: 'cs_share', payment_intent: 'pi_share', amount_total: 2500, metadata: { kind: 'split_share', share_id: 'sh_1' } })));
    expect(res.status).toBe(200);
    expect(splitPayments.fulfillSplitShare).toHaveBeenCalledTimes(1);
    const args = (splitPayments.fulfillSplitShare as any).mock.calls[0];
    expect(args[2]).toBe('cs_share');
    expect(args[3]).toBe('pi_share');
    expect(args[4]).toBe(2500);
    none();
  });

  it('is never mistaken for a booking or an order, even if it carries their ids', async () => {
    await handler(signedRequest(sessionEvent({ id: 'cs_share2', payment_intent: 'pi_2', amount_total: 100, metadata: { kind: 'split_share', booking_id: 'b1', order_id: 'o1' } })));
    expect(splitPayments.fulfillSplitShare).toHaveBeenCalledTimes(1);
    none();
  });

  it('a payment intent that is an object is read, and no intent at all is passed as null', async () => {
    await handler(signedRequest(sessionEvent({ id: 'cs_s3', payment_intent: { id: 'pi_obj' }, amount_total: 300, metadata: { kind: 'split_share' } })));
    await handler(signedRequest(sessionEvent({ id: 'cs_s4', amount_total: 300, metadata: { kind: 'split_share' } })));
    const calls = (splitPayments.fulfillSplitShare as any).mock.calls;
    expect(calls[0][3]).toBe('pi_obj');
    expect(calls[1][3]).toBeNull();
  });

  it('no amount is passed as nothing, which the database refuses rather than guesses', async () => {
    await handler(signedRequest(sessionEvent({ id: 'cs_s5', metadata: { kind: 'split_share' } })));
    expect((splitPayments.fulfillSplitShare as any).mock.calls[0][4]).toBe(0);
  });

  it('an ordinary table booking still goes where it went', async () => {
    await handler(signedRequest(sessionEvent({ payment_intent: 'pi_b', metadata: { booking_id: 'bk_1' } })));
    expect(fulfillment.fulfillTableBooking).toHaveBeenCalledTimes(1);
    expect(splitPayments.fulfillSplitShare).not.toHaveBeenCalled();
  });
});
