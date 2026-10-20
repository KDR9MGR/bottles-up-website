import { describe, expect, it, vi } from 'vitest';

vi.mock('npm:@supabase/supabase-js@2', () => ({ createClient: vi.fn() }));
import { isMissingFunction, tablesTaken } from '../../supabase/functions/_shared/tableCapacity.ts';

const query = { typeId: 'type-1', slotId: 'slot-1', arrivalDate: '2026-10-24' };

// A client that answers rpc() with `rpcResult` and, for the fallback, counts paid rows with the filters it is given.
function client(rpcResult: { data: unknown; error: unknown }, fallback: { count: number | null; error?: unknown } = { count: 0 }) {
  const calls: { rpc: { name: string; args: unknown }[]; filters: [string, unknown][] } = { rpc: [], filters: [] };
  const chain: any = {
    select: () => chain,
    eq: (col: string, val: unknown) => { calls.filters.push([col, val]); return chain; },
    then: (resolve: (v: unknown) => unknown) => Promise.resolve({ count: fallback.count, error: fallback.error ?? null }).then(resolve),
  };
  const fake: any = {
    rpc: (name: string, args: unknown) => { calls.rpc.push({ name, args }); return Promise.resolve(rpcResult); },
    from: () => chain,
  };
  return { fake, calls };
}

describe('isMissingFunction: the migration is not applied yet', () => {
  it('recognises the three ways the database says so', () => {
    expect(isMissingFunction({ code: 'PGRST202', message: 'x' })).toBe(true);
    expect(isMissingFunction({ code: '42883', message: 'x' })).toBe(true);
    expect(isMissingFunction({ code: 'PGRST202', message: 'Could not find the function public.site_table_taken_count' })).toBe(true);
    expect(isMissingFunction({ message: 'function public.site_table_taken_count(uuid) does not exist' })).toBe(true);
  });
  it('and nothing else: a dropped connection or a permission error is a real failure', () => {
    expect(isMissingFunction(null)).toBe(false);
    expect(isMissingFunction(undefined)).toBe(false);
    expect(isMissingFunction({ code: '42501', message: 'permission denied for function site_table_taken_count' })).toBe(false);
    expect(isMissingFunction({ message: 'fetch failed' })).toBe(false);
  });
});

describe('tablesTaken: how many tables of a type are taken for an arrival time', () => {
  it('asks the database, with the guest\'s e-mail so their own unfinished checkout does not block them', async () => {
    const { fake, calls } = client({ data: 2, error: null });
    expect(await tablesTaken(fake, { ...query, excludeEmail: 'guest@example.com' })).toBe(2);
    expect(calls.rpc).toEqual([{ name: 'site_table_taken_count', args: { p_type: 'type-1', p_slot: 'slot-1', p_date: '2026-10-24', p_exclude_email: 'guest@example.com' } }]);
    expect(calls.filters).toEqual([]); // the fallback is not touched
  });

  it('sends no e-mail when there is none (a staff walk-in)', async () => {
    const { fake, calls } = client({ data: 0, error: null });
    expect(await tablesTaken(fake, query)).toBe(0);
    expect((calls.rpc[0].args as { p_exclude_email: unknown }).p_exclude_email).toBeNull();
  });

  it('an answer that is not a whole number is refused, never read as "free"', async () => {
    for (const data of [null, 'two', -1, 1.5, undefined]) {
      await expect(tablesTaken(client({ data, error: null }).fake, query)).rejects.toThrow('not a count');
    }
  });

  it('a real failure is thrown, so a booking is never sold on an answer that could not be read', async () => {
    const { fake, calls } = client({ data: null, error: { code: '57014', message: 'canceling statement due to statement timeout' } }, { count: 0 });
    await expect(tablesTaken(fake, query)).rejects.toThrow('Could not check table availability: canceling statement due to statement timeout');
    expect(calls.filters).toEqual([]); // and it did NOT quietly fall back to the old rule
  });

  it('before the migration is applied, the old rule (paid bookings only) still answers, for exactly that table, time and day', async () => {
    const { fake, calls } = client({ data: null, error: { code: 'PGRST202', message: 'Could not find the function' } }, { count: 3 });
    expect(await tablesTaken(fake, query)).toBe(3);
    expect(calls.filters).toEqual([['table_type_id', 'type-1'], ['time_slot_id', 'slot-1'], ['booking_date', '2026-10-24'], ['status', 'paid']]);
  });

  it('...and a failure of that fallback is thrown too', async () => {
    const { fake } = client({ data: null, error: { code: '42883', message: 'x' } }, { count: null, error: { message: 'connection lost' } });
    await expect(tablesTaken(fake, query)).rejects.toThrow('Could not check table availability: connection lost');
  });

  it('a missing count in the fallback is zero', async () => {
    const { fake } = client({ data: null, error: { code: '42883', message: 'x' } }, { count: null });
    expect(await tablesTaken(fake, query)).toBe(0);
  });
});
