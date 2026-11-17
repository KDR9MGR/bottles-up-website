import { supabase } from '@/lib/supabase';

// The complimentary bottle claim page (brief section 20): the recipient opens the link in their e-mail, sees what they are being given and where it is from, says where they are on the club's
// floor plan, and staff bring it. The page is public and reads and writes through the comp-claim function only (supabase/functions/_shared/compClaim.ts), which throttles every visit and
// returns nothing but what is shown here. Everything below is pure so what the page says and where a table is drawn can be tested.

/** The token the database makes: two uuids with the dashes taken out. */
export const CLAIM_TOKEN = /^[0-9a-f]{64}$/;
export const isClaimToken = (value: unknown): value is string => typeof value === 'string' && CLAIM_TOKEN.test(value);

export interface ClaimFloor {
  id: string;
  label: string;
  imageUrl: string | null;
}

export interface ClaimTable {
  id: string;
  name: string;
  floorId: string | null;
  /** Percent of the floor image from the left and the top, and the table's own size in percent: the same numbers the venue's own floor plan uses. */
  x: number | null;
  y: number | null;
  width: number | null;
  height: number | null;
}

export interface OpenClaim {
  state: 'open';
  venueName: string;
  eventTitle: string | null;
  item: string;
  size: string | null;
  quantity: number;
  sign: string | null;
  recipientName: string | null;
  expiresAt: string;
  floors: ClaimFloor[];
  tables: ClaimTable[];
}

export type ClaimEnd = 'submitted' | 'expired' | 'cancelled' | 'not_found' | 'bad_table' | 'rate_limited' | 'error';

export type ClaimResult = OpenClaim | { state: 'claimed'; item: string | null; quantity: number | null; venueName: string | null } | { state: ClaimEnd };

const asRecord = (v: unknown): Record<string, unknown> | null => (v && typeof v === 'object' && !Array.isArray(v) ? (v as Record<string, unknown>) : null);
const text = (v: unknown): string | null => (typeof v === 'string' ? v : null);
const number = (v: unknown): number | null => (typeof v === 'number' && Number.isFinite(v) ? v : null);

const ENDS: readonly string[] = ['submitted', 'expired', 'cancelled', 'not_found', 'bad_table'];

/** What the function answered, as the page can use it. Anything unreadable is an "error", never a half page. */
export function parseClaim(data: unknown): ClaimResult {
  const d = asRecord(data);
  if (!d) return { state: 'error' };
  const state = d.state;
  if (state === 'open') {
    const venueName = text(d.venue_name);
    const item = text(d.item);
    const quantity = number(d.quantity);
    const expiresAt = text(d.expires_at);
    if (venueName === null || item === null || quantity === null || expiresAt === null) return { state: 'error' };
    const floors: ClaimFloor[] = (Array.isArray(d.floors) ? d.floors : []).flatMap((f) => {
      const r = asRecord(f);
      const id = r && text(r.id);
      const label = r && text(r.label);
      return r && id && label !== null ? [{ id, label, imageUrl: text(r.image_url) }] : [];
    });
    const tables: ClaimTable[] = (Array.isArray(d.tables) ? d.tables : []).flatMap((t) => {
      const r = asRecord(t);
      const id = r && text(r.id);
      const name = r && text(r.name);
      return r && id && name !== null ? [{ id, name, floorId: text(r.floor_id), x: number(r.pos_x), y: number(r.pos_y), width: number(r.width), height: number(r.height) }] : [];
    });
    return { state: 'open', venueName, eventTitle: text(d.event_title), item, size: text(d.size), quantity, sign: text(d.sign), recipientName: text(d.recipient_name), expiresAt, floors, tables };
  }
  if (state === 'claimed') return { state: 'claimed', item: text(d.item), quantity: number(d.quantity), venueName: text(d.venue_name) };
  if (typeof state === 'string' && ENDS.includes(state)) return { state: state as ClaimEnd };
  return { state: 'error' };
}

async function ask(body: Record<string, unknown>): Promise<ClaimResult> {
  try {
    const { data, error } = await supabase.functions.invoke('comp-claim', { body });
    if (error) {
      const status = (error as { context?: { status?: number } }).context?.status;
      return { state: status === 429 ? 'rate_limited' : 'error' };
    }
    return parseClaim(data);
  } catch {
    return { state: 'error' };
  }
}

