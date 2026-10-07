// The rules behind the owner's venue setup editors: arrival times, table types and the bottle menu. Pure functions,
// tested without a browser. Each check mirrors the database function that finally decides (save_venue_table_type,
// save_venue_bottle, add_venue_time_slot): the form says what is wrong in plain words before anything is sent, and the
// database still refuses anything that gets past it. Money is typed in dollars and stored in whole cents.

export const DAY_LABELS = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'] as const;
export const DAY_SHORT = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'] as const;
/** Monday first is how a week of opening nights is usually read; the stored day numbers stay 0 (Sunday) to 6. */
export const DAY_ORDER = [1, 2, 3, 4, 5, 6, 0] as const;

// ---------------------------------------------------------------------------
// Money
// ---------------------------------------------------------------------------

/**
 * "1,250.50", "$90" or "90.5" as whole cents; null when it is blank, negative, has more than two decimals, or is not a
 * number. Done on the digits, never with floating point, so 19.99 can never become 1998 cents.
 */
export function parseMoney(input: string): number | null {
  const cleaned = input.trim().replace(/^\$/, '').replace(/,/g, '').trim();
  const match = /^(\d{1,9})(?:\.(\d{1,2}))?$/.exec(cleaned);
  if (!match) return null;
  const dollars = Number(match[1]);
  const cents = Number((match[2] ?? '').padEnd(2, '0') || '0');
  return dollars * 100 + cents;
}

/** Cents as the text for an input: "1500.00". Null or undefined is an empty box. */
export function moneyInput(cents: number | null | undefined): string {
  if (cents === null || cents === undefined) return '';
  return (cents / 100).toFixed(2);
}

