import { describe, expect, it } from 'vitest';
import { bookingLink, DEFAULT_SITE_URL, isLive, linkNote, qrFileName, siteOrigin } from './bookingLink';

describe('the address links point at', () => {
  it('uses the configured site when it is a plain https address', () => {
    expect(siteOrigin('https://staging.bottlesupapp.com')).toBe('https://staging.bottlesupapp.com');
    expect(siteOrigin('  https://www.example.com  ')).toBe('https://www.example.com');
  });

  it('keeps only the origin: a path, query or trailing slash is dropped', () => {
    expect(siteOrigin('https://www.example.com/')).toBe('https://www.example.com');
    expect(siteOrigin('https://www.example.com/some/path?x=1#y')).toBe('https://www.example.com');
  });

  it.each([
    undefined, null, '', '   ', 'http://www.example.com', 'ftp://www.example.com', 'javascript:alert(1)', 'not a url',
    'https://user:pass@www.example.com', 'https://localhost', '//www.example.com', 'www.example.com',
  ])('ignores %j and falls back to the real site, so a configuration mistake never reaches a printed QR code', (value) => {
    expect(siteOrigin(value as string | null | undefined)).toBe(DEFAULT_SITE_URL);
  });
});

describe('the booking link', () => {
  const site = 'https://www.bottlesupapp.com';

  it('uses the venue slug', () => {
    expect(bookingLink(site, { id: 'a1b2', slug: 'club-noir' })).toBe('https://www.bottlesupapp.com/venues/club-noir');
  });

  it('falls back to the venue id when there is no slug, or when the slug is not a clean one', () => {
    expect(bookingLink(site, { id: 'a1b2', slug: null })).toBe('https://www.bottlesupapp.com/venues/a1b2');
    expect(bookingLink(site, { id: 'a1b2', slug: '' })).toBe('https://www.bottlesupapp.com/venues/a1b2');
    expect(bookingLink(site, { id: 'a1b2', slug: 'bad slug/../x' })).toBe('https://www.bottlesupapp.com/venues/a1b2');
    expect(bookingLink(site, { id: 'a1b2', slug: '-leading-dash' })).toBe('https://www.bottlesupapp.com/venues/a1b2');
  });

  it('never produces a double slash, whatever the site ends with', () => {
    expect(bookingLink('https://www.bottlesupapp.com/', { id: 'x', slug: 'club' })).toBe('https://www.bottlesupapp.com/venues/club');
  });

  it('escapes anything that could change the meaning of the address', () => {
    const link = bookingLink(site, { id: 'a b?c#d', slug: null });
    expect(link).toBe('https://www.bottlesupapp.com/venues/a%20b%3Fc%23d');
    expect(new URL(link).pathname).toBe('/venues/a%20b%3Fc%23d');
    expect(new URL(link).search).toBe('');
    expect(new URL(link).hash).toBe('');
  });
});

describe('whether the link works yet', () => {
  it('only a published venue has a working link (the public page shows nothing else)', () => {
    expect(isLive('published')).toBe(true);
    for (const status of ['draft', 'archived', '', 'Published']) expect(isLive(status)).toBe(false);
  });

  it('says so in words', () => {
    expect(linkNote('published')).toBe('Guests can book through this link now.');
    expect(linkNote('draft')).toContain('starts working when the venue goes live');
  });
});

describe('the QR file name', () => {
  it.each([
    ['Club Noir', 'club-noir-booking-qr.png'],
    ['Club Ñoche & Bar', 'club-noche-bar-booking-qr.png'],
    ['  --The  Roof!!  ', 'the-roof-booking-qr.png'],
    ['🔥🔥', 'venue-booking-qr.png'],
    ['', 'venue-booking-qr.png'],
    ['../../etc/passwd', 'etc-passwd-booking-qr.png'],
  ])('%j -> %s', (name, file) => expect(qrFileName(name)).toBe(file));

  it('is always a plain, short file name', () => {
    const file = qrFileName('x'.repeat(500));
    expect(file).toMatch(/^[a-z0-9-]+-booking-qr\.png$/);
    expect(file.length).toBeLessThan(90);
  });
});
