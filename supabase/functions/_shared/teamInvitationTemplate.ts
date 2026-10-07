// The invitation email, as pure functions (no network, no Deno), so what ends up in someone's inbox is tested.
//
// Business, venue, shift and inviter names are typed by users, so they are untrusted. Everything dynamic is
// HTML-escaped, and the subject has line breaks stripped so a name cannot inject extra mail headers.

export interface InvitationEmailContext {
  inviteeEmail: string;
  role: string;
  orgName: string;
  venueName: string | null;
  eventTitle: string | null;
  shiftName: string | null;
  accessStartAt: string | null;
  accessEndAt: string | null;
  expiresAt: string;
  inviterName: string | null;
}

const ROLE_LABELS: Record<string, string> = {
  manager: 'Manager',
  server: 'Bottle Server',
  door: 'Door Staff',
  security: 'Security',
  verifier: 'Payment Verifier',
};

export function roleLabel(role: string): string {
  return ROLE_LABELS[role] ?? role;
}

export function escapeHtml(value: string): string {
  return value
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

// \s covers CR, LF and the Unicode line separators, so this also removes anything that could add a mail header.
const oneLine = (value: string) => value.replace(/\s+/g, ' ').trim();

// Venues are in Toronto today and the database has no per-venue time zone yet, so times are shown in Toronto
// time with the zone spelled out, rather than in the server's UTC, which nobody would read correctly.
const TIME_ZONE = 'America/Toronto';

export function formatMoment(iso: string): string {
  return new Intl.DateTimeFormat('en-CA', {
    timeZone: TIME_ZONE,
    month: 'short',
    day: 'numeric',
    hour: 'numeric',
    minute: '2-digit',
    timeZoneName: 'short',
  }).format(new Date(iso));
}

export function describeWindow(start: string | null, end: string | null): string | null {
  if (!start && !end) return null;
  if (start && end) return `${formatMoment(start)} to ${formatMoment(end)}`;
  if (start) return `From ${formatMoment(start)}`;
  return `Until ${formatMoment(end as string)}`;
}

export function buildInvitationEmail(ctx: InvitationEmailContext, link: string): { subject: string; html: string; text: string } {
  const role = roleLabel(ctx.role);
  const org = oneLine(ctx.orgName);
  const who = ctx.inviterName ? oneLine(ctx.inviterName) : org;
  const subject = `${who} invited you to join ${org} on BottlesUp as ${role}`.slice(0, 180);

  const where = [ctx.venueName, ctx.eventTitle].filter((v): v is string => !!v).map(oneLine);
  const window = describeWindow(ctx.accessStartAt, ctx.accessEndAt);
  const expires = formatMoment(ctx.expiresAt);

  const rows: [string, string][] = [['Role', role], ['Business', org]];
  if (where.length) rows.push([ctx.eventTitle ? 'Venue and event' : 'Venue', where.join(' · ')]);
  if (ctx.shiftName) rows.push(['Shift', oneLine(ctx.shiftName)]);
  rows.push(['Access', window ?? 'Ongoing until removed']);

  const html = `
    <div style="font-family: sans-serif; max-width: 480px; margin: 0 auto; padding: 24px; background: #0a0a0a; color: #fff; border-radius: 16px;">
      <h1 style="color: #f97316; font-size: 22px;">You've been invited to join a team</h1>
      <p><strong>${escapeHtml(who)}</strong> invited you to join <strong>${escapeHtml(org)}</strong> on BottlesUp as <strong>${escapeHtml(role)}</strong>.</p>
      <table style="width: 100%; border-collapse: collapse; margin: 16px 0; font-size: 14px;">
        ${rows.map(([k, v]) => `<tr><td style="padding: 4px 0; color: #ccc;">${escapeHtml(k)}</td><td style="padding: 4px 0; color: #ccc; text-align: right;">${escapeHtml(v)}</td></tr>`).join('\n        ')}
      </table>
      <div style="text-align: center; margin: 24px 0;">
        <a href="${escapeHtml(link)}" style="display: inline-block; background: #f97316; color: #000; font-weight: bold; padding: 12px 28px; border-radius: 999px; text-decoration: none;">
          Accept invitation
        </a>
      </div>
      <p style="color: #999; font-size: 13px;">Sign in or create an account with <strong>${escapeHtml(ctx.inviteeEmail)}</strong> to accept. This link is personal to you and works until ${escapeHtml(expires)}. If you were not expecting it, you can ignore this email.</p>
    </div>
  `;

  const text = [
    `${who} invited you to join ${org} on BottlesUp as ${role}.`,
    '',
    ...rows.map(([k, v]) => `${k}: ${v}`),
    '',
    `Accept the invitation: ${link}`,
    '',
    `Sign in or create an account with ${ctx.inviteeEmail} to accept. This link is personal to you and works until ${expires}.`,
    'If you were not expecting it, you can ignore this email.',
  ].join('\n');

  return { subject, html, text };
}
