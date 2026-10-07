import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import {
  bottleForm, bottlePayload, bottleStatus, DAY_LABELS, DAY_ORDER, describeTablePrice, EMPTY_BOTTLE_FORM, EMPTY_TABLE_TYPE_FORM,
  formatMoney, formatSlotTime, groupSlotsByDay, moneyInput, parseMoney, parseWhole, slotTimeInput, summarizeSlotAttempts,
  tableTypeForm, tableTypePayload, validateBottleForm, validateFloorForm, validateSlotForm, validateTableTypeForm,
  type BottleRow, type TableTypeForm, type TableTypeRow, type TimeSlot,
} from './venueSetupForms';

describe('money is typed in dollars and kept in whole cents, without floating point', () => {
  it.each([
    ['150', 15000], ['150.5', 15050], ['150.50', 15050], ['$90', 9000], ['  $1,250.50 ', 125050], ['0', 0], ['0.07', 7], ['19.99', 1999],
    ['1,000,000', 100000000], ['0.1', 10], ['.', null],
  ] as const)('%s -> %s', (input, cents) => {
    expect(parseMoney(input)).toBe(cents);
  });

  it.each(['', '  ', '-5', '5.', '.5', '1.234', 'abc', '12abc', '1e3', '1.2.3', '$', '1 000', '--1', '+5', '١٢٣'])('%j is not an amount', (input) => {
    expect(parseMoney(input)).toBeNull();
  });

  it('19.99 is exactly 1999 cents, not 1998 (the floating point trap)', () => {
    expect(parseMoney('19.99')).toBe(1999);
    expect(parseMoney('4.35')).toBe(435);
    expect(parseMoney('1.005')).toBeNull(); // a third decimal is refused, never silently rounded
  });

  it('what a box shows can be typed back unchanged, for every amount in the first $60 and a spread beyond', () => {
    for (let c = 0; c <= 6000; c++) expect(parseMoney(moneyInput(c))).toBe(c);
    for (const c of [99999, 100000, 123456, 999999, 12345678, 100000000]) expect(parseMoney(moneyInput(c))).toBe(c);
  });

  it('an empty box for no amount', () => {
    expect(moneyInput(null)).toBe('');
    expect(moneyInput(undefined)).toBe('');
    expect(moneyInput(0)).toBe('0.00');
  });

  it('formats for reading', () => {
    expect(formatMoney(150000)).toBe('$1,500.00');
    expect(formatMoney(5)).toBe('$0.05');
    expect(formatMoney(0)).toBe('$0.00');
  });
});

describe('whole numbers', () => {
  it.each([['12', 12], [' 7 ', 7], ['0', 0], ['100', 100]] as const)('%j -> %s', (input, n) => expect(parseWhole(input)).toBe(n));
  it.each(['', '1.5', '-2', '1e3', '12abc', 'abc', '1,000', '9999999999'])('%j is not a whole number', (input) => expect(parseWhole(input)).toBeNull());
});

