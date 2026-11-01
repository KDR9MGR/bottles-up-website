// The e-mail that carries a report PDF, as pure functions (no network, no Deno), so what lands in an inbox is tested.
//
// Nothing a person typed ends up here: the business, club and event names come from the database, the night is a checked date, and the subject is fixed, so a name cannot inject a
// mail header and the application cannot be used to write arbitrary mail. Everything dynamic is HTML-escaped.

import { escapeHtml } from './teamInvitationTemplate.ts';

export type ReportKind = 'owner_combined' | 'venue_night' | 'organizer_sales';

export const REPORT_KINDS: readonly ReportKind[] = ['owner_combined', 'venue_night', 'organizer_sales'];

export interface ReportEmailContext {
  kind: ReportKind;
  orgName: string;
  venueName: string | null;
  eventTitle: string | null;
  /** A night as YYYY-MM-DD (checked by the database), or the event's id for an organizer's report. */
  ref: string;
  /** The signed-in person who sent it. */
  senderEmail: string;
  filename: string;
}

const oneLine = (value: string) => value.replace(/\s+/g, ' ').trim();

export const REPORT_SUBJECT = 'A report from BottlesUp Business';

/** "Friday, October 30, 2026" from "2026-10-30", with no time zone shifting it. */
export function nightLabel(ref: string): string {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(ref);
  if (!m) return ref;
  const date = new Date(Date.UTC(Number(m[1]), Number(m[2]) - 1, Number(m[3])));
  return date.toLocaleDateString('en-US', { timeZone: 'UTC', weekday: 'long', year: 'numeric', month: 'long', day: 'numeric' });
}

/** What the report is, in one line. */
export function describeReport(ctx: Pick<ReportEmailContext, 'kind' | 'orgName' | 'venueName' | 'eventTitle' | 'ref'>): string {
  const org = oneLine(ctx.orgName);
  if (ctx.kind === 'owner_combined') return `${org}: the combined report for every club, ${nightLabel(ctx.ref)}`;
  if (ctx.kind === 'venue_night') return `${ctx.venueName ? oneLine(ctx.venueName) : org}: the night report, ${nightLabel(ctx.ref)}`;
  return `${org}: the event report${ctx.eventTitle ? ` for ${oneLine(ctx.eventTitle)}` : ''}`;
}

export function buildReportEmail(ctx: ReportEmailContext): { subject: string; html: string; text: string } {
  const what = describeReport(ctx);
  const sender = oneLine(ctx.senderEmail);
  const file = oneLine(ctx.filename);

  const html = `
    <div style="font-family: sans-serif; max-width: 480px; margin: 0 auto; padding: 24px; background: #0a0a0a; color: #fff; border-radius: 16px;">
      <h1 style="color: #f97316; font-size: 22px;">A report for you</h1>
      <p>${escapeHtml(what)}.</p>
      <p>It is attached as a PDF (${escapeHtml(file)}).</p>
      <p style="color: #999; font-size: 12px;">Sent by ${escapeHtml(sender)} from BottlesUp Business, because your address is on the report list. If you were not expecting this, you can ignore it.</p>
    </div>`;
  const text = [
    'A report for you',
    '',
    `${what}.`,
    `It is attached as a PDF (${file}).`,
    '',
    `Sent by ${sender} from BottlesUp Business, because your address is on the report list. If you were not expecting this, you can ignore it.`,
  ].join('\n');
  return { subject: REPORT_SUBJECT, html, text };
}
