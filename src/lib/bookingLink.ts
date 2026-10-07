// The Booking Link section (client brief, section 4): the address guests use to book at a venue, a QR code of it, and
// whether it works yet. Pure functions, tested without a browser. The page itself is the existing public venue page
// (`/venues/:slug-or-id`); nothing here creates routes or grants anything.

export const DEFAULT_SITE_URL = 'https://www.bottlesupapp.com';

/**
 * The address links should point at. A configured value is used only if it is a plain https address; anything else (http,
 * garbage, a login embedded in it) is ignored and the real site is used, so a mistake in configuration can never put a
 * wrong or unsafe address on a printed QR code. A path or query on it is dropped: only the origin is kept.
 */
export function siteOrigin(configured: string | undefined | null): string {
  const raw = (configured ?? '').trim();
  if (raw) {
    try {
      const url = new URL(raw);
      if (url.protocol === 'https:' && !url.username && !url.password && url.hostname.includes('.')) return url.origin;
    } catch {
      // not an address: fall through to the default
    }
  }
  return DEFAULT_SITE_URL;
}

export interface LinkVenue {
  id: string;
  slug: string | null;
}

/** `https://site/venues/<slug>`, or the venue id when it has no usable slug (the public page accepts both). */
export function bookingLink(site: string, venue: LinkVenue): string {
  const usable = venue.slug && /^[a-z0-9][a-z0-9-]*$/i.test(venue.slug) ? venue.slug : venue.id;
  return `${site.replace(/\/+$/, '')}/venues/${encodeURIComponent(usable)}`;
}

/** The public page only shows a published venue, so only a published venue's link works. */
export function isLive(status: string): boolean {
  return status === 'published';
}

export function linkNote(status: string): string {
  return isLive(status)
    ? 'Guests can book through this link now.'
    : 'This link starts working when the venue goes live. Until then guests who open it will see a "not found" page.';
}

/** A safe file name for the downloaded QR code: "Club Ñoche & Bar" becomes "club-noche-bar-booking-qr.png". */
export function qrFileName(venueName: string): string {
  const base = venueName
    .normalize('NFKD')
    .replace(/[̀-ͯ]/g, '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 60);
  return `${base || 'venue'}-booking-qr.png`;
}
