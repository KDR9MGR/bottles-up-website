import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';
import { renderTemplate } from './helpers/renderTemplate';

// supabase/email-templates/recovery.html is pasted by hand into Supabase's "Reset Password" template (Authentication > Emails), so
// nothing else checks it. These tests read the file itself and render each variant the way Supabase will.

const TEMPLATE = readFileSync(resolve(__dirname, '../../supabase/email-templates/recovery.html'), 'utf8');

// The addresses the apps pass as `redirectTo` when they ask for a reset. Supabase hands the one it accepted back to the template as
// .RedirectTo, which is how the template tells the apps apart. They must match the apps and the Redirect URLs list exactly.
const BUSINESS = 'https://www.bottlesupapp.com/reset-password?app=business';
const USER = 'https://www.bottlesupapp.com/reset-password?app=user';
const HASH = 'a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c';

const render = (redirectTo: string) =>
  renderTemplate(TEMPLATE, { RedirectTo: redirectTo, TokenHash: HASH, Token: '483920', Email: 'sam@example.com', SiteURL: 'https://www.bottlesupapp.com' });

const hrefs = (html: string) => [...html.matchAll(/href="([^"]+)"/g)].map((m) => m[1]);
const buttonLink = (html: string) => hrefs(html)[0];

describe('recovery e-mail template: the file', () => {
  it('uses only what the renderer (and Supabase) understand, and every {{ if }} is closed', () => {
    expect(() => render(USER)).not.toThrow();
    const ifs = (TEMPLATE.match(/\{\{\s*if /g) ?? []).length;
    const ends = (TEMPLATE.match(/\{\{\s*end\s*\}\}/g) ?? []).length;
    expect(ifs).toBe(ends);
  });

  it('recognises each app by the exact address it sends as redirectTo', () => {
    expect(TEMPLATE).toContain(`eq .RedirectTo "${BUSINESS}"`);
    expect(TEMPLATE).toContain(`eq .RedirectTo "${USER}"`);
  });

  it('points at our own page with the token hash, not at Supabase\'s verify address (which mail scanners can spend)', () => {
    expect(TEMPLATE).toContain('https://www.bottlesupapp.com/reset-password?token_hash={{ .TokenHash }}&amp;type=recovery&amp;app=');
    expect(TEMPLATE).not.toContain('.ConfirmationURL');
    expect(TEMPLATE).not.toContain('.SiteURL');
  });

  it('is self-contained: no images, scripts or external stylesheets to be blocked', () => {
    expect(TEMPLATE).not.toMatch(/<img\b|<script\b|<link\b|@import|url\(/i);
  });

  it('declares language and both colour schemes, and stays small enough for Gmail (clips at 102 KB)', () => {
    expect(TEMPLATE).toContain('<html lang="en"');
    expect(TEMPLATE).toContain('name="color-scheme" content="light dark"');
    expect(Buffer.byteLength(TEMPLATE)).toBeLessThan(25_000);
  });
});

describe('recovery e-mail template: what each variant says', () => {
  it('BottlesUp Business: names the business app and tells the page to offer it', () => {
    const html = render(BUSINESS);
    expect(html).toContain('your BottlesUp Business account');
    expect(html).toContain('>Business</span>');
    expect(html).toContain('In BottlesUp Business, open');
    expect(buttonLink(html)).toBe(`https://www.bottlesupapp.com/reset-password?token_hash=${HASH}&amp;type=recovery&amp;app=business`);
    expect(html).not.toContain('app=user');
  });

  it('BottlesUp (customers): names the customer app', () => {
    const html = render(USER);
    expect(html).toContain('your BottlesUp account');
    expect(html).not.toContain('Business');
    expect(html).toContain('In BottlesUp, open');
    expect(buttonLink(html)).toBe(`https://www.bottlesupapp.com/reset-password?token_hash=${HASH}&amp;type=recovery&amp;app=user`);
  });

  it('anything else (the website, or a redirect Supabase did not accept) gets the neutral e-mail', () => {
    for (const other of ['https://www.bottlesupapp.com', '', 'https://evil.example/?app=business']) {
      const html = render(other);
      expect(html).toContain('your BottlesUp account');
      expect(html).not.toContain('Business');
      expect(html).toContain('In the app, open');
      expect(buttonLink(html)).toContain('&amp;app=web');
    }
  });

  it.each([BUSINESS, USER, 'https://www.bottlesupapp.com'])('every variant carries the code, the e-mail and the same link twice (%s)', (redirect) => {
    const html = render(redirect);
    expect(html.match(/483920/g)).toHaveLength(1);
    expect(html).toContain('<strong>sam@example.com</strong>');
    const links = hrefs(html);
    expect(links).toHaveLength(2);
    expect(links[1]).toBe(links[0]);
    expect(html).toContain('>Reset password</a>');
    expect(html).toContain('Didn&rsquo;t ask for this?');
    expect(html).toContain('Never share the code');
  });

  it.each([BUSINESS, USER, 'https://www.bottlesupapp.com'])('leaves no template syntax behind (%s)', (redirect) => {
    const html = render(redirect);
    expect(html).not.toMatch(/\{\{|\}\}/);
    expect(html.trimStart().startsWith('<!DOCTYPE html>')).toBe(true);
  });

  it('a raw & never appears inside the link: it is written &amp; as HTML requires', () => {
    for (const href of hrefs(render(USER))) expect(href).not.toMatch(/&(?!amp;)/);
  });
});
