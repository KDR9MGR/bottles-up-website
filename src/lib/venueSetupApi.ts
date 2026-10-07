import { call } from './account';
import type { BottleRow, FloorRow, TableTypeRow, TimeSlot } from './venueSetupForms';

// The owner's venue setup, over the database functions in 20261010100000_venue_setup.sql. Each call is checked by the
// database against the signed-in person's role at THIS venue; nothing here decides who may do what.

const num = (v: unknown, fallback = 0): number => (typeof v === 'number' ? v : Number(v ?? fallback) || fallback);
const text = (v: unknown): string | null => (typeof v === 'string' && v !== '' ? v : null);

// --- arrival times ---------------------------------------------------------

export async function listVenueTimeSlots(venueId: string): Promise<TimeSlot[]> {
  const rows = await call<Record<string, unknown>[] | null>('list_venue_time_slots', { p_venue: venueId });
  return (rows ?? []).map((r) => ({
    slotId: String(r.slot_id),
    dayOfWeek: num(r.day_of_week),
    startTime: String(r.start_time ?? ''),
    label: text(r.label),
    bookingCount: num(r.booking_count),
  }));
}

export async function addVenueTimeSlot(venueId: string, day: number, time: string, label: string): Promise<string> {
  return call<string>('add_venue_time_slot', { p_venue: venueId, p_day: day, p_start: time, p_label: label.trim() || null });
}

export async function removeVenueTimeSlot(venueId: string, slotId: string): Promise<void> {
  await call('remove_venue_time_slot', { p_venue: venueId, p_slot: slotId });
}

// --- floors ----------------------------------------------------------------

export async function listVenueFloors(venueId: string): Promise<FloorRow[]> {
  const rows = await call<Record<string, unknown>[] | null>('list_venue_floors', { p_venue: venueId });
  return (rows ?? []).map((r) => ({
    floorId: String(r.floor_id),
    label: String(r.label ?? ''),
    imageUrl: String(r.image_url ?? ''),
    sortOrder: num(r.sort_order),
    tableCount: num(r.table_count),
  }));
}

/** floorId null adds a floor; otherwise changes that one. */
export async function saveVenueFloor(venueId: string, floorId: string | null, label: string, imageUrl: string): Promise<string> {
  return call<string>('save_venue_floor', { p_venue: venueId, p_floor: floorId, p_label: label.trim(), p_image_url: imageUrl.trim() });
}

export async function removeVenueFloor(venueId: string, floorId: string): Promise<void> {
  await call('remove_venue_floor', { p_venue: venueId, p_floor: floorId });
}

// --- table types -----------------------------------------------------------

export async function listVenueTableTypes(venueId: string): Promise<TableTypeRow[]> {
  const rows = await call<Record<string, unknown>[] | null>('list_venue_table_types', { p_venue: venueId });
  return (rows ?? []).map((r) => ({
    typeId: String(r.type_id),
    name: String(r.name ?? ''),
    description: text(r.description),
    maxGuests: num(r.max_guests),
    minGuests: r.min_guests === null || r.min_guests === undefined ? null : num(r.min_guests),
    minSpendCents: num(r.min_spend_cents),
    depositCents: num(r.deposit_cents),
    inventoryCount: num(r.inventory_count),
    imageUrl: text(r.image_url),
    badgeLabel: text(r.badge_label),
    isFeatured: r.is_featured === true,
    pricingMode: r.pricing_mode === 'hourly' ? 'hourly' : 'flat',
    hourlyRateCents: r.hourly_rate_cents === null || r.hourly_rate_cents === undefined ? null : num(r.hourly_rate_cents),
    minHours: r.min_hours === null || r.min_hours === undefined ? null : num(r.min_hours),
    floorId: text(r.floor_id),
    sortOrder: num(r.sort_order),
    bookingCount: num(r.booking_count),
  }));
}

/** typeId null adds a table type; otherwise changes that one. Only the fields in `details` change. */
export async function saveVenueTableType(venueId: string, typeId: string | null, details: Record<string, unknown>): Promise<string> {
  return call<string>('save_venue_table_type', { p_venue: venueId, p_type: typeId, p_details: details });
}

export async function removeVenueTableType(venueId: string, typeId: string): Promise<void> {
  await call('remove_venue_table_type', { p_venue: venueId, p_type: typeId });
}

// --- bottles ---------------------------------------------------------------

export async function listVenueBottles(venueId: string): Promise<BottleRow[]> {
  const rows = await call<Record<string, unknown>[] | null>('list_venue_bottles', { p_venue: venueId });
  return (rows ?? []).map((r) => ({
    bottleId: String(r.bottle_id),
    name: String(r.name ?? ''),
    size: text(r.size),
    description: text(r.description),
    priceCents: num(r.price_cents),
    category: text(r.category),
    imageUrl: text(r.image_url),
    isAvailable: r.is_available !== false,
    isSoldOut: r.is_sold_out === true,
    stockQuantity: r.stock_quantity === null || r.stock_quantity === undefined ? null : num(r.stock_quantity),
    sortOrder: num(r.sort_order),
  }));
}

/** bottleId null adds a bottle; otherwise changes that one. Only the fields in `details` change. */
export async function saveVenueBottle(venueId: string, bottleId: string | null, details: Record<string, unknown>): Promise<string> {
  return call<string>('save_venue_bottle', { p_venue: venueId, p_bottle: bottleId, p_details: details });
}

export async function removeVenueBottle(venueId: string, bottleId: string): Promise<void> {
  await call('remove_venue_bottle', { p_venue: venueId, p_bottle: bottleId });
}
