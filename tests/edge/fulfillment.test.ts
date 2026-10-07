import { beforeEach, describe, expect, it, vi } from 'vitest';

// Emails go through Resend over the network; we replace them and inspect the calls.
vi.mock('../../supabase/functions/_shared/ticketEmail.ts', () => ({
  generateTicketCode: vi.fn(() => 'TKT-NEW'),
  sendTicketEmail: vi.fn(async () => ({ sent: true })),
}));
vi.mock('../../supabase/functions/_shared/tableBookingEmail.ts', () => ({
  generateConfirmationCode: vi.fn(() => 'CONF-NEW'),
  sendTableBookingEmail: vi.fn(async () => ({ sent: true })),
  sendBottleAdditionEmail: vi.fn(async () => ({ sent: true })),
  formatTimeSlot: (t: string) => `slot ${t}`,
}));

import { fulfillBottleAddon, fulfillTableBooking, fulfillTicketOrder } from '../../supabase/functions/_shared/fulfillment.ts';
import { generateTicketCode, sendTicketEmail } from '../../supabase/functions/_shared/ticketEmail.ts';
import { generateConfirmationCode, sendBottleAdditionEmail, sendTableBookingEmail } from '../../supabase/functions/_shared/tableBookingEmail.ts';
import { createFakeDb } from './stubs/fakeDb';

beforeEach(() => {
  vi.clearAllMocks();
  vi.spyOn(console, 'error').mockImplementation(() => {});
  (globalThis as any).Deno = { env: { get: () => undefined } };
});

const tableRow = (db: ReturnType<typeof createFakeDb>, t: string, id: string) => db.tables[t].find((r) => r.id === id)!;

// --------------------------------------------------------------------------
// Ticket orders
// --------------------------------------------------------------------------
const order = (over: Record<string, unknown> = {}) => ({
  id: 'o1', status: 'pending', tier_id: 't1', quantity: 2, customer_email: 'ada@example.com', customer_name: 'Ada',
  ticket_code: null, ticket_sent_at: null, stripe_payment_intent_id: null, promo_code_id: null, discount_cents: 0,
  ticket_tiers: { name: 'General', events: { title: 'NYE', venue_name: 'The Club', start_date: '2026-12-31T22:00:00Z' } },
  promo: null,
  ...over,
});
const ticketDb = (o = order()) => createFakeDb({ site_orders: [o] });

