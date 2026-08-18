import { createClient } from 'npm:@supabase/supabase-js@2';

// eslint-disable-next-line @typescript-eslint/no-explicit-any
type SupabaseClient = ReturnType<typeof createClient<any>>;

export interface PromoValidationResult {
  valid: boolean;
  message: string;
  promoCodeId?: string;
  discountCents?: number;
}

// Single source of truth for "is this code usable right now, and what does it
// discount". Used both by the public preview endpoint (validate-promo-code)
// and, re-run from scratch, at actual checkout-session creation - a client
// never gets to just hand over a discount amount it computed itself.
export async function validatePromoCode(
  supabase: SupabaseClient,
  opts: {
    code: string;
    appliesTo: 'tickets' | 'tables';
    venueId: string | null;
    subtotalCents: number;
  },
): Promise<PromoValidationResult> {
  const normalizedCode = opts.code.trim().toUpperCase();
  if (!normalizedCode) {
    return { valid: false, message: 'Enter a promo code' };
  }

  const { data: promo, error } = await supabase
    .from('promo_codes')
    .select('id, discount_type, discount_value, applies_to, max_uses, used_count, min_purchase_cents, starts_at, expires_at, is_active')
    .eq('code', normalizedCode)
    .maybeSingle();

  if (error || !promo) {
    return { valid: false, message: 'Invalid promo code' };
  }
  if (!promo.is_active) {
    return { valid: false, message: 'This promo code is no longer active' };
  }

  const now = new Date();
  if (promo.starts_at && new Date(promo.starts_at) > now) {
    return { valid: false, message: 'This promo code is not active yet' };
  }
  if (promo.expires_at && new Date(promo.expires_at) < now) {
    return { valid: false, message: 'This promo code has expired' };
  }
  // Best-effort: not airtight under heavy concurrent checkouts (used_count only
  // increments on payment fulfillment, not at checkout-creation time), same
  // documented trade-off as the capacity checks elsewhere in this codebase.
  if (promo.max_uses !== null && promo.used_count >= promo.max_uses) {
    return { valid: false, message: 'This promo code has reached its usage limit' };
  }
  if (promo.applies_to !== 'both' && promo.applies_to !== opts.appliesTo) {
    const productName = opts.appliesTo === 'tickets' ? 'event tickets' : 'table bookings';
    return { valid: false, message: `This promo code doesn't apply to ${productName}` };
  }
  if (promo.min_purchase_cents && opts.subtotalCents < promo.min_purchase_cents) {
    const min = (promo.min_purchase_cents / 100).toFixed(2);
    return { valid: false, message: `This promo code requires a minimum purchase of $${min}` };
  }

  // Venue scoping: zero rows means the code applies to every venue.
  const { data: venueLinks } = await supabase
    .from('promo_code_venues')
    .select('venue_id')
    .eq('promo_code_id', promo.id);

  if (venueLinks && venueLinks.length > 0) {
    const allowed = new Set(venueLinks.map((v: { venue_id: string }) => v.venue_id));
    if (!opts.venueId || !allowed.has(opts.venueId)) {
      return { valid: false, message: 'This promo code is not valid for this venue' };
    }
  }

  let discountCents: number;
  if (promo.discount_type === 'percentage') {
    discountCents = Math.round((opts.subtotalCents * Number(promo.discount_value)) / 100);
  } else {
    discountCents = Math.round(Number(promo.discount_value));
  }
  discountCents = Math.min(discountCents, opts.subtotalCents);

  if (discountCents <= 0) {
    return { valid: false, message: 'This promo code has no effect on this order' };
  }

  return { valid: true, message: 'Promo code applied', promoCodeId: promo.id, discountCents };
}
