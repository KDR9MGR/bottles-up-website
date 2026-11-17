import { describe, expect, it } from 'vitest';
import { buildCompOfferEmail, COMP_OFFER_SUBJECT, describeGift, expiryLabel } from '../../supabase/functions/_shared/compOfferEmail.ts';

// The e-mail that carries a complimentary bottle's claim link. What matters: the subject is fixed (nothing typed reaches a header), everything typed is escaped and one line, the link is https only,
// the expiry is in the club's own time, and the words never promise more than the offer is (nothing is charged; the link works once).
const LINK = 'https://bottlesupapp.com/claim/' + 'a'.repeat(64);
const ctx = (over: Record<string, unknown> = {}) => ({
  toName: 'Gina Guest',
  venueName: 'Club A',
  eventTitle: null as string | null,
  item: 'Patron',
  quantity: 2,
  expiresAt: '2026-11-25T02:00:00Z',
  timeZone: 'America/Toronto' as string | null,
  link: LINK,
  ...over,
});

describe('the subject', () => {
  it('is fixed, whatever anyone typed', () => {
    expect(buildCompOfferEmail(ctx()).subject).toBe('A complimentary bottle for you');
    expect(buildCompOfferEmail(ctx({ venueName: 'Evil\r\nBcc: x@y.z', toName: 'A\nB', item: 'X\r\nY' })).subject).toBe(COMP_OFFER_SUBJECT);
  });
});

describe('the words', () => {
  it('greet the person, say who is giving what, and how to claim it', () => {
    const { text } = buildCompOfferEmail(ctx());
    expect(text).toContain('Hi Gina Guest,');
    expect(text).toContain('Club A would like to give you 2 × Patron on the house.');
    expect(text).toContain('open the link below and tell them where you are');
    expect(text).toContain(LINK);
  });

  it('without a name, just "Hi,"', () => {
    expect(buildCompOfferEmail(ctx({ toName: null })).text.split('\n')[0]).toBe('Hi,');
    expect(buildCompOfferEmail(ctx({ toName: '   ' })).text.split('\n')[0]).toBe('Hi,');
  });

  it('name the event when the offer is for one', () => {
    expect(buildCompOfferEmail(ctx({ eventTitle: 'Halloween Night' })).text).toContain('on the house for Halloween Night.');
    expect(buildCompOfferEmail(ctx()).text).not.toContain(' for null');
  });

  it('say nothing is charged and the link works once', () => {
    const { text, html } = buildCompOfferEmail(ctx());
    expect(text).toContain('Nothing is charged.');
    expect(text).toContain('The link works once and stops working on');
    expect(html).toContain('Nothing is charged.');
  });

  it('put the link on a button and in the plain text', () => {
    const { html, text } = buildCompOfferEmail(ctx());
    expect(html).toContain(`href="${LINK}"`);
    expect(html).toContain('Claim your bottle');
    expect(text.split('\n')).toContain(LINK);
  });
});

describe('what a person typed', () => {
  it('is escaped in the HTML', () => {
    const { html } = buildCompOfferEmail(ctx({ toName: '<script>alert(1)</script>', venueName: 'A & B "Club"', eventTitle: '<b>Night</b>', item: "O'Brien <i>Gin</i>" }));
    expect(html).not.toContain('<script>');
    expect(html).not.toContain('<b>Night</b>');
    expect(html).not.toContain('<i>Gin</i>');
    expect(html).toContain('&lt;script&gt;');
    expect(html).toContain('A &amp; B &quot;Club&quot;');
  });

  it('is reduced to one line', () => {
    const { text } = buildCompOfferEmail(ctx({ toName: 'Gina\n\nGuest', venueName: 'Club\r\nA', item: 'Pa\ntron' }));
    expect(text).toContain('Hi Gina Guest,');
    expect(text).toContain('Club A would like to give you 2 × Pa tron on the house.');
  });
});

describe('the link', () => {
  it('must be https', () => {
    expect(() => buildCompOfferEmail(ctx({ link: 'http://bottlesupapp.com/claim/x' }))).toThrow();
    expect(() => buildCompOfferEmail(ctx({ link: 'javascript:alert(1)' }))).toThrow();
    expect(() => buildCompOfferEmail(ctx({ link: '' }))).toThrow();
  });

  it('is escaped in the HTML (an ampersand in it is &amp; there) and left as it is in the plain text', () => {
    const link = 'https://bottlesupapp.com/claim/' + 'a'.repeat(64) + '?a=1&b=2';
    const { html, text } = buildCompOfferEmail(ctx({ link }));
    expect(html).toContain(`href="${link.replace('&', '&amp;')}"`);
    expect(html).not.toContain('a=1&b=2');
    expect(text).toContain('a=1&b=2');
  });

  it('may not carry anything that breaks out of the attribute', () => {
    expect(() => buildCompOfferEmail(ctx({ link: 'https://x.example/a" onclick="x' }))).toThrow();
    expect(() => buildCompOfferEmail(ctx({ link: 'https://x.example/a b' }))).toThrow();
    expect(() => buildCompOfferEmail(ctx({ link: 'https://x.example/<a>' }))).toThrow();
  });
});

describe('the expiry', () => {
  it('is in the club\'s own time', () => {
    expect(expiryLabel('2026-11-25T02:00:00Z', 'America/Toronto')).toBe('Tuesday, November 24 at 9:00 PM EST');
    expect(expiryLabel('2026-11-25T02:00:00Z', 'America/Los_Angeles')).toBe('Tuesday, November 24 at 6:00 PM PST');
  });

  it('falls back to Toronto without a zone, and to UTC for a zone that is not real', () => {
    expect(expiryLabel('2026-11-25T02:00:00Z', null)).toContain('9:00 PM');
    expect(expiryLabel('2026-11-25T02:00:00Z', '')).toContain('9:00 PM');
    expect(expiryLabel('2026-11-25T02:00:00Z', 'Mars/Olympus')).toContain('2:00 AM');
    expect(expiryLabel('2026-11-25T02:00:00Z', 'Mars/Olympus')).toContain('UTC');
  });

  it('is empty when the time cannot be read, and the e-mail still says the link expires', () => {
    expect(expiryLabel('not a time', 'America/Toronto')).toBe('');
    expect(buildCompOfferEmail(ctx({ expiresAt: 'nope' })).text).toContain('The link works once and expires.');
  });

  it('is in the e-mail', () => {
    expect(buildCompOfferEmail(ctx()).text).toContain('stops working on Tuesday, November 24 at 9:00 PM EST.');
  });
});

describe('the gift', () => {
  it('is quantity times item, on one line', () => {
    expect(describeGift(1, 'Patron')).toBe('1 × Patron');
    expect(describeGift(12, '  Grey\nGoose ')).toBe('12 × Grey Goose');
  });
});
