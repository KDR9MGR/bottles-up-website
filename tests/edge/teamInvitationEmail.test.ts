import { describe, expect, it } from 'vitest';
import {
  buildInvitationEmail, describeWindow, escapeHtml, formatMoment, roleLabel, type InvitationEmailContext,
} from '../../supabase/functions/_shared/teamInvitationTemplate.ts';

const ctx = (over: Partial<InvitationEmailContext> = {}): InvitationEmailContext => ({
  inviteeEmail: 'door@club.example',
  role: 'door',
  orgName: 'Club Co',
  venueName: 'Club A',
  eventTitle: null,
  shiftName: null,
  accessStartAt: null,
  accessEndAt: null,
  expiresAt: '2026-10-20T15:00:00Z',
  inviterName: 'Olivia Owner',
  ...over,
});
const LINK = 'https://www.bottlesupapp.com/accept-invite?token=abc123';

describe('what the invited person receives', () => {
  it('says who invited them, to what, and in which role', () => {
    const { subject, html, text } = buildInvitationEmail(ctx(), LINK);
    expect(subject).toBe('Olivia Owner invited you to join Club Co on BottlesUp as Door Staff');
    expect(html).toContain('Door Staff');
    expect(html).toContain('Club Co');
    expect(text).toContain('Olivia Owner invited you to join Club Co on BottlesUp as Door Staff.');
  });

  it('contains the accept link in both the html and the plain-text version', () => {
    const { html, text } = buildInvitationEmail(ctx(), LINK);
    expect(html).toContain(`href="${LINK}"`);
    expect(text).toContain(`Accept the invitation: ${LINK}`);
  });

  it('names the address the invitation is for, so a forwarded email is understood', () => {
    expect(buildInvitationEmail(ctx(), LINK).html).toContain('door@club.example');
  });

  it('shows the venue, event and shift only when there are some', () => {
    const plain = buildInvitationEmail(ctx({ venueName: null }), LINK).text;
    expect(plain).not.toContain('Venue');
    const full = buildInvitationEmail(ctx({ venueName: 'Club A', eventTitle: 'Friday Night', shiftName: 'Doors 9pm' }), LINK).text;
    expect(full).toContain('Venue and event: Club A · Friday Night');
    expect(full).toContain('Shift: Doors 9pm');
  });

  it('falls back to the business name when the inviter has no name', () => {
    expect(buildInvitationEmail(ctx({ inviterName: null }), LINK).subject).toBe('Club Co invited you to join Club Co on BottlesUp as Door Staff');
  });

  it('says when the access is temporary and when it ends, in Toronto time with the zone shown', () => {
    const { text } = buildInvitationEmail(ctx({ accessStartAt: '2026-10-10T23:00:00Z', accessEndAt: '2026-10-11T07:00:00Z' }), LINK);
    expect(text).toMatch(/Access: Oct 10, 7:00 p\.m\. EDT to Oct 11, 3:00 a\.m\. EDT/);
  });

  it('says access is ongoing when there is no window', () => {
    expect(buildInvitationEmail(ctx(), LINK).text).toContain('Access: Ongoing until removed');
  });

  it('says when the link stops working', () => {
    expect(buildInvitationEmail(ctx(), LINK).text).toMatch(/works until Oct 20, 11:00 a\.m\. EDT/);
  });
});

describe('names typed by users cannot inject markup or headers', () => {
  const evil = '<script>alert(1)</script>"><img src=x onerror=alert(2)>';

  it.each([
    ['business', { orgName: evil }],
    ['venue', { venueName: evil }],
    ['event', { eventTitle: evil }],
    ['shift', { shiftName: evil }],
    ['inviter', { inviterName: evil }],
  ] as const)('escapes the %s name', (_n, over) => {
    const { html } = buildInvitationEmail(ctx(over), LINK);
    expect(html).not.toContain('<script>');
    expect(html).not.toContain('<img src=x');
    expect(html).toContain('&lt;script&gt;');
  });

  it('escapes the link too, in case it ever carries a quote', () => {
    const { html } = buildInvitationEmail(ctx(), 'https://x.example/a?token="><script>1</script>');
    expect(html).not.toContain('<script>1</script>');
  });

  it('keeps line breaks out of the subject (no extra mail headers)', () => {
    const { subject } = buildInvitationEmail(ctx({ orgName: 'Club\r\nBcc: victim@example.com', inviterName: 'A\nB' }), LINK);
    expect(subject).not.toMatch(/[\r\n]/);
  });

  it('keeps the subject to a sane length', () => {
    expect(buildInvitationEmail(ctx({ orgName: 'x'.repeat(500) }), LINK).subject.length).toBeLessThanOrEqual(180);
  });
});

describe('helpers', () => {
  it('escapes the five dangerous characters', () => {
    expect(escapeHtml(`<a href="x">'&'</a>`)).toBe('&lt;a href=&quot;x&quot;&gt;&#39;&amp;&#39;&lt;/a&gt;');
  });
  it('labels roles and passes an unknown one through', () => {
    expect(roleLabel('verifier')).toBe('Payment Verifier');
    expect(roleLabel('captain')).toBe('captain');
  });
  it('describes a window with only one end', () => {
    expect(describeWindow('2026-10-10T23:00:00Z', null)).toMatch(/^From Oct 10/);
    expect(describeWindow(null, '2026-10-11T07:00:00Z')).toMatch(/^Until Oct 11/);
    expect(describeWindow(null, null)).toBeNull();
  });
  it('shows winter times as EST, not EDT', () => {
    expect(formatMoment('2026-12-10T23:00:00Z')).toMatch(/EST/);
  });
});