describe('arrival times', () => {
  it.each([
    ['00:00:00', '12:00 AM'], ['00:30', '12:30 AM'], ['09:05:00', '9:05 AM'], ['11:59:00', '11:59 AM'], ['12:00:00', '12:00 PM'],
    ['13:00:00', '1:00 PM'], ['21:00:00', '9:00 PM'], ['23:59:00', '11:59 PM'],
  ])('%s reads as %s', (input, text) => expect(formatSlotTime(input)).toBe(text));

  it('anything that is not a time is left as it is, never turned into a wrong time', () => {
    for (const bad of ['24:00:00', '12:60', 'later', '', '9pm']) expect(formatSlotTime(bad)).toBe(bad);
  });

  it('a time input takes hours and minutes only', () => {
    expect(slotTimeInput('21:00:00')).toBe('21:00');
    expect(slotTimeInput('nonsense')).toBe('');
  });

  const slot = (day: number, time: string, id = `${day}-${time}`): TimeSlot => ({ slotId: id, dayOfWeek: day, startTime: time, label: null, bookingCount: 0 });

  it('groups by day, Monday first and Sunday last, earliest time first, with every day present', () => {
    const groups = groupSlotsByDay([slot(0, '21:00:00'), slot(5, '23:00:00'), slot(5, '21:00:00'), slot(1, '20:00:00')]);
    expect(groups.map((g) => g.label)).toEqual(['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday']);
    expect(groups.find((g) => g.day === 5)?.slots.map((s) => s.startTime)).toEqual(['21:00:00', '23:00:00']);
    expect(groups.find((g) => g.day === 2)?.slots).toEqual([]);
    expect(groups.find((g) => g.day === 0)?.slots).toHaveLength(1);
    expect([...DAY_ORDER].sort()).toEqual([0, 1, 2, 3, 4, 5, 6]);
  });

  it('every stored slot lands in exactly one day', () => {
    const all = [0, 1, 2, 3, 4, 5, 6].flatMap((d) => [slot(d, '20:00:00'), slot(d, '22:00:00')]);
    expect(groupSlotsByDay(all).flatMap((g) => g.slots)).toHaveLength(14);
  });

  it('validates the add form in plain words', () => {
    expect(validateSlotForm({ days: [5], time: '21:00', label: '' })).toEqual([]);
    expect(validateSlotForm({ days: [], time: '21:00', label: '' })).toEqual(['Choose at least one day.']);
    expect(validateSlotForm({ days: [5], time: '', label: '' })).toEqual(['Choose an arrival time.']);
    expect(validateSlotForm({ days: [5], time: '24:00', label: '' })).toEqual(['Choose an arrival time.']);
    expect(validateSlotForm({ days: [7], time: '21:00', label: '' })).toEqual(['Choose days from the list.']);
    expect(validateSlotForm({ days: [5], time: '21:00', label: 'x'.repeat(61) })).toEqual(['The note must be 60 characters or fewer.']);
    expect(validateSlotForm({ days: [], time: '', label: '' })).toHaveLength(2);
  });

  it('summarises a batch of adds', () => {
    expect(summarizeSlotAttempts([{ day: 5, error: null }])).toEqual({ title: 'Arrival time added', description: undefined, failed: false });
    expect(summarizeSlotAttempts([{ day: 5, error: null }, { day: 6, error: null }]).title).toBe('2 arrival times added');
    const some = summarizeSlotAttempts([{ day: 5, error: null }, { day: 6, error: 'that arrival time is already added' }]);
    expect(some).toMatchObject({ title: 'Arrival time added', description: 'Saturday already had it.', failed: false });
    const allDup = summarizeSlotAttempts([{ day: 5, error: 'that arrival time is already added' }]);
    expect(allDup).toMatchObject({ title: 'Already added', failed: false });
    expect(allDup.description).toBe('Friday already has that arrival time.');
    const bad = summarizeSlotAttempts([{ day: 5, error: null }, { day: 6, error: "You don't have access to do that." }]);
    expect(bad).toMatchObject({ title: 'Added 1, but some could not be added', failed: true });
    expect(bad.description).toBe("Saturday: You don't have access to do that.");
    expect(summarizeSlotAttempts([{ day: 0, error: 'boom' }])).toMatchObject({ title: 'Could not add that arrival time', failed: true });
  });

  it('names the days the way the database numbers them: 0 is Sunday', () => {
    expect(DAY_LABELS[0]).toBe('Sunday');
    expect(DAY_LABELS[6]).toBe('Saturday');
  });
});

const baseRow: TableTypeRow = {
  typeId: 't1', name: 'VIP booth', description: null, maxGuests: 6, minGuests: null, minSpendCents: 150000, depositCents: 50000,
  inventoryCount: 3, imageUrl: null, badgeLabel: null, isFeatured: false, pricingMode: 'flat', hourlyRateCents: null,
  minHours: null, floorId: null, sortOrder: 0, bookingCount: 0,
};
const goodForm = (over: Partial<TableTypeForm> = {}): TableTypeForm => ({ ...EMPTY_TABLE_TYPE_FORM, name: 'Booth', maxGuests: '6', ...over });

