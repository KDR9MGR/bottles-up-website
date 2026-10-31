// The e-mail that carries a temporary-staff identity code, as pure functions (no network, no Deno), so what lands in an inbox is tested.
//
// The code is six digits, checked before it gets here; business, venue and shift names are typed by users, so everything dynamic is HTML-escaped and
// the subject carries no dynamic text at all (so a name cannot inject a mail header).

import { describeWindow, escapeHtml, formatMoment, roleLabel } from './teamInvitationTemplate.ts';

export interface CodeEmailContext {
  code: string;
  role: string;
  orgName: string;
  venueName: string | null;
  eventTitle: string | null;
  shiftName: string | null;
  accessStartAt: string | null;
  accessEndAt: string | null;
  /** When the code stops working. */
  codeExpiresAt: string;
}

const oneLine = (value: string) => value.replace(/\s+/g, ' ').trim();

export const CODE_SUBJECT = 'Your BottlesUp Business code';

export function buildCodeEmail(ctx: CodeEmailContext): { subject: string; html: string; text: string } {
  const role = roleLabel(ctx.role);
  const org = oneLine(ctx.orgName);
  const where = [ctx.venueName, ctx.eventTitle].filter((v): v is string => !!v).map(oneLine).join(' · ');
  const window = describeWindow(ctx.accessStartAt, ctx.accessEndAt);
  const until = formatMoment(ctx.codeExpiresAt);

  const lines: [string, string][] = [['Role', role], ['Business', org]];
  if (where) lines.push(['Where', where]);
  if (ctx.shiftName) lines.push(['Shift', oneLine(ctx.shiftName)]);
  if (window) lines.push(['Access', window]);

  const html = `
    <div style="font-family: sans-serif; max-width: 480px; margin: 0 auto; padding: 24px; background: #0a0a0a; color: #fff; border-radius: 16px;">
      <h1 style="color: #f97316; font-size: 22px;">Your code</h1>
      <p>Type this code in the BottlesUp Business app to confirm it is you and start your temporary access.</p>
      <p style="text-align: center; font-size: 40px; letter-spacing: 8px; font-weight: bold; margin: 24px 0;">${escapeHtml(ctx.code)}</p>
      <p style="color: #ccc; text-align: center;">It works until ${escapeHtml(until)} (10 minutes).</p>
      <table style="width: 100%; border-collapse: collapse; margin: 16px 0; font-size: 14px;">
        ${lines.map(([k, v]) => `<tr><td style="padding: 4px 0; color: #ccc;">${escapeHtml(k)}</td><td style="padding: 4px 0; color: #ccc; text-align: right;">${escapeHtml(v)}</td></tr>`).join('\n        ')}
      </table>
      <p style="color: #999; font-size: 13px;">Never share this code. If you did not ask for it, ignore this e-mail: nobody can use your invitation link without it.</p>
    </div>
  `;

  const text = [
    'Type this code in the BottlesUp Business app to confirm it is you and start your temporary access:',
    '',
    ctx.code,
    '',
    `It works until ${until} (10 minutes).`,
    '',
    ...lines.map(([k, v]) => `${k}: ${v}`),
    '',
    'Never share this code. If you did not ask for it, ignore this e-mail: nobody can use your invitation link without it.',
  ].join('\n');

  return { subject: CODE_SUBJECT, html, text };
}