/** Opens the link: what the offer is, or why it cannot be claimed. */
export function viewClaim(token: string): Promise<ClaimResult> {
  return ask({ action: 'view', token });
}

/** Says where the person is. One claim only: a second one changes nothing. */
export function submitClaim(token: string, tableId: string): Promise<ClaimResult> {
  return ask({ action: 'submit', token, tableId });
}

// ---------------------------------------------------------------------------
// The map
// ---------------------------------------------------------------------------

/** A table that can be drawn on its floor's picture. */
export const isPlaced = (t: ClaimTable): boolean => t.floorId !== null && t.x !== null && t.y !== null;

/** The tables drawn on one floor. */
export const tablesOnFloor = (claim: OpenClaim, floorId: string): ClaimTable[] => claim.tables.filter((t) => isPlaced(t) && t.floorId === floorId);

/** The floors that have a picture and at least one table on it. */
export const mapFloors = (claim: OpenClaim): ClaimFloor[] => claim.floors.filter((f) => f.imageUrl !== null && tablesOnFloor(claim, f.id).length > 0);

/** Every table that is not on a picture the person can see: they are listed by name so nobody is left with nothing to choose. */
export function listedTables(claim: OpenClaim): ClaimTable[] {
  const drawn = new Set(mapFloors(claim).flatMap((f) => tablesOnFloor(claim, f.id).map((t) => t.id)));
  return claim.tables.filter((t) => !drawn.has(t.id));
}

const clamp = (value: number, min: number, max: number) => Math.min(max, Math.max(min, value));

/** Where and how big, in percent of the picture, kept inside it. A table with no size is drawn as a small square. */
export function markerStyle(t: ClaimTable): { left: string; top: string; width: string; height: string } {
  const width = clamp(t.width ?? 6, 2, 100);
  const height = clamp(t.height ?? 6, 2, 100);
  return {
    left: `${clamp(t.x ?? 0, 0, 100 - width)}%`,
    top: `${clamp(t.y ?? 0, 0, 100 - height)}%`,
    width: `${width}%`,
    height: `${height}%`,
  };
}

// ---------------------------------------------------------------------------
// Words
// ---------------------------------------------------------------------------

/** "2 × Patron (750ml)". */
export const giftLabel = (c: Pick<OpenClaim, 'quantity' | 'item' | 'size'>): string => `${c.quantity} × ${c.item}${c.size ? ` (${c.size})` : ''}`;

/** When the link stops working, in the visitor's own time. */
export function expiryText(iso: string, locale?: string): string {
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return '';
  return date.toLocaleString(locale, { weekday: 'long', month: 'long', day: 'numeric', hour: 'numeric', minute: '2-digit', timeZoneName: 'short' });
}

/** What the page says when there is nothing to choose. Never more than the state: nothing here says who the offer was for or where it was. */
export function endMessage(result: Exclude<ClaimResult, OpenClaim>): { title: string; body: string } {
  switch (result.state) {
    case 'submitted':
      return { title: 'Thank you', body: 'We have told the staff where you are. Someone will bring your bottle to you.' };
    case 'claimed':
      return {
        title: 'Already claimed',
        body: result.item && result.quantity !== null ? `${result.quantity} × ${result.item}${result.venueName ? ` from ${result.venueName}` : ''} has been claimed. Ask a member of staff if you need anything.` : 'This offer has already been claimed. Ask a member of staff if you need anything.',
      };
    case 'expired':
      return { title: 'This link has expired', body: 'The offer is no longer open. Ask a member of staff at the venue and they can look after you.' };
    case 'cancelled':
      return { title: 'This offer is no longer available', body: 'Ask a member of staff at the venue if you have any questions.' };
    case 'bad_table':
      return { title: 'Choose again', body: 'That place is not one of this venue\'s tables. Choose where you are from the list or the map.' };
    case 'rate_limited':
      return { title: 'Too many tries', body: 'Wait a few minutes and open the link again.' };
    case 'error':
      return { title: 'Something went wrong', body: 'We could not reach BottlesUp. Check your connection and try again.' };
    default:
      return { title: 'We could not find this offer', body: 'The link may be wrong or out of date. Check the e-mail it came from, or ask a member of staff.' };
  }
}
