import { readFileSync } from 'node:fs';
import { describe, expect, it, vi } from 'vitest';

vi.mock('npm:@supabase/supabase-js@2', () => ({ createClient: vi.fn() }));
import { reserveTableBooking, type TableReservation } from '../../supabase/functions/_shared/reserveTableBooking.ts';

// Every figure has its own value, so a swapped argument shows.
const reservation: TableReservation = {
  venueId: 'venue-1',
  tableTypeId: 'type-1',
  slotId: 'slot-1',
  arrivalDate: '2026-11-14',
  customerName: 'Ann First',
  customerEmail: 'ann@example.com',
  customerPhone: '+1 555 0100',
  guests: 3,
  hours: 2,
  depositCents: 10000,
  bottleSubtotalCents: 25000,
  taxCents: 4550,
  bottlesUpFeeCents: 1000,
  amountTotalCents: 40550,
  bottlePaymentChoice: 'pay_at_club',
  currency: 'cad',
  promoCodeId: 'promo-1',
  discountCents: 500,
  signText: 'Happy Birthday',
};

type Answer = { data: unknown; error: unknown };

// A client that answers rpc() with `rpcResult` and, for the fallback, records the row it is asked to insert and answers with `insertResult`.
function client(rpcResult: Answer, insertResult: Answer = { data: { id: 'booking-from-insert' }, error: null }) {
  const calls: { rpc: { name: string; args: Record<string, unknown> }[]; from: string[]; inserted: Record<string, unknown>[] } = { rpc: [], from: [], inserted: [] };
  const fake: any = {
    rpc: (name: string, args: Record<string, unknown>) => {
      calls.rpc.push({ name, args });
      return Promise.resolve(rpcResult);
    },
    from: (table: string) => {
      calls.from.push(table);
      return {
        insert: (row: Record<string, unknown>) => {
          calls.inserted.push(row);
          return { select: () => ({ single: () => Promise.resolve(insertResult) }) };
        },
      };
    },
  };
  return { fake, calls };
}

const missing = { code: 'PGRST202', message: 'Could not find the function public.site_reserve_table_booking' };

describe('reserveTableBooking: the table is taken in one database step', () => {
  it('asks the database with every figure under its own name', async () => {
    const { fake, calls } = client({ data: 'booking-1', error: null });
    await reserveTableBooking(fake, reservation);
    expect(calls.rpc).toEqual([
      {
        name: 'site_reserve_table_booking',
        args: {
          p_venue: 'venue-1',
          p_table_type: 'type-1',
          p_slot: 'slot-1',
          p_arrival: '2026-11-14',
          p_customer_name: 'Ann First',
          p_customer_email: 'ann@example.com',
          p_customer_phone: '+1 555 0100',
          p_guests: 3,
          p_hours: 2,
          p_deposit_cents: 10000,
          p_bottle_subtotal_cents: 25000,
          p_tax_cents: 4550,
          p_fee_cents: 1000,
          p_total_cents: 40550,
          p_bottle_payment_choice: 'pay_at_club',
          p_currency: 'cad',
          p_promo_code_id: 'promo-1',
          p_discount_cents: 500,
          p_sign_text: 'Happy Birthday',
        },
      },
    ]);
  });

  it('returns the booking the database made, and does not insert anything itself', async () => {
    const { fake, calls } = client({ data: 'booking-1', error: null });
    expect(await reserveTableBooking(fake, reservation)).toEqual({ kind: 'reserved', bookingId: 'booking-1' });
    expect(calls.from).toEqual([]);
  });

  it('says sold out when the database says none is left, and writes nothing', async () => {
    const { fake, calls } = client({ data: null, error: null });
    expect(await reserveTableBooking(fake, reservation)).toEqual({ kind: 'sold_out' });
    expect(calls.from).toEqual([]);
  });

  it('sends nothing for what a guest did not give (no phone, no hours, no promo, no sign)', async () => {
    const { fake, calls } = client({ data: 'booking-1', error: null });
    await reserveTableBooking(fake, { ...reservation, customerPhone: null, hours: null, promoCodeId: null, signText: null });
    const a = calls.rpc[0].args;
    expect([a.p_customer_phone, a.p_hours, a.p_promo_code_id, a.p_sign_text]).toEqual([null, null, null, null]);
  });

  it('refuses an answer that is not a booking: never a table sold on something it could not read', async () => {
    for (const data of [undefined, '', 7, { id: 'x' }, true]) {
      const { fake, calls } = client({ data, error: null });
      await expect(reserveTableBooking(fake, reservation)).rejects.toThrow('not a booking');
      expect(calls.from).toEqual([]);
    }
  });
});

