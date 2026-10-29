import { describe, expect, it, vi } from 'vitest';

vi.mock('npm:@supabase/supabase-js@2', () => ({ createClient: vi.fn() }));
import { bookingHeldForReview, bookingIsOversold } from '../../supabase/functions/_shared/oversold.ts';

type Answer = { data: unknown; error: unknown };

function rpcClient(answer: Answer) {
  const calls: { name: string; args: unknown }[] = [];
  const fake: any = { rpc: (name: string, args: unknown) => (calls.push({ name, args }), Promise.resolve(answer)) };
  return { fake, calls };
}

// a client whose from('site_booking_conflicts').select().eq().eq().maybeSingle() answers `answer`, remembering the filters
function tableClient(answer: Answer) {
  const seen: { table: string; filters: [string, unknown][] } = { table: '', filters: [] };
  const chain: any = {
    select: () => chain,
    eq: (col: string, val: unknown) => (seen.filters.push([col, val]), chain),
    maybeSingle: () => Promise.resolve(answer),
  };
  const fake: any = { from: (t: string) => ((seen.table = t), chain) };
  return { fake, seen };
}

describe('bookingIsOversold: after a booking is marked paid, was the table already gone?', () => {
  it('asks the database about that booking and returns its answer', async () => {
    const yes = rpcClient({ data: true, error: null });
    expect(await bookingIsOversold(yes.fake, 'b1')).toBe(true);
    expect(yes.calls).toEqual([{ name: 'site_flag_oversold_booking', args: { p_booking: 'b1' } }]);
    expect(await bookingIsOversold(rpcClient({ data: false, error: null }).fake, 'b1')).toBe(false);
  });

  it('says no while the migration is not applied (no such function), so a deploy before it changes nothing', async () => {
    for (const error of [{ code: 'PGRST202', message: 'x' }, { code: '42883', message: 'x' }, { message: 'function public.site_flag_oversold_booking(uuid) does not exist' }]) {
      expect(await bookingIsOversold(rpcClient({ data: null, error }).fake, 'b1')).toBe(false);
    }
  });

  it.each([
    [{ data: null, error: { code: '42501', message: 'permission denied for function' } }, 'Could not check the table: permission denied for function'],
    [{ data: null, error: { code: '57014', message: 'canceling statement due to statement timeout' } }, 'Could not check the table: canceling statement'],
    [{ data: null, error: { code: 'XX', message: undefined } }, 'Could not check the table: XX'],
    [{ data: null, error: null }, 'did not answer yes or no'],
    [{ data: 1, error: null }, 'did not answer yes or no'],
    [{ data: 'false', error: null }, 'did not answer yes or no'],
  ])('anything else is a failure, never "no": %j', async (answer, text) => {
    await expect(bookingIsOversold(rpcClient(answer).fake, 'b1')).rejects.toThrow(text);
  });
});

describe('bookingHeldForReview: is there an open conflict for this booking?', () => {
  it('yes when an open one exists, asking for exactly that booking and that state', async () => {
    const { fake, seen } = tableClient({ data: { id: 'k1' }, error: null });
    expect(await bookingHeldForReview(fake, 'b1')).toBe(true);
    expect(seen.table).toBe('site_booking_conflicts');
    expect(seen.filters).toEqual([['booking_id', 'b1'], ['status', 'open']]);
  });

  it('no when there is none', async () => {
    expect(await bookingHeldForReview(tableClient({ data: null, error: null }).fake, 'b1')).toBe(false);
  });

  it('no while the migration is not applied (no such table)', async () => {
    for (const error of [{ code: 'PGRST205', message: 'x' }, { code: '42P01', message: 'x' }, { message: 'Could not find the table public.site_booking_conflicts in the schema cache' }]) {
      expect(await bookingHeldForReview(tableClient({ data: null, error }).fake, 'b1')).toBe(false);
    }
  });

  it('any other failure is thrown, so the guest is never shown a confirmation on an answer that could not be read', async () => {
    await expect(bookingHeldForReview(tableClient({ data: null, error: { code: '42501', message: 'permission denied for table' } }).fake, 'b1')).rejects.toThrow('Could not check the booking: permission denied for table');
    await expect(bookingHeldForReview(tableClient({ data: null, error: { code: 'XX', message: undefined } }).fake, 'b1')).rejects.toThrow('Could not check the booking: XX');
  });
});