describe('table type form', () => {
  it('a new form is not valid until it has a name and a capacity, and says so', () => {
    expect(validateTableTypeForm(EMPTY_TABLE_TYPE_FORM)).toEqual(['Give the table a name.', 'Maximum guests must be a whole number from 1 to 100.']);
  });

  it('the smallest valid form needs only a name, a capacity and a count', () => {
    expect(validateTableTypeForm(goodForm())).toEqual([]);
    expect(tableTypePayload(goodForm())).toEqual({
      name: 'Booth', description: null, max_guests: 6, min_guests: null, inventory_count: 1, min_spend_cents: 0, deposit_cents: 0,
      pricing_mode: 'flat', hourly_rate_cents: null, min_hours: null, badge_label: null, is_featured: false, image_url: null,
    });
  });

  it.each([
    [{ name: '   ' }, 'Give the table a name.'],
    [{ name: 'x'.repeat(121) }, 'The name must be 120 characters or fewer.'],
    [{ description: 'x'.repeat(2001) }, 'The description must be 2000 characters or fewer.'],
    [{ maxGuests: '0' }, 'Maximum guests must be a whole number from 1 to 100.'],
    [{ maxGuests: '101' }, 'Maximum guests must be a whole number from 1 to 100.'],
    [{ maxGuests: '4.5' }, 'Maximum guests must be a whole number from 1 to 100.'],
    [{ minGuests: '0' }, 'Minimum guests must be a whole number from 1 to 100, or left empty.'],
    [{ minGuests: 'two' }, 'Minimum guests must be a whole number from 1 to 100, or left empty.'],
    [{ minGuests: '7' }, 'Minimum guests cannot be more than maximum guests.'],
    [{ inventoryCount: '' }, 'The number of tables must be a whole number from 0 to 500.'],
    [{ inventoryCount: '501' }, 'The number of tables must be a whole number from 0 to 500.'],
    [{ minSpend: 'lots' }, 'Minimum spend must be an amount like 150 or 150.50.'],
    [{ minSpend: '-1' }, 'Minimum spend must be an amount like 150 or 150.50.'],
    [{ minSpend: '1000001' }, 'Minimum spend is too large.'],
    [{ deposit: '12.345' }, 'Deposit must be an amount like 150 or 150.50.'],
    [{ badgeLabel: 'x'.repeat(41) }, 'The badge must be 40 characters or fewer.'],
    [{ pricingMode: 'hourly' as const }, 'Enter the hourly rate, for example 200.'],
    [{ pricingMode: 'hourly' as const, hourlyRate: '0' }, 'Enter the hourly rate, for example 200.'],
    [{ pricingMode: 'hourly' as const, hourlyRate: '200', minHours: '25' }, 'Minimum hours must be a whole number from 1 to 24.'],
    [{ pricingMode: 'hourly' as const, hourlyRate: '200', minHours: '1.5' }, 'Minimum hours must be a whole number from 1 to 24.'],
  ] as [Partial<TableTypeForm>, string][])('%j is refused: %s', (over, message) => {
    expect(validateTableTypeForm(goodForm(over))).toContain(message);
  });

  it('zero tables is allowed (it stops new bookings), and so is no minimum guests', () => {
    expect(validateTableTypeForm(goodForm({ inventoryCount: '0' }))).toEqual([]);
    expect(validateTableTypeForm(goodForm({ minGuests: '' }))).toEqual([]);
    expect(validateTableTypeForm(goodForm({ minGuests: '6' }))).toEqual([]); // equal to the maximum
  });

  it('hourly fields are ignored while the price is flat, and checked once it is hourly', () => {
    expect(validateTableTypeForm(goodForm({ hourlyRate: 'junk', minHours: 'junk' }))).toEqual([]);
    expect(validateTableTypeForm(goodForm({ pricingMode: 'hourly', hourlyRate: '200' }))).toEqual([]);
  });

  it('sends hourly pricing with a default of one minimum hour, and nothing hourly for flat pricing', () => {
    const hourly = tableTypePayload(goodForm({ pricingMode: 'hourly', hourlyRate: '200', minSpend: '1000' }));
    expect(hourly).toMatchObject({ pricing_mode: 'hourly', hourly_rate_cents: 20000, min_hours: 1, min_spend_cents: 100000 });
    const flat = tableTypePayload(goodForm({ hourlyRate: '200', minHours: '3' }));
    expect(flat).toMatchObject({ pricing_mode: 'flat', hourly_rate_cents: null, min_hours: null });
  });

  it('trims text, and turns blank optional fields into "none" so they can be cleared', () => {
    const p = tableTypePayload(goodForm({ name: '  Booth  ', description: '   ', badgeLabel: ' ', imageUrl: ' ' }));
    expect(p).toMatchObject({ name: 'Booth', description: null, badge_label: null, image_url: null });
  });

  it('opening a saved table and saving it unchanged sends the same values back', () => {
    const row: TableTypeRow = { ...baseRow, description: 'By the DJ', minGuests: 2, imageUrl: 'https://img.example/a.png', badgeLabel: 'Popular', isFeatured: true, pricingMode: 'hourly', hourlyRateCents: 20050, minHours: 2 };
    const form = tableTypeForm(row);
    expect(validateTableTypeForm(form)).toEqual([]);
    expect(tableTypePayload(form)).toEqual({
      name: 'VIP booth', description: 'By the DJ', max_guests: 6, min_guests: 2, inventory_count: 3, min_spend_cents: 150000, deposit_cents: 50000,
      pricing_mode: 'hourly', hourly_rate_cents: 20050, min_hours: 2, badge_label: 'Popular', is_featured: true, image_url: 'https://img.example/a.png',
    });
  });

  it('describes what a guest pays', () => {
    expect(describeTablePrice(baseRow)).toBe('min spend $1,500.00 · deposit $500.00');
    expect(describeTablePrice({ ...baseRow, minSpendCents: 0, depositCents: 0 })).toBe('No minimum spend or deposit');
    expect(describeTablePrice({ ...baseRow, pricingMode: 'hourly', hourlyRateCents: 20000, minHours: 3, minSpendCents: 0 })).toBe('$200.00 per hour, 3 hour minimum · deposit $500.00');
    expect(describeTablePrice({ ...baseRow, pricingMode: 'hourly', hourlyRateCents: 20000, minHours: 1, minSpendCents: 0, depositCents: 0 })).toBe('$200.00 per hour');
  });
});