describe('reserveTableBooking: the migration is not applied yet', () => {
  it('falls back to the plain insert of before, with every column', async () => {
    const { fake, calls } = client({ data: null, error: missing });
    expect(await reserveTableBooking(fake, reservation)).toEqual({ kind: 'reserved', bookingId: 'booking-from-insert' });
    expect(calls.from).toEqual(['site_table_bookings']);
    expect(calls.inserted).toEqual([
      {
        venue_id: 'venue-1',
        table_type_id: 'type-1',
        time_slot_id: 'slot-1',
        booking_date: '2026-11-14',
        customer_name: 'Ann First',
        customer_email: 'ann@example.com',
        customer_phone: '+1 555 0100',
        guest_count: 3,
        hours: 2,
        deposit_cents: 10000,
        bottle_subtotal_cents: 25000,
        tax_cents: 4550,
        bottlesup_fee_cents: 1000,
        amount_total_cents: 40550,
        bottle_payment_choice: 'pay_at_club',
        currency: 'cad',
        status: 'pending',
        promo_code_id: 'promo-1',
        discount_cents: 500,
        bottle_sign_text: 'Happy Birthday',
      },
    ]);
  });

  it('also when Postgres itself says the function does not exist', async () => {
    const { fake, calls } = client({ data: null, error: { code: '42883', message: 'function public.site_reserve_table_booking(...) does not exist' } });
    expect(await reserveTableBooking(fake, reservation)).toEqual({ kind: 'reserved', bookingId: 'booking-from-insert' });
    expect(calls.inserted).toHaveLength(1);
  });

  it('fails when even the plain insert fails', async () => {
    const { fake } = client({ data: null, error: missing }, { data: null, error: { message: 'insert failed' } });
    await expect(reserveTableBooking(fake, reservation)).rejects.toThrow('Could not start the booking: insert failed');
  });

  it('fails when the plain insert gives no row back', async () => {
    const { fake } = client({ data: null, error: missing }, { data: null, error: null });
    await expect(reserveTableBooking(fake, reservation)).rejects.toThrow('Could not start the booking: no row came back');
  });
});

describe('reserveTableBooking: any OTHER failure is a failure, never a sale', () => {
  it.each([
    [{ code: '42501', message: 'permission denied for function site_reserve_table_booking' }, 'permission denied'],
    [{ message: 'fetch failed' }, 'fetch failed'],
    [{ code: 'P0001', message: 'table not found' }, 'table not found'],
    [{ code: '57014', message: 'canceling statement due to statement timeout' }, 'statement timeout'],
  ])('%j throws and does not fall back to the unlocked insert', async (error, text) => {
    const { fake, calls } = client({ data: null, error });
    await expect(reserveTableBooking(fake, reservation)).rejects.toThrow(`Could not reserve the table: ${error.message}`);
    expect(error.message).toContain(text);
    expect(calls.from).toEqual([]);
    expect(calls.inserted).toEqual([]);
  });
});

describe('the checkout function takes the table through it', () => {
  const source = readFileSync(new URL('../../supabase/functions/create-table-booking-checkout/index.ts', import.meta.url), 'utf8');

  it('calls reserveTableBooking and no longer inserts a booking on its own', () => {
    expect(source).toMatch(/import \{ reserveTableBooking \} from '\.\.\/_shared\/reserveTableBooking\.ts'/);
    expect(source).toMatch(/await reserveTableBooking\(supabase,/);
    expect(source).not.toMatch(/\.from\('site_table_bookings'\)\s*\.insert\(/);
  });

  it('tells a guest who lost the race the same thing the early check does', () => {
    const answers = source.match(/No tables of this type left for that date and time/g) ?? [];
    expect(answers.length).toBe(2); // the early check and the deciding one
    expect(source).toMatch(/reserved\.kind === 'sold_out'[\s\S]{0,120}409/);
  });
});