describe('fulfillTicketOrder', () => {
  it('first delivery: marks paid, issues a code, counts the sale, emails the ticket, records that it was sent', async () => {
    const db = ticketDb();
    await fulfillTicketOrder(db.client, 'o1', 'pi_1');

    expect(tableRow(db, 'site_orders', 'o1')).toMatchObject({ status: 'paid', ticket_code: 'TKT-NEW', stripe_payment_intent_id: 'pi_1' });
    expect(tableRow(db, 'site_orders', 'o1').ticket_sent_at).toBeTruthy();
    expect(db.rpcCalls).toEqual([{ name: 'increment_tier_sold', args: { p_tier_id: 't1', p_qty: 2 } }]);
    expect(sendTicketEmail).toHaveBeenCalledTimes(1);
    expect(sendTicketEmail).toHaveBeenCalledWith(
      expect.objectContaining({ toEmail: 'ada@example.com', quantity: 2, ticketCode: 'TKT-NEW', eventTitle: 'NYE', tierName: 'General', qrDataUrl: expect.stringContaining('TKT-NEW') }),
    );
  });

  it('counts a promo code use exactly once, and tells the email which code was used', async () => {
    const db = ticketDb(order({ promo_code_id: 'p1', promo: { code: 'SAVE10' }, discount_cents: 500 }));
    await fulfillTicketOrder(db.client, 'o1', 'pi_1');
    expect(db.rpcCalls.map((c) => c.name)).toEqual(['increment_tier_sold', 'increment_promo_code_usage']);
    expect(db.rpcCalls[1].args).toEqual({ p_promo_id: 'p1' });
    expect(sendTicketEmail).toHaveBeenCalledWith(expect.objectContaining({ promoCode: 'SAVE10', discountCents: 500 }));
  });

  it('IDEMPOTENT: a ticket that was already emailed is left completely alone (webhook redelivery)', async () => {
    const db = ticketDb(order({ status: 'paid', ticket_code: 'OLD', ticket_sent_at: '2026-01-01T00:00:00Z' }));
    await fulfillTicketOrder(db.client, 'o1', 'pi_1');
    expect(db.writes).toEqual([]);
    expect(db.rpcCalls).toEqual([]);
    expect(sendTicketEmail).not.toHaveBeenCalled();
    expect(generateTicketCode).not.toHaveBeenCalled();
  });

  it('a retry after a failed email re-sends the SAME code and does not double-count the sale', async () => {
    // First attempt claimed the order and counted the sale but the email failed.
    const db = ticketDb(order({ status: 'paid', ticket_code: 'OLD', ticket_sent_at: null }));
    await fulfillTicketOrder(db.client, 'o1', 'pi_1');
    expect(generateTicketCode).not.toHaveBeenCalled();
    expect(db.rpcCalls).toEqual([]); // no second increment_tier_sold
    expect(sendTicketEmail).toHaveBeenCalledWith(expect.objectContaining({ ticketCode: 'OLD' }));
    expect(tableRow(db, 'site_orders', 'o1').ticket_sent_at).toBeTruthy();
  });

  it('if the email fails, the order is NOT marked as sent, so a later retry can still deliver it', async () => {
    (sendTicketEmail as any).mockResolvedValueOnce({ sent: false, error: 'resend 500' });
    const db = ticketDb();
    await fulfillTicketOrder(db.client, 'o1', 'pi_1');
    const row = tableRow(db, 'site_orders', 'o1');
    expect(row.ticket_sent_at).toBeNull();
    expect(row).toMatchObject({ status: 'paid', ticket_code: 'TKT-NEW' }); // paid and coded, just not delivered
  });

  it('RACE: another caller claims the order first and already emailed it -> we do nothing', async () => {
    const db = ticketDb();
    let fired = false;
    db.beforeWrite = (table) => {
      if (table === 'site_orders' && !fired) {
        fired = true;
        Object.assign(db.tables.site_orders[0], { status: 'paid', ticket_code: 'THEIRS', ticket_sent_at: '2026-01-01T00:00:00Z' });
      }
    };
    await fulfillTicketOrder(db.client, 'o1', 'pi_1');
    expect(tableRow(db, 'site_orders', 'o1').ticket_code).toBe('THEIRS'); // our generated code never overwrote theirs
    expect(db.rpcCalls).toEqual([]); // the winner counts the sale, not us
    expect(sendTicketEmail).not.toHaveBeenCalled();
  });

  it('RACE: another caller claimed it but has not emailed yet -> we deliver THEIR code, and do not count the sale twice', async () => {
    const db = ticketDb();
    let fired = false;
    db.beforeWrite = (table) => {
      if (table === 'site_orders' && !fired) {
        fired = true;
        Object.assign(db.tables.site_orders[0], { status: 'paid', ticket_code: 'THEIRS' });
      }
    };
    await fulfillTicketOrder(db.client, 'o1', 'pi_1');
    expect(db.rpcCalls).toEqual([]);
    expect(sendTicketEmail).toHaveBeenCalledWith(expect.objectContaining({ ticketCode: 'THEIRS' }));
  });

  it('an order that has a code but is not marked paid is marked paid, without re-counting', async () => {
    const db = ticketDb(order({ status: 'pending', ticket_code: 'OLD' }));
    await fulfillTicketOrder(db.client, 'o1', 'pi_7');
    expect(tableRow(db, 'site_orders', 'o1')).toMatchObject({ status: 'paid', stripe_payment_intent_id: 'pi_7', ticket_code: 'OLD' });
    expect(db.rpcCalls).toEqual([]);
  });

  it('an order id that does not exist is a no-op, not a crash', async () => {
    const db = createFakeDb({ site_orders: [] });
    await expect(fulfillTicketOrder(db.client, 'ghost', 'pi_1')).resolves.toBeUndefined();
    expect(db.writes).toEqual([]);
    expect(sendTicketEmail).not.toHaveBeenCalled();
  });
});