describe('bottle form', () => {
  const good = { ...EMPTY_BOTTLE_FORM, name: 'Grey Goose', price: '195' };

  it('needs a name and a price, and says so', () => {
    expect(validateBottleForm(EMPTY_BOTTLE_FORM)).toEqual(['Give the bottle a name.', 'Enter the price as an amount like 195 or 195.50.']);
    expect(validateBottleForm(good)).toEqual([]);
  });

  it.each([
    [{ name: 'x'.repeat(121) }, 'The name must be 120 characters or fewer.'],
    [{ size: 'x'.repeat(41) }, 'The size must be 40 characters or fewer.'],
    [{ category: 'x'.repeat(41) }, 'The category must be 40 characters or fewer.'],
    [{ description: 'x'.repeat(1001) }, 'The description must be 1000 characters or fewer.'],
    [{ price: '-1' }, 'Enter the price as an amount like 195 or 195.50.'],
    [{ price: '19.5.0' }, 'Enter the price as an amount like 195 or 195.50.'],
    [{ price: '100001' }, 'The price is too large.'],
    [{ stock: '-3' }, 'Stock must be a whole number, or left empty if you do not track it.'],
    [{ stock: '2.5' }, 'Stock must be a whole number, or left empty if you do not track it.'],
    [{ stock: '100001' }, 'Stock must be a whole number, or left empty if you do not track it.'],
  ] as [Partial<typeof good>, string][])('%j is refused: %s', (over, message) => {
    expect(validateBottleForm({ ...good, ...over })).toContain(message);
  });

  it('a free bottle and a bottle without stock tracking are allowed', () => {
    expect(validateBottleForm({ ...good, price: '0' })).toEqual([]);
    expect(validateBottleForm({ ...good, stock: '0' })).toEqual([]);
  });

  it('sends what was typed; blank optional fields are cleared, an empty stock means "not tracked"', () => {
    expect(bottlePayload({ ...good, size: ' 750ml ', category: '', stock: '' })).toEqual({
      name: 'Grey Goose', size: '750ml', category: null, description: null, price_cents: 19500, stock_quantity: null,
      image_url: null, is_available: true, is_sold_out: false,
    });
    expect(bottlePayload({ ...good, stock: '0' })).toMatchObject({ stock_quantity: 0 });
  });

  it('opening a saved bottle and saving it unchanged sends the same values back', () => {
    const row: BottleRow = { bottleId: 'b1', name: 'Don Julio', size: '750ml', description: 'Tequila', priceCents: 62050, category: 'Tequila', imageUrl: 'https://img.example/d.png', isAvailable: true, isSoldOut: true, stockQuantity: 4, sortOrder: 2 };
    const form = bottleForm(row);
    expect(validateBottleForm(form)).toEqual([]);
    expect(bottlePayload(form)).toEqual({
      name: 'Don Julio', size: '750ml', category: 'Tequila', description: 'Tequila', price_cents: 62050, stock_quantity: 4,
      image_url: 'https://img.example/d.png', is_available: true, is_sold_out: true,
    });
  });

  it('what a guest sees: off the menu hides it, whatever the sold-out flag says', () => {
    expect(bottleStatus({ isAvailable: true, isSoldOut: false })).toBe('available');
    expect(bottleStatus({ isAvailable: true, isSoldOut: true })).toBe('sold_out');
    expect(bottleStatus({ isAvailable: false, isSoldOut: false })).toBe('off_menu');
    expect(bottleStatus({ isAvailable: false, isSoldOut: true })).toBe('off_menu');
  });
});

