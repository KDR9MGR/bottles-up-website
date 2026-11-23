// When a ticket type may be bought, as the pages show it. The checkout function (supabase/functions/_shared/saleWindow.ts) decides for real; this only tells the
// visitor in advance, so nobody fills in a form for a ticket type that is not on sale. Same rule: sales start AT the start moment and end AT the end moment
// (a type set to end at 10:00 cannot be bought at 10:00). A ticket type with no dates is on sale, as before.

export type SaleWindowTier = { sale_starts_at?: string | null; sale_ends_at?: string | null };

export type SaleState =
  | { state: 'open' }
  | { state: 'not_started'; opensAt: Date }
  | { state: 'ended'; closedAt: Date };

function parse(value: string | null | undefined): Date | null {
  if (!value) return null;
  const d = new Date(value);
  return Number.isNaN(d.getTime()) ? null : d;
}

export function saleState(tier: SaleWindowTier, now: Date = new Date()): SaleState {
  const start = parse(tier.sale_starts_at);
  const end = parse(tier.sale_ends_at);
  if (start && now.getTime() < start.getTime()) return { state: 'not_started', opensAt: start };
  if (end && now.getTime() >= end.getTime()) return { state: 'ended', closedAt: end };
  return { state: 'open' };
}

export const isOnSale = (tier: SaleWindowTier, now: Date = new Date()): boolean => saleState(tier, now).state === 'open';

/** "On sale from Dec 5, 7:00 PM", "Sales ended", or null when the type is on sale. The time is shown in the visitor's own zone unless [timeZone] says otherwise. */
export function saleLabel(tier: SaleWindowTier, now: Date = new Date(), timeZone?: string): string | null {
  const s = saleState(tier, now);
  if (s.state === 'open') return null;
  if (s.state === 'ended') return 'Sales ended';
  const when = new Intl.DateTimeFormat('en-CA', { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit', ...(timeZone ? { timeZone } : {}) }).format(s.opensAt);
  return `On sale from ${when}`;
}

/** The ticket type to start on: the one asked for if it is on sale, else the first that is on sale, else the first (the form then says why it cannot be bought). */
export function defaultTierId(tiers: ({ id: string } & SaleWindowTier)[], preferredId: string | null | undefined, now: Date = new Date()): string {
  if (tiers.length === 0) return '';
  const preferred = preferredId ? tiers.find((t) => t.id === preferredId) : undefined;
  if (preferred && isOnSale(preferred, now)) return preferred.id;
  const firstOpen = tiers.find((t) => isOnSale(t, now));
  if (firstOpen) return firstOpen.id;
  return (preferred ?? tiers[0]).id;
}