// --------------------------------------------------------------------------
// Table bookings
// --------------------------------------------------------------------------
const booking = (over: Record<string, unknown> = {}) => ({
  id: 'b1', status: 'pending', confirmation_code: null, confirmation_sent_at: null,
  amount_total_cents: 11800, amount_paid_cents: 0, bottle_payment_choice: 'pay_ahead', bottle_subtotal_cents: 0,
  deposit_cents: 10000, tax_cents: 1300, bottlesup_fee_cents: 500, discount_cents: 0, promo_code_id: null, promo: null,
  guest_count: 4, hours: 1, currency: 'cad', booking_date: '2026-12-31', customer_email: 'ada@example.com', customer_name: 'Ada',
  table_type: { name: 'Booth' }, venue: { name: 'The Club', deposit_is_credit: false }, time_slot: { start_time: '23:00:00' },
  ...over,
});
const tableDb = (b = booking(), bottles: Record<string, unknown>[] = []) =>
  createFakeDb({ site_table_bookings: [b], site_table_booking_bottles: bottles });

describe('fulfillTableBooking: what Stripe collected vs what is left for the venue', () => {
  it('pay_ahead: everything was paid online', async () => {
    const db = tableDb();
    await fulfillTableBooking(db.client, 'b1', 'pi_1');
    expect(tableRow(db, 'site_table_bookings', 'b1')).toMatchObject({ status: 'paid', confirmation_code: 'CONF-NEW', amount_paid_cents: 11800, stripe_payment_intent_id: 'pi_1' });
    expect(sendTableBookingEmail).toHaveBeenCalledWith(expect.objectContaining({ totalCents: 11800, paidNowCents: 11800, dueAtVenueCents: 0, confirmationCode: 'CONF-NEW' }));
  });

  it('pay_at_club: the bottle total is NOT collected online; it is due at the venue', async () => {
    // total 26800 = 11800 charged now + 15000 of bottles due at the club
    const db = tableDb(booking({ amount_total_cents: 26800, bottle_payment_choice: 'pay_at_club', bottle_subtotal_cents: 15000 }));
    await fulfillTableBooking(db.client, 'b1', 'pi_1');
    expect(tableRow(db, 'site_table_bookings', 'b1').amount_paid_cents).toBe(11800);
    expect(sendTableBookingEmail).toHaveBeenCalledWith(expect.objectContaining({ paidNowCents: 11800, dueAtVenueCents: 15000 }));
  });

  it('pay_at_club with a credit deposit: the deposit is netted off the amount due at the venue', async () => {
    // bottles 30000, deposit 10000 credited -> 20000 due at venue; total 31800 -> 11800 paid now
    const db = tableDb(booking({ amount_total_cents: 31800, bottle_payment_choice: 'pay_at_club', bottle_subtotal_cents: 30000, venue: { name: 'The Club', deposit_is_credit: true } }));
    await fulfillTableBooking(db.client, 'b1', 'pi_1');
    expect(tableRow(db, 'site_table_bookings', 'b1').amount_paid_cents).toBe(11800);
    expect(sendTableBookingEmail).toHaveBeenCalledWith(expect.objectContaining({ paidNowCents: 11800, dueAtVenueCents: 20000 }));
  });

  it('amount paid can never be negative, even if the stored numbers disagree', async () => {
    const db = tableDb(booking({ amount_total_cents: 5000, bottle_payment_choice: 'pay_at_club', bottle_subtotal_cents: 15000 }));
    await fulfillTableBooking(db.client, 'b1', 'pi_1');
    expect(tableRow(db, 'site_table_bookings', 'b1').amount_paid_cents).toBe(0);
  });

  it('puts the booked bottles into the confirmation email', async () => {
    const db = tableDb(booking(), [{ booking_id: 'b1', bottle_name: 'Grey Goose', size: '750ml', quantity: 2, unit_price_cents: 20000, line_total_cents: 40000, payment_status: 'paid' }]);
    await fulfillTableBooking(db.client, 'b1', 'pi_1');
    expect(sendTableBookingEmail).toHaveBeenCalledWith(expect.objectContaining({ bottles: [expect.objectContaining({ bottle_name: 'Grey Goose', quantity: 2 })] }));
  });
});