describe('floor form', () => {
  it('needs a name and an image', () => {
    expect(validateFloorForm('Main room', 'https://img.example/a.png')).toEqual([]);
    expect(validateFloorForm('  ', 'https://img.example/a.png')).toEqual(['Give the floor a name, for example "Main room".']);
    expect(validateFloorForm('Main', '')).toEqual(['Upload the floor plan image.']);
    expect(validateFloorForm('x'.repeat(61), 'https://img.example/a.png')).toEqual(['The name must be 60 characters or fewer.']);
  });
});

// The forms and the database must agree on which fields exist. The database refuses a key it does not know, so a field
// added to a form and forgotten in the SQL would fail for every owner. This reads the whitelist out of the migration.
describe('what the forms send matches what the database accepts', () => {
  const sql = readFileSync(join(__dirname, '..', '..', 'supabase', 'migrations', '20261010100000_venue_setup.sql'), 'utf8');

  function allowedKeys(fn: string): string[] {
    const body = new RegExp(`create function public\\.${fn}\\([\\s\\S]*?setup_only_keys\\(p_details, array\\[([\\s\\S]*?)\\]\\)`).exec(sql)?.[1] ?? '';
    return [...body.matchAll(/'(\w+)'/g)].map((m) => m[1]);
  }

  it('finds the whitelists it is comparing against (so this cannot pass by checking nothing)', () => {
    expect(allowedKeys('save_venue_table_type').length).toBeGreaterThan(10);
    expect(allowedKeys('save_venue_bottle').length).toBeGreaterThan(8);
  });

  it('every table type field the form sends is one the database accepts, and the form sends all of them except the ones kept for the CMS', () => {
    const sent = Object.keys(tableTypePayload(goodForm()));
    const allowed = allowedKeys('save_venue_table_type');
    expect(allowed).toEqual(expect.arrayContaining(sent));
    expect(allowed.filter((k) => !sent.includes(k))).toEqual(['sort_order']); // the form does not reorder
  });

  it('every bottle field the form sends is one the database accepts, and the form sends all of them except the order', () => {
    const sent = Object.keys(bottlePayload({ ...EMPTY_BOTTLE_FORM, name: 'x', price: '1' }));
    const allowed = allowedKeys('save_venue_bottle');
    expect(allowed).toEqual(expect.arrayContaining(sent));
    expect(allowed.filter((k) => !sent.includes(k))).toEqual(['sort_order']);
  });

  it('the form limits are the database limits', () => {
    // Money: whole cents up to 100,000,000 for tables and 10,000,000 for bottles.
    expect(sql).toContain("'minimum spend', 0, 100000000");
    expect(sql).toContain("'price', 0, 10000000");
    expect(validateTableTypeForm(goodForm({ minSpend: '1000000' }))).toEqual([]);
    expect(validateTableTypeForm(goodForm({ minSpend: '1000000.01' }))).not.toEqual([]);
    expect(validateBottleForm({ ...EMPTY_BOTTLE_FORM, name: 'x', price: '100000' })).toEqual([]);
    expect(validateBottleForm({ ...EMPTY_BOTTLE_FORM, name: 'x', price: '100000.01' })).not.toEqual([]);
    // Counts.
    expect(sql).toContain("'maximum guests', 1, 100");
    expect(sql).toContain("'number of tables', 0, 500");
    expect(sql).toContain("'minimum hours', 1, 24");
    expect(sql).toContain("'stock', 0, 100000");
    // Text lengths.
    expect(sql).toContain("'name', 120");
    expect(sql).toContain("'description', 2000");
    expect(sql).toContain("'badge', 40");
    expect(sql).toContain("'description', 1000");
    expect(sql).toContain('length(v_label) > 60');
  });
});
