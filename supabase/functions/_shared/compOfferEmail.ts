// The e-mail that carries a complimentary offer's claim link, as pure functions (no network, no Deno), so what lands in an inbox is tested.
//
// The subject is fixed and nothing a person typed reaches a header. The recipient's name and the club's and event's names are text staff typed, so everything dynamic is HTML-escaped and
// reduced to one line. The link is built by this application from a token the database made: it is checked to be an https address before it goes into the message.

import { escapeHtml } from './teamInvitationTemplate.ts';

export const COMP_OFFER_SUBJECT = 'A complimentary bottle for you';

export interface CompOfferEmailContext {
  toName: string | null;
  venueName: string;
  eventTitle: string | null;
  item: string;
  quantity: number;
  /** When the link stops working, as the database's timestamp. */
  expiresAt: string;
  /** The club's time zone (an IANA name), or null for the platform default. */
  timeZone: string | null;
  /** The claim link, https only. */
  link: string;
}

const oneLine = (value: string) => value.replace(/\s+/g, ' ').trim();

/** "Tuesday, November 24, 9:00 PM EST" in the club's own time (the platform default when the zone is missing or not a real one; UTC as a last resort). Empty when the time itself is unreadable. */
export function expiryLabel(iso: string, zone: string | null): string {
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return '';
  const format = (timeZone: string) =>
    date.toLocaleString('en-US', { timeZone, weekday: 'long', month: 'long', day: 'numeric', hour: 'numeric', minute: '2-digit', timeZoneName: 'short' });
  try {
    return format(zone || 'America/Toronto');
  } catch {
    return format('UTC');
  }
}

/** What is being given, in a few words: "2 × Patron". */
export function describeGift(quantity: number, item: string): string {
  return `${quantity} × ${oneLine(item)}`;
}

const SAFE_LINK = /^https:\/\/[^\s"'<>]+$/;

export function buildCompOfferEmail(ctx: CompOfferEmailContext): { subject: string; html: string; text: string } {
  if (!SAFE_LINK.test(ctx.link)) throw new Error('the claim link is not an https address');
  const venue = oneLine(ctx.venueName);
  const name = ctx.toName ? oneLine(ctx.toName) : '';
  const gift = describeGift(ctx.quantity, ctx.item);
  const forEvent = ctx.eventTitle ? ` for ${oneLine(ctx.eventTitle)}` : '';
  const expiry = expiryLabel(ctx.expiresAt, ctx.timeZone);
  const hello = name ? `Hi ${name},` : 'Hi,';
  const line1 = `${venue} would like to give you ${gift} on the house${forEvent}.`;
  const line2 = 'To claim it, open the link below and tell them where you are. A member of staff will bring it to you.';
  const line3 = expiry ? `The link works once and stops working on ${expiry}.` : 'The link works once and expires.';
  const line4 = 'If you were not expecting this, you can ignore this e-mail. Nothing is charged.';

  const html = `
    <div style="font-family: sans-serif; max-width: 480px; margin: 0 auto; padding: 24px; background: #0a0a0a; color: #fff; border-radius: 16px;">
      <h1 style="color: #f97316; font-size: 22px;">A bottle on the house</h1>
      <p>${escapeHtml(hello)}</p>
      <p>${escapeHtml(line1)}</p>
      <p>${escapeHtml(line2)}</p>
      <p style="margin: 24px 0;"><a href="${escapeHtml(ctx.link)}" style="background: #f97316; color: #fff; padding: 12px 20px; border-radius: 10px; text-decoration: none; font-weight: bold;">Claim your bottle</a></p>
      <p style="color: #999; font-size: 12px;">${escapeHtml(line3)} ${escapeHtml(line4)}</p>
    </div>`;
  const text = [hello, '', line1, line2, '', ctx.link, '', line3, line4].join('\n');
  return { subject: COMP_OFFER_SUBJECT, html, text };
}