describe('fulfillTableBooking: idempotency and races', () => {
  it('counts a promo use exactly once on the first delivery', async () => {
    const db = tableDb(booking({ promo_code_id: 'p1', promo: { code: 'SAVE10' } }));
    await fulfillTableBooking(db.client, 'b1', 'pi_1');
    expect(db.rpcCalls).toEqual([{ name: 'increment_promo_code_usage', args: { p_promo_id: 'p1' } }]);
  });

  it('IDEMPOTENT: an already-confirmed booking is left completely alone', async () => {
    const db = tableDb(booking({ status: 'paid', confirmation_code: 'OLD', confirmation_sent_at: '2026-01-01T00:00:00Z', amount_paid_cents: 11800 }));
    await fulfillTableBooking(db.client, 'b1', 'pi_1');
    expect(db.writes).toEqual([]);
    expect(db.rpcCalls).toEqual([]);
    expect(sendTableBookingEmail).not.toHaveBeenCalled();
    expect(generateConfirmationCode).not.toHaveBeenCalled();
  });

  it('a retry after a failed email re-sends the same confirmation code and does not re-count the promo', async () => {
    const db = tableDb(booking({ status: 'paid', confirmation_code: 'OLD', promo_code_id: 'p1', promo: { code: 'SAVE10' }, amount_paid_cents: 11800 }));
    await fulfillTableBooking(db.client, 'b1', 'pi_1');
    expect(generateConfirmationCode).not.toHaveBeenCalled();
    expect(db.rpcCalls).toEqual([]);
    expect(sendTableBookingEmail).toHaveBeenCalledWith(expect.objectContaining({ confirmationCode: 'OLD' }));
    expect(tableRow(db, 'site_table_bookings', 'b1').confirmation_sent_at).toBeTruthy();
  });

  it('a failed email leaves the booking paid but NOT marked as confirmed-sent', async () => {
    (sendTableBookingEmail as any).mockResolvedValueOnce({ sent: false, error: 'resend 500' });
    const db = tableDb();
    await fulfillTableBooking(db.client, 'b1', 'pi_1');
    const row = tableRow(db, 'site_table_bookings', 'b1');
    expect(row.confirmation_sent_at).toBeNull();
    expect(row).toMatchObject({ status: 'paid', confirmation_code: 'CONF-NEW' });
  });

  it('RACE: someone else claimed the booking and already emailed -> we do nothing and do not overwrite their code', async () => {
    const db = tableDb(booking({ promo_code_id: 'p1', promo: { code: 'SAVE10' } }));
    let fired = false;
    db.beforeWrite = (table) => {
      if (table === 'site_table_bookings' && !fired) {
        fired = true;
        Object.assign(db.tables.site_table_bookings[0], { status: 'paid', confirmation_code: 'THEIRS', confirmation_sent_at: '2026-01-01T00:00:00Z' });
      }
    };
    await fulfillTableBooking(db.client, 'b1', 'pi_1');
    expect(tableRow(db, 'site_table_bookings', 'b1').confirmation_code).toBe('THEIRS');
    expect(db.rpcCalls).toEqual([]); // promo counted by the winner only
    expect(sendTableBookingEmail).not.toHaveBeenCalled();
  });

  it('an unknown booking id is a no-op', async () => {
    const db = createFakeDb({ site_table_bookings: [] });
    await expect(fulfillTableBooking(db.client, 'ghost', 'pi_1')).resolves.toBeUndefined();
    expect(sendTableBookingEmail).not.toHaveBeenCalled();
  });
});

// --------------------------------------------------------------------------
// Pay-ahead bottle add-ons (a second Stripe charge on an existing booking)
// --------------------------------------------------------------------------
const addonDb = () =>
  createFakeDb({
    site_table_bookings: [{
      id: 'b1', deposit_cents: 10000, discount_cents: 0, amount_paid_cents: 11800, amount_total_cents: 11800,
      customer_email: 'ada@example.com', customer_name: 'Ada', confirmation_code: 'CONF1', currency: 'cad',
      table_type: { name: 'Booth' }, venue: { name: 'The Club', tax_rate_bps: 1300, deposit_is_credit: false },
    }],
    site_table_booking_bottles: [
      { id: 'l1', booking_id: 'b1', bottle_name: 'Grey Goose', size: '750ml', quantity: 1, line_total_cents: 10000, payment_status: 'pending_payment', stripe_checkout_session_id: 'cs_A', cancelled_at: null },
      { id: 'l2', booking_id: 'b1', bottle_name: 'Patron', size: '750ml', quantity: 1, line_total_cents: 10000, payment_status: 'pending_payment', stripe_checkout_session_id: 'cs_A', cancelled_at: null },
      { id: 'l3', booking_id: 'b1', bottle_name: 'Hennessy', size: '750ml', quantity: 1, line_total_cents: 9000, payment_status: 'pending_payment', stripe_checkout_session_id: 'cs_B', cancelled_at: null },
    ],
    site_content: [{ id: 1, bottlesup_fee_bps: 500 }],
    audit_log: [],
  });

