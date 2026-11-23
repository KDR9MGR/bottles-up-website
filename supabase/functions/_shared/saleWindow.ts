// When a ticket type may be bought (developer fix list 22 Nov, item 3: "sale dates"). A ticket type may have a start and an end of sales
// (site_ticket_tiers.sale_starts_at / sale_ends_at, both optional: empty = on sale as always, which is every ticket type made before this existed).
// One place decides it, so the checkout function and anything else that asks says the same thing.
//
// The moment sales start counts as ON SALE (start <= now); the moment they end counts as CLOSED (now >= end). That is the half-open window
// [start, end): a ticket type set to end at 10:00 cannot be bought at 10:00.
//
// Door sales are deliberately not held to this: a person at the door sells whatever the night needs.

export type SaleWindowTier = { sale_starts_at?: string | null; sale_ends_at?: string | null };

export type SaleWindowBlock =
  | { blocked: false }
  | { blocked: true; reason: 'not_started'; message: string; opens_at: string }
  | { blocked: true; reason: 'ended'; message: string; closed_at: string };

function time(value: string | null | undefined): number | null {
  if (!value) return null;
  const t = Date.parse(value);
  return Number.isNaN(t) ? null : t;
}

/** Is this ticket type on sale at [now]? A date that cannot be read is treated as no date (the database only stores real ones). */
export function saleWindowBlock(tier: SaleWindowTier, now: Date = new Date()): SaleWindowBlock {
  const start = time(tier.sale_starts_at);
  const end = time(tier.sale_ends_at);
  const t = now.getTime();
  if (start !== null && t < start) {
    return { blocked: true, reason: 'not_started', message: 'Ticket sales for this ticket type have not opened yet.', opens_at: new Date(start).toISOString() };
  }
  if (end !== null && t >= end) {
    return { blocked: true, reason: 'ended', message: 'Ticket sales for this ticket type have ended.', closed_at: new Date(end).toISOString() };
  }
  return { blocked: false };
}