/** Cents for display: "$1,500.00". */
export function formatMoney(cents: number): string {
  return `$${(cents / 100).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
}

/** A whole number written in a box ("12"), or null if it is blank or anything else ("1.5", "1e3", "-2", "12abc"). */
export function parseWhole(input: string): number | null {
  const t = input.trim();
  if (!/^\d{1,9}$/.test(t)) return null;
  return Number(t);
}

// ---------------------------------------------------------------------------
// Arrival times
// ---------------------------------------------------------------------------

export interface TimeSlot {
  slotId: string;
  dayOfWeek: number;
  /** "21:00:00" as the database returns it. */
  startTime: string;
  label: string | null;
  bookingCount: number;
}

/** "21:00:00" or "21:00" as "9:00 PM". Anything that is not a time is returned as it came. */
export function formatSlotTime(time: string): string {
  const m = /^(\d{1,2}):(\d{2})/.exec(time);
  if (!m) return time;
  const h = Number(m[1]);
  const min = m[2];
  if (h > 23 || Number(min) > 59) return time;
  const hour12 = h % 12 === 0 ? 12 : h % 12;
  return `${hour12}:${min} ${h < 12 ? 'AM' : 'PM'}`;
}

/** The value of a time input ("21:00") from the database's "21:00:00". */
export function slotTimeInput(time: string): string {
  return /^\d{2}:\d{2}/.test(time) ? time.slice(0, 5) : '';
}

/** Arrival times grouped by day, earliest first within each day. Days with none are still present (as an empty list). */
export function groupSlotsByDay(slots: readonly TimeSlot[]): { day: number; label: string; slots: TimeSlot[] }[] {
  return DAY_ORDER.map((day) => ({
    day,
    label: DAY_LABELS[day],
    slots: slots.filter((s) => s.dayOfWeek === day).sort((a, b) => a.startTime.localeCompare(b.startTime)),
  }));
}

export interface SlotForm {
  days: number[];
  /** A time input's value, e.g. "21:00". */
  time: string;
  label: string;
}

export function validateSlotForm(form: SlotForm): string[] {
  const problems: string[] = [];
  if (form.days.length === 0) problems.push('Choose at least one day.');
  if (form.days.some((d) => !Number.isInteger(d) || d < 0 || d > 6)) problems.push('Choose days from the list.');
  if (!/^([01]\d|2[0-3]):[0-5]\d$/.test(form.time)) problems.push('Choose an arrival time.');
  if (form.label.trim().length > 60) problems.push('The note must be 60 characters or fewer.');
  return problems;
}

export interface SlotAttempt {
  day: number;
  /** null = added; otherwise the reason it was not. */
  error: string | null;
}

/** One sentence for a batch of adds: what was added, what already existed, and what failed. */
export function summarizeSlotAttempts(attempts: readonly SlotAttempt[]): { title: string; description?: string; failed: boolean } {
  const added = attempts.filter((a) => a.error === null).length;
  const already = attempts.filter((a) => a.error !== null && /already added/i.test(a.error));
  const failed = attempts.filter((a) => a.error !== null && !/already added/i.test(a.error));
  const dayNames = (list: readonly SlotAttempt[]) => list.map((a) => DAY_LABELS[a.day]).join(', ');

  if (failed.length > 0) {
    return {
      title: added > 0 ? `Added ${added}, but some could not be added` : 'Could not add that arrival time',
      description: `${dayNames(failed)}: ${failed[0].error}`,
      failed: true,
    };
  }
  if (added === 0) return { title: 'Already added', description: `${dayNames(already)} already ${already.length === 1 ? 'has' : 'have'} that arrival time.`, failed: false };
  return {
    title: added === 1 ? 'Arrival time added' : `${added} arrival times added`,
    description: already.length > 0 ? `${dayNames(already)} already had it.` : undefined,
    failed: false,
  };
}

// ---------------------------------------------------------------------------
// Table types
// ---------------------------------------------------------------------------

export interface TableTypeRow {
  typeId: string;
  name: string;
  description: string | null;
  maxGuests: number;
  minGuests: number | null;
  minSpendCents: number;
  depositCents: number;
  inventoryCount: number;
  imageUrl: string | null;
  badgeLabel: string | null;
  isFeatured: boolean;
  pricingMode: 'flat' | 'hourly';
  hourlyRateCents: number | null;
  minHours: number | null;
  floorId: string | null;
  sortOrder: number;
  bookingCount: number;
}

export interface TableTypeForm {
  name: string;
  description: string;
  maxGuests: string;
  minGuests: string;
  inventoryCount: string;
  minSpend: string;
  deposit: string;
  pricingMode: 'flat' | 'hourly';
  hourlyRate: string;
  minHours: string;
  badgeLabel: string;
  isFeatured: boolean;
  imageUrl: string;
}

export const EMPTY_TABLE_TYPE_FORM: TableTypeForm = {
  name: '', description: '', maxGuests: '', minGuests: '', inventoryCount: '1', minSpend: '', deposit: '',
  pricingMode: 'flat', hourlyRate: '', minHours: '', badgeLabel: '', isFeatured: false, imageUrl: '',
};

export function tableTypeForm(row: TableTypeRow): TableTypeForm {
  return {
    name: row.name,
    description: row.description ?? '',
    maxGuests: String(row.maxGuests),
    minGuests: row.minGuests === null ? '' : String(row.minGuests),
    inventoryCount: String(row.inventoryCount),
    minSpend: moneyInput(row.minSpendCents),
    deposit: moneyInput(row.depositCents),
    pricingMode: row.pricingMode,
    hourlyRate: moneyInput(row.hourlyRateCents),
    minHours: row.minHours === null ? '' : String(row.minHours),
    badgeLabel: row.badgeLabel ?? '',
    isFeatured: row.isFeatured,
    imageUrl: row.imageUrl ?? '',
  };
}

const MAX_TABLE_MONEY_CENTS = 100_000_000;
const MAX_BOTTLE_PRICE_CENTS = 10_000_000;

/** Plain-language problems with the table type form; an empty list means it can be sent. */
export function validateTableTypeForm(f: TableTypeForm): string[] {
  const problems: string[] = [];
  if (!f.name.trim()) problems.push('Give the table a name.');
  else if (f.name.trim().length > 120) problems.push('The name must be 120 characters or fewer.');
  if (f.description.trim().length > 2000) problems.push('The description must be 2000 characters or fewer.');

  const max = parseWhole(f.maxGuests);
  if (max === null || max < 1 || max > 100) problems.push('Maximum guests must be a whole number from 1 to 100.');
  if (f.minGuests.trim() !== '') {
    const min = parseWhole(f.minGuests);
    if (min === null || min < 1 || min > 100) problems.push('Minimum guests must be a whole number from 1 to 100, or left empty.');
    else if (max !== null && min > max) problems.push('Minimum guests cannot be more than maximum guests.');
  }
  const count = parseWhole(f.inventoryCount);
  if (count === null || count > 500) problems.push('The number of tables must be a whole number from 0 to 500.');

  for (const [label, value] of [['Minimum spend', f.minSpend], ['Deposit', f.deposit]] as const) {
    if (value.trim() === '') continue; // empty means none
    const cents = parseMoney(value);
    if (cents === null) problems.push(`${label} must be an amount like 150 or 150.50.`);
    else if (cents > MAX_TABLE_MONEY_CENTS) problems.push(`${label} is too large.`);
  }

  if (f.pricingMode === 'hourly') {
    const rate = parseMoney(f.hourlyRate);
    if (rate === null || rate < 1) problems.push('Enter the hourly rate, for example 200.');
    else if (rate > MAX_TABLE_MONEY_CENTS) problems.push('The hourly rate is too large.');
    if (f.minHours.trim() !== '') {
      const hours = parseWhole(f.minHours);
      if (hours === null || hours < 1 || hours > 24) problems.push('Minimum hours must be a whole number from 1 to 24.');
    }
  }
  if (f.badgeLabel.trim().length > 40) problems.push('The badge must be 40 characters or fewer.');
  return problems;
}

/**
 * What is sent for a table type. Only call this when validateTableTypeForm returned nothing. Sends every field the form
 * shows, and nothing it does not (placing a table on a floor plan is not part of it).
 */
export function tableTypePayload(f: TableTypeForm): Record<string, unknown> {
  const hourly = f.pricingMode === 'hourly';
  return {
    name: f.name.trim(),
    description: f.description.trim() || null,
    max_guests: parseWhole(f.maxGuests),
    min_guests: f.minGuests.trim() === '' ? null : parseWhole(f.minGuests),
    inventory_count: parseWhole(f.inventoryCount),
    min_spend_cents: f.minSpend.trim() === '' ? 0 : parseMoney(f.minSpend),
    deposit_cents: f.deposit.trim() === '' ? 0 : parseMoney(f.deposit),
    pricing_mode: f.pricingMode,
    hourly_rate_cents: hourly ? parseMoney(f.hourlyRate) : null,
    min_hours: hourly ? (f.minHours.trim() === '' ? 1 : parseWhole(f.minHours)) : null,
    badge_label: f.badgeLabel.trim() || null,
    is_featured: f.isFeatured,
    image_url: f.imageUrl.trim() || null,
  };
}

/** One line describing what a guest pays, for the list: "Min spend $1,500.00 · deposit $500.00". */
export function describeTablePrice(row: Pick<TableTypeRow, 'pricingMode' | 'hourlyRateCents' | 'minHours' | 'minSpendCents' | 'depositCents'>): string {
  const parts: string[] = [];
  if (row.pricingMode === 'hourly' && row.hourlyRateCents !== null) {
    parts.push(`${formatMoney(row.hourlyRateCents)} per hour${row.minHours && row.minHours > 1 ? `, ${row.minHours} hour minimum` : ''}`);
  }
  if (row.minSpendCents > 0) parts.push(`min spend ${formatMoney(row.minSpendCents)}`);
  if (row.depositCents > 0) parts.push(`deposit ${formatMoney(row.depositCents)}`);
  return parts.length > 0 ? parts.join(' · ') : 'No minimum spend or deposit';
}

// ---------------------------------------------------------------------------
// Bottles
// ---------------------------------------------------------------------------

export interface BottleRow {
  bottleId: string;
  name: string;
  size: string | null;
  description: string | null;
  priceCents: number;
  category: string | null;
  imageUrl: string | null;
  isAvailable: boolean;
  isSoldOut: boolean;
  stockQuantity: number | null;
  sortOrder: number;
}

export interface BottleForm {
  name: string;
  size: string;
  category: string;
  description: string;
  price: string;
  stock: string;
  imageUrl: string;
  isAvailable: boolean;
  isSoldOut: boolean;
}

export const EMPTY_BOTTLE_FORM: BottleForm = {
  name: '', size: '', category: '', description: '', price: '', stock: '', imageUrl: '', isAvailable: true, isSoldOut: false,
};

export function bottleForm(row: BottleRow): BottleForm {
  return {
    name: row.name,
    size: row.size ?? '',
    category: row.category ?? '',
    description: row.description ?? '',
    price: moneyInput(row.priceCents),
    stock: row.stockQuantity === null ? '' : String(row.stockQuantity),
    imageUrl: row.imageUrl ?? '',
    isAvailable: row.isAvailable,
    isSoldOut: row.isSoldOut,
  };
}

export function validateBottleForm(f: BottleForm): string[] {
  const problems: string[] = [];
  if (!f.name.trim()) problems.push('Give the bottle a name.');
  else if (f.name.trim().length > 120) problems.push('The name must be 120 characters or fewer.');
  if (f.size.trim().length > 40) problems.push('The size must be 40 characters or fewer.');
  if (f.category.trim().length > 40) problems.push('The category must be 40 characters or fewer.');
  if (f.description.trim().length > 1000) problems.push('The description must be 1000 characters or fewer.');
  const price = parseMoney(f.price);
  if (price === null) problems.push('Enter the price as an amount like 195 or 195.50.');
  else if (price > MAX_BOTTLE_PRICE_CENTS) problems.push('The price is too large.');
  if (f.stock.trim() !== '') {
    const stock = parseWhole(f.stock);
    if (stock === null || stock > 100_000) problems.push('Stock must be a whole number, or left empty if you do not track it.');
  }
  return problems;
}

export function bottlePayload(f: BottleForm): Record<string, unknown> {
  return {
    name: f.name.trim(),
    size: f.size.trim() || null,
    category: f.category.trim() || null,
    description: f.description.trim() || null,
    price_cents: parseMoney(f.price),
    stock_quantity: f.stock.trim() === '' ? null : parseWhole(f.stock),
    image_url: f.imageUrl.trim() || null,
    is_available: f.isAvailable,
    is_sold_out: f.isSoldOut,
  };
}

/** What a guest sees for a bottle right now. A bottle that is off the menu is hidden, whatever its sold-out flag says. */
export function bottleStatus(row: Pick<BottleRow, 'isAvailable' | 'isSoldOut'>): 'off_menu' | 'sold_out' | 'available' {
  if (!row.isAvailable) return 'off_menu';
  if (row.isSoldOut) return 'sold_out';
  return 'available';
}

// ---------------------------------------------------------------------------
// Floors
// ---------------------------------------------------------------------------

export interface FloorRow {
  floorId: string;
  label: string;
  imageUrl: string;
  sortOrder: number;
  tableCount: number;
}

export function validateFloorForm(label: string, imageUrl: string): string[] {
  const problems: string[] = [];
  if (!label.trim()) problems.push('Give the floor a name, for example "Main room".');
  else if (label.trim().length > 60) problems.push('The name must be 60 characters or fewer.');
  if (!imageUrl.trim()) problems.push('Upload the floor plan image.');
  return problems;
}