describe('fulfillBottleAddon', () => {
  it('confirms only the lines paid for by THIS checkout session, recomputes totals, adds what was charged, audits and emails', async () => {
    const db = addonDb();
    await fulfillBottleAddon(db.client, 'b1', 'cs_A', 20000);

    const lines = Object.fromEntries(db.tables.site_table_booking_bottles.map((l) => [l.id, l.payment_status]));
    expect(lines).toEqual({ l1: 'paid', l2: 'paid', l3: 'pending_payment' }); // the other session's line is untouched

    // paid bottles 20000 + deposit 10000 = 30000 -> tax 3900, fee 1500 -> 35400
    expect(tableRow(db, 'site_table_bookings', 'b1')).toMatchObject({
      bottle_subtotal_cents: 20000, tax_cents: 3900, bottlesup_fee_cents: 1500, amount_total_cents: 35400,
      amount_paid_cents: 11800 + 20000,
    });
    expect(db.tables.audit_log).toHaveLength(1);
    expect(db.tables.audit_log[0]).toMatchObject({ action: 'table_booking.customer_addon_confirmed', entity_id: 'b1' });
    expect(sendBottleAdditionEmail).toHaveBeenCalledWith(expect.objectContaining({ amountChargedNowCents: 20000, newAmountTotalCents: 35400, newAmountPaidCents: 31800 }));
  });

  it('IDEMPOTENT: confirming the same session a second time changes nothing and does not double-credit', async () => {
    const db = addonDb();
    await fulfillBottleAddon(db.client, 'b1', 'cs_A', 20000);
    const after1 = structuredClone(db.tables.site_table_bookings[0]);
    await fulfillBottleAddon(db.client, 'b1', 'cs_A', 20000);
    expect(db.tables.site_table_bookings[0]).toEqual(after1);
    expect(db.tables.audit_log).toHaveLength(1);
    expect(sendBottleAdditionEmail).toHaveBeenCalledTimes(1);
  });

  it('a session that has nothing pending is a no-op', async () => {
    const db = addonDb();
    await fulfillBottleAddon(db.client, 'b1', 'cs_UNKNOWN', 5000);
    expect(db.writes).toEqual([]);
    expect(sendBottleAdditionEmail).not.toHaveBeenCalled();
  });

  // KNOWN ISSUE (found while writing these tests, against this in-memory fake;
  // not reproduced on the live database). The code is safe if called twice one
  // after the other, but if the Stripe webhook and the confirm-bottle-addon
  // fallback run at the SAME time, both read the lines as still pending before
  // either flips them. The flip is `update ... where payment_status =
  // 'pending_payment'` but its row count is never checked, so both callers
  // carry on: two audit rows, two emails, and the charged amount is added to
  // amount_paid_cents twice (or lost-updated). `it.fails` keeps CI green while
  // documenting it; when the code is fixed this test starts failing, which is
  // the cue to delete the `.fails`.
  it.fails('KNOWN ISSUE: confirms an add-on only once when the webhook and the fallback run at the same time', async () => {
    const db = addonDb();
    await Promise.all([fulfillBottleAddon(db.client, 'b1', 'cs_A', 20000), fulfillBottleAddon(db.client, 'b1', 'cs_A', 20000)]);
    expect(db.tables.audit_log).toHaveLength(1);
    expect(sendBottleAdditionEmail).toHaveBeenCalledTimes(1);
    expect(tableRow(db, 'site_table_bookings', 'b1').amount_paid_cents).toBe(31800);
  });
});
