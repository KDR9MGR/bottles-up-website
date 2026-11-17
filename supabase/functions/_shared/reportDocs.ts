// The four reports as DOCUMENTS (a title, a line saying who and when, whether it is final, and sections of label/value rows), built from what the database returns, for the server to
// turn into a PDF. The vendor app builds the same documents on the phone (lib/features/night/logic/night_rules.dart, consolidated_report.dart, sales_source/logic/sales_source_rules.dart and
// venue_access/logic/access_rules.dart); THIS FILE MUST SAY THE SAME THING. tests/fixtures/report_docs/*.json holds inputs with the documents the app builds from them, and both the app's test
// and this one's must produce exactly those, so neither can change without the other noticing.
//
// Two honest differences from the phone: times are shown in the club's time zone (the phone uses its own), and a PDF made here is checked for a usable file name.
// Everything here is a pure function: no network, no clock, no Deno.

export interface ReportRow {
  label: string;
  value: string;
  strong: boolean;
}
export interface ReportSection {
  title: string;
  rows: ReportRow[];
}
export interface ReportDocument {
  title: string;
  subtitle: string;
  statusLine: string;
  sections: ReportSection[];
  fileName: string;
}

const row = (label: string, value: string, strong = false): ReportRow => ({ label, value, strong });
const section = (title: string, rows: ReportRow[]): ReportSection => ({ title, rows });

// ---------------------------------------------------------------------------------------------------------------------------------------------------------------------
// Reading what the database sends (forgiving, like the app: a missing or odd value is a default, never a crash)
// ---------------------------------------------------------------------------------------------------------------------------------------------------------------------

type Json = Record<string, unknown>;
const isMap = (v: unknown): v is Json => typeof v === 'object' && v !== null && !Array.isArray(v);

export function opsStr(m: Json | null | undefined, key: string): string | null {
  const v = m?.[key];
  if (v === null || v === undefined) return null;
  const s = String(v);
  return s === '' ? null : s;
}

export function opsInt(m: Json | null | undefined, key: string): number {
  const v = m?.[key];
  if (typeof v === 'number') return Math.trunc(v);
  if (typeof v === 'string' && /^[+-]?\d+$/.test(v)) return Number.parseInt(v, 10);
  return 0;
}

export const opsBool = (m: Json | null | undefined, key: string): boolean => m?.[key] === true;

/** A timestamp the database sent ("2026-11-18T03:52:47.697772+05:30"), or null. */
export function opsTime(m: Json | null | undefined, key: string): Date | null {
  const v = m?.[key];
  if (typeof v !== 'string') return null;
  const t = Date.parse(v);
  return Number.isNaN(t) ? null : new Date(t);
}

// ---------------------------------------------------------------------------------------------------------------------------------------------------------------------
// Words and figures (the app's own formatting, so a figure reads the same on the phone and in the PDF)
// ---------------------------------------------------------------------------------------------------------------------------------------------------------------------

/** "$1,234.50" from cents. Mirrors the app's formatDollars exactly, including how it treats a negative amount. */
export function formatDollars(cents: number): string {
  const whole = Math.trunc(cents / 100);
  const frac = String(((cents % 100) + 100) % 100).padStart(2, '0');
  const grouped = String(whole).replace(/\B(?=(\d{3})+(?!\d))/g, ',');
  return `$${grouped}.${frac}`;
}

const WEEKDAYS = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/** "Saturday Oct 10" from "2026-10-10". A date this cannot read is returned as it came. */
export function formatNight(iso: string): string {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(iso);
  if (!m) return iso;
  const y = Number(m[1]);
  const mo = Number(m[2]);
  const d = Number(m[3]);
  const dt = new Date(Date.UTC(y, mo - 1, d));
  if (dt.getUTCFullYear() !== y || dt.getUTCMonth() !== mo - 1 || dt.getUTCDate() !== d) return iso;
  return `${WEEKDAYS[(dt.getUTCDay() + 6) % 7]} ${MONTHS[mo - 1]} ${d}`;
}

const SECURITY_KINDS: Record<string, string> = {
  fight: 'Fight', medical: 'Medical', intoxicated: 'Intoxicated guest', theft: 'Theft', crowd: 'Crowd', other: 'Other', harassment: 'Harassment', weapon: 'Weapon', property: 'Property damage',
};
export const kindLabel = (id: string): string => SECURITY_KINDS[id] ?? id;

const slug = (s: string): string => s.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '');

// Times, in a time zone. English, 24-hour or 12-hour as the app writes them.
function parts(d: Date, timeZone: string, opts: Intl.DateTimeFormatOptions): Record<string, string> {
  const out: Record<string, string> = {};
  for (const p of new Intl.DateTimeFormat('en-US', { timeZone, ...opts }).formatToParts(d)) out[p.type] = p.value;
  return out;
}
/** "22:05" (the app's HH:mm). */
export function timeOfDay(d: Date, timeZone: string): string {
  const p = parts(d, timeZone, { hour: '2-digit', minute: '2-digit', hourCycle: 'h23' });
  return `${p.hour}:${p.minute}`;
}
/** "Sat Nov 14, 22:00" (the app's EEE MMM d, HH:mm). */
export function whenLabel(d: Date, timeZone: string): string {
  const p = parts(d, timeZone, { weekday: 'short', month: 'short', day: 'numeric' });
  return `${p.weekday} ${p.month} ${p.day}, ${timeOfDay(d, timeZone)}`;
}
/** "10:00 PM" (the app's h:mm a). */
export function clock12(d: Date, timeZone: string): string {
  const p = parts(d, timeZone, { hour: 'numeric', minute: '2-digit', hour12: true });
  return `${p.hour}:${p.minute} ${p.dayPeriod}`;
}
/** "Nov 14, 10:00 PM" (the app's MMM d, h:mm a). */
export function atLabel(d: Date, timeZone: string): string {
  const p = parts(d, timeZone, { month: 'short', day: 'numeric' });
  return `${p.month} ${p.day}, ${clock12(d, timeZone)}`;
}

// ---------------------------------------------------------------------------------------------------------------------------------------------------------------------
// 1. The club's night report (night_report; the manager's and the owner's "full" view)
// ---------------------------------------------------------------------------------------------------------------------------------------------------------------------

interface NightException {
  key: string;
  label: string;
  count: number;
  isChecklist: boolean;
}

function parseExceptions(list: unknown): NightException[] {
  if (!Array.isArray(list)) return [];
  const out: NightException[] = [];
  for (const e of list) {
    if (!isMap(e)) continue;
    const key = opsStr(e, 'key');
    if (key === null) continue;
    out.push({ key, label: opsStr(e, 'label') ?? key, count: opsInt(e, 'count'), isChecklist: e.kind === 'checklist' });
  }
  return out;
}

export interface NightReport {
  view: string;
  isFinal: boolean;
  venueName: string;
  night: string;
  generatedAt: Date | null;
  closedAt: Date | null;
  closedByName: string | null;
  exceptions: NightException[];
  exceptionsNote: string | null;
  sections: Record<string, Json>;
}

const NIGHT_SECTIONS = ['bookings', 'payments', 'cash', 'flags', 'bottles', 'service', 'security'];

export function parseNightReport(r: unknown): NightReport | null {
  if (!isMap(r)) return null;
  const night = opsStr(r, 'business_night');
  if (night === null) return null;
  const sections: Record<string, Json> = {};
  for (const n of NIGHT_SECTIONS) if (isMap(r[n])) sections[n] = r[n] as Json;
  return {
    view: opsStr(r, 'view') ?? 'full',
    isFinal: opsBool(r, 'final'),
    venueName: opsStr(r, 'venue_name') ?? 'Club',
    night,
    generatedAt: opsTime(r, 'generated_at'),
    closedAt: opsTime(r, 'closed_at'),
    closedByName: opsStr(r, 'closed_by_name'),
    exceptions: parseExceptions(r.exceptions),
    exceptionsNote: opsStr(r, 'exceptions_note'),
    sections,
  };
}

const viewLabel = (view: string): string => (view === 'finance' ? 'Finance report' : view === 'security' ? 'Security report' : 'Nightly report');

export function buildNightDocument(r: NightReport, timeZone: string): ReportDocument {
  const n = (m: Json | undefined, key: string) => String(opsInt(m, key));
  const d = (m: Json | undefined, key: string) => formatDollars(opsInt(m, key));
  const time = (t: Date | null) => (t === null ? '' : timeOfDay(t, timeZone));
  const sections: ReportSection[] = [];
  const b = r.sections.bookings;
  const p = r.sections.payments;
  const c = r.sections.cash;
  const f = r.sections.flags;
  const bt = r.sections.bottles;
  const sv = r.sections.service;
  const sec = r.sections.security;

  if (b) {
    sections.push(section('Tables and guests', [row('Tables booked', n(b, 'count')), row('Guests', n(b, 'guests')), row('Guests seated (tables)', n(b, 'seated'))]));
    sections.push(section('Sales', [row('Booked total', d(b, 'total_cents'), true), row('Paid so far', d(b, 'paid_cents')), row('Balance still due', d(b, 'balance_cents')), row('Discounts', d(b, 'discount_cents'))]));
  }
  if (p) {
    sections.push(section('Payments recorded at the club', [
      row('Payments', n(p, 'count')),
      row('Collected', d(p, 'collected_cents'), true),
      row('Cash', d(p, 'cash_cents')),
      row('Debit', d(p, 'debit_cents')),
      row('Credit', d(p, 'credit_cents')),
      row('Card part of split payments', d(p, 'split_card_cents')),
      row('Tax', d(p, 'tax_cents')),
      row('Gratuity', d(p, 'gratuity_cents')),
      row('Not yet verified', n(p, 'unverified')),
      row('Disputed by the guest', n(p, 'disputed')),
      row('Without a receipt photo', n(p, 'no_receipt')),
      row('Corrections (each counted once)', n(p, 'corrections')),
    ]));
  }
  if (c) {
    sections.push(section('Cash', [
      row('Handovers', n(c, 'handovers')),
      row('Handed in', d(c, 'claimed_cents')),
      row('Counted', d(c, 'counted_cents'), true),
      row('Shortages', d(c, 'shortage_cents')),
      row('Overages', d(c, 'overage_cents')),
      row('Waiting to be counted', n(c, 'waiting')),
      row('Still held by staff', d(c, 'held_cents')),
    ]));
  }
  if (f) {
    const by = f.by_resolution;
    const rows = [row('Flagged', n(f, 'raised')), row('Still open', n(f, 'open')), row('Resolved', n(f, 'resolved'))];
    if (isMap(by)) for (const [k, v] of Object.entries(by)) rows.push(row(`Resolved as ${k.replaceAll('_', ' ')}`, String(v)));
    sections.push(section('Flagged payments', rows));
  }
  if (bt) {
    sections.push(section('Bottle orders', [
      row('Bottles ordered', n(bt, 'lines')),
      row('Value', d(bt, 'value_cents'), true),
      row('Served', n(bt, 'served')),
      row('In progress', n(bt, 'in_progress')),
      row('Waiting to be prepared', n(bt, 'awaiting')),
      row('Cancelled', n(bt, 'cancelled')),
      row('To be paid at the club', n(bt, 'due_at_venue')),
    ]));
  }
  if (sv) {
    sections.push(section('Requests from tables', [row('Requests', n(sv, 'total')), row('Completed', n(sv, 'completed')), row('Escalated', n(sv, 'escalated')), row('Still open', n(sv, 'open'))]));
  }
  if (sec) {
    const alerts = isMap(sec.alerts) ? sec.alerts : {};
    const tasks = isMap(sec.tasks) ? sec.tasks : {};
    const kinds = alerts.by_kind;
    const incidents = Array.isArray(sec.incidents) ? sec.incidents : [];
    const rows = [row('Alerts', n(alerts, 'total')), row('Urgent', n(alerts, 'urgent')), row('Escalated', n(alerts, 'escalated')), row('Not resolved', n(alerts, 'unresolved'))];
    if (isMap(kinds)) for (const [k, v] of Object.entries(kinds)) rows.push(row(`  ${kindLabel(k)}`, String(v)));
    rows.push(row('Tasks', n(tasks, 'total')), row('Tasks done', n(tasks, 'done')), row('Incident reports', String(incidents.length)));
    for (const i of incidents) {
      if (isMap(i)) rows.push(row(`  ${kindLabel(i.kind === null || i.kind === undefined ? 'other' : String(i.kind))} · ${i.location === null || i.location === undefined ? '' : String(i.location)}`, i.status === 'reviewed' ? 'Reviewed' : 'Not reviewed'));
    }
    sections.push(section('Security', rows));
  }
  if (r.isFinal && r.exceptions.length > 0) {
    const rows = r.exceptions.map((e) => row(e.isChecklist ? 'Not ticked' : e.label, e.isChecklist ? e.label : String(e.count)));
    if (r.exceptionsNote !== null) rows.push(row('Reason given', r.exceptionsNote));
    sections.push(section('Closed with exceptions', rows));
  }

  const status = r.isFinal
    ? `FINAL · closed${r.closedAt === null ? '' : ` ${time(r.closedAt)}`}${r.closedByName === null ? '' : ` by ${r.closedByName}`}`
    : `PRELIMINARY · figures as of ${time(r.generatedAt)}; not final until the night is closed`;
  const s = slug(r.venueName);
  return {
    title: viewLabel(r.view),
    subtitle: `${r.venueName} · ${formatNight(r.night)}`,
    statusLine: status,
    sections,
    fileName: `${s === '' ? 'club' : s}-${r.night}-${r.view}-${r.isFinal ? 'final' : 'preliminary'}.pdf`,
  };
}

// ---------------------------------------------------------------------------------------------------------------------------------------------------------------------
// 2. The sales added to the club's night report (night_sales_sources): what BottlesUp recorded, beside what the club reported, never added together
// ---------------------------------------------------------------------------------------------------------------------------------------------------------------------

const SALES_SOURCES: Record<string, string> = { entries: 'BottlesUp entries', upload: 'Closing report upload' };
const CLOSING_STATUS: Record<string, string> = { submitted: 'Waiting to be checked', reviewed: 'Checked', rejected: 'Not accepted', superseded: 'Replaced by a newer report' };

const sourcesFooter = 'The two are never added together. Venue-reported sales are the club\'s own end-of-night figure, not live bar sales.';
const smallerThanRecordedText = 'This report is smaller than what BottlesUp recorded for the night, so it cannot include all of it. Check it before accepting.';
const noReportYetText = 'No closing report has been sent for this night.';

function salesInt(v: unknown): number | null {
  if (typeof v === 'number') return Math.trunc(v);
  if (typeof v === 'string' && /^[+-]?\d+$/.test(v)) return Number.parseInt(v, 10);
  return null;
}
function salesTime(v: unknown): Date | null {
  if (typeof v !== 'string') return null;
  const t = Date.parse(v);
  return Number.isNaN(t) ? null : new Date(t);
}

export interface NightSales {
  night: string;
  source: string;
  sourceLabel: string;
  recorded: { label: string; basis: string; gross: number; discount: number; refund: number; net: number; collected: number; unpaid: number; asOf: Date | null };
  reported: null | {
    label: string; basis: string; status: string; periodStart: Date | null; periodEnd: Date | null; gross: number; discount: number; refund: number; net: number;
    includesBottlesUp: boolean; barAndOther: number; smallerThanRecorded: boolean; submittedAt: Date | null; reviewedAt: Date | null; verification: string;
  };
}

export function parseNightSales(j: unknown): NightSales | null {
  if (!isMap(j)) return null;
  const source = typeof j.source === 'string' && j.source in SALES_SOURCES ? j.source : null;
  const r = j.recorded;
  if (source === null || !isMap(r) || typeof j.business_night !== 'string') return null;
  const str = (v: unknown, fallback: string) => (typeof v === 'string' ? v : fallback);
  const recorded = {
    label: str(r.label, 'Recorded sales'),
    basis: str(r.basis, ''),
    gross: salesInt(r.gross_cents) ?? 0,
    discount: salesInt(r.discount_cents) ?? 0,
    refund: salesInt(r.refund_cents) ?? 0,
    net: salesInt(r.net_cents) ?? 0,
    collected: salesInt(r.collected_cents) ?? 0,
    unpaid: salesInt(r.unpaid_cents) ?? 0,
    asOf: salesTime(r.as_of),
  };
  let reported: NightSales['reported'] = null;
  const v = j.venue_reported;
  if (isMap(v)) {
    const status = typeof v.status === 'string' && v.status in CLOSING_STATUS ? v.status : null;
    if (status !== null) {
      reported = {
        label: str(v.label, 'Venue-reported sales'),
        basis: str(v.basis, ''),
        status,
        periodStart: salesTime(v.period_start),
        periodEnd: salesTime(v.period_end),
        gross: salesInt(v.gross_cents) ?? 0,
        discount: salesInt(v.discount_cents) ?? 0,
        refund: salesInt(v.refund_cents) ?? 0,
        net: salesInt(v.net_cents) ?? 0,
        includesBottlesUp: v.includes_bottlesup === true,
        barAndOther: salesInt(v.bar_and_other_cents) ?? 0,
        smallerThanRecorded: v.smaller_than_recorded === true,
        submittedAt: salesTime(v.submitted_at),
        reviewedAt: salesTime(v.reviewed_at),
        verification: str(v.verification, CLOSING_STATUS[status]),
      };
    }
  }
  return { night: j.business_night, source, sourceLabel: str(j.source_label, SALES_SOURCES[source]), recorded, reported };
}

/** The night's report with the labelled sales added at the end. Without sales (the server could not read them) the report is returned unchanged. */
export function documentWithSales(doc: ReportDocument, sales: NightSales | null, timeZone: string): ReportDocument {
  if (sales === null) return doc;
  const at = (t: Date | null) => (t === null ? '' : atLabel(t, timeZone));
  const recordedRows: ReportRow[] = [
    row('Booked, before discounts', formatDollars(sales.recorded.gross)),
    row('Discounts', formatDollars(sales.recorded.discount)),
    row('Refunds paid out', formatDollars(sales.recorded.refund)),
    row('Net of refunds', formatDollars(sales.recorded.net), true),
    row('Collected', formatDollars(sales.recorded.collected)),
    row('Not yet collected', formatDollars(sales.recorded.unpaid)),
    row('Worked out', sales.recorded.asOf === null ? 'just now' : at(sales.recorded.asOf)),
  ];
  const extra: ReportSection[] = [];
  extra.push(section(sales.recorded.label, [...(sales.recorded.basis !== '' ? [row('What this is', sales.recorded.basis)] : []), ...recordedRows]));
  const rep = sales.reported;
  if (rep !== null) {
    const lines: ReportRow[] = [];
    if (rep.periodStart !== null && rep.periodEnd !== null) lines.push(row('Period', `${clock12(rep.periodStart, timeZone)} to ${clock12(rep.periodEnd, timeZone)}`));
    lines.push(
      row('Gross', formatDollars(rep.gross)),
      row('Discounts', formatDollars(rep.discount)),
      row('Refunds', formatDollars(rep.refund)),
      row('Net', formatDollars(rep.net), true),
      row('Includes what BottlesUp recorded', rep.includesBottlesUp ? 'Yes' : 'No'),
    );
    if (rep.includesBottlesUp) lines.push(row('Bar and other, without BottlesUp\'s', formatDollars(rep.barAndOther), true));
    lines.push(row('Sent', at(rep.submittedAt)), row('Checked', rep.status === 'submitted' ? 'Waiting to be checked' : `${rep.verification}${rep.reviewedAt === null ? '' : `, ${at(rep.reviewedAt)}`}`));
    extra.push(section(rep.label, [...(rep.basis !== '' ? [row('What this is', rep.basis)] : []), ...lines, ...(rep.smallerThanRecorded ? [row('Check this report', smallerThanRecordedText, true)] : [])]));
  }
  if (sales.source === 'upload' && rep === null) extra.push(section('Venue-reported sales', [row('Closing report', noReportYetText)]));
  extra.push(section('Reading the sales', [row('This club\'s source', sales.sourceLabel), row('Note', sourcesFooter)]));
  return { ...doc, sections: [...doc.sections, ...extra] };
}

// ---------------------------------------------------------------------------------------------------------------------------------------------------------------------
// 3. The owner's combined report (owner_night_report)
// ---------------------------------------------------------------------------------------------------------------------------------------------------------------------

export interface ConsolidatedReport {
  orgName: string;
  night: string;
  generatedAt: Date | null;
  venuesTotal: number;
  venuesFinal: number;
  currency: string | null;
  currencyMixed: boolean;
  currencies: string[];
  totals: Record<string, number> | null;
  venues: { venueId: string; venueName: string; currencies: string[]; report: NightReport }[];
}

/** Null when the answer cannot be trusted: no night, a club whose report cannot be read, or a club count that does not match the clubs sent. */
export function parseConsolidatedReport(r: unknown): ConsolidatedReport | null {
  if (!isMap(r)) return null;
  const night = opsStr(r, 'business_night');
  if (night === null) return null;
  const raw = r.venues;
  if (!Array.isArray(raw)) return null;
  const clubs: ConsolidatedReport['venues'] = [];
  for (const v of raw) {
    if (!isMap(v)) return null;
    const id = opsStr(v, 'venue_id');
    const report = parseNightReport(v.report);
    if (id === null || report === null) return null;
    clubs.push({ venueId: id, venueName: opsStr(v, 'venue_name') ?? report.venueName, currencies: Array.isArray(v.currencies) ? v.currencies.map(String) : [], report });
  }
  const total = opsInt(r, 'venues_total');
  if (total !== clubs.length) return null;
  const mixed = opsBool(r, 'currency_mixed');
  const t = r.totals;
  if (!mixed && !isMap(t)) return null;
  let totals: Record<string, number> | null = null;
  if (!mixed && isMap(t)) {
    totals = {};
    for (const [k, v] of Object.entries(t)) totals[k] = typeof v === 'number' ? Math.trunc(v) : /^[+-]?\d+$/.test(String(v)) ? Number.parseInt(String(v), 10) : 0;
  }
  return {
    orgName: opsStr(r, 'org_name') ?? 'Your business',
    night,
    generatedAt: opsTime(r, 'generated_at'),
    venuesTotal: total,
    venuesFinal: opsInt(r, 'venues_final'),
    currency: mixed ? null : opsStr(r, 'currency'),
    currencyMixed: mixed,
    currencies: Array.isArray(r.currencies) ? r.currencies.map(String) : [],
    totals,
    venues: clubs,
  };
}

export function buildConsolidatedDocument(r: ConsolidatedReport, timeZone: string): ReportDocument {
  const sections: ReportSection[] = [];
  const t = r.totals;
  const n = (key: string) => t?.[key] ?? 0;
  const d = (key: string) => formatDollars(n(key));
  const label = r.currency === null ? '' : ` (${r.currency})`;
  const allFinal = r.venuesTotal > 0 && r.venuesFinal === r.venuesTotal;

  if (r.currencyMixed) {
    sections.push(section('Totals not added', [row('Currencies sold in', r.currencies.map((c) => c.toUpperCase()).join(', ')), row('Combined total', 'Not shown'), row('Why', 'Different currencies are never added together')]));
  } else if (t !== null) {
    sections.push(
      section(`Tables and guests${label}`, [row('Tables booked', String(n('tables'))), row('Guests', String(n('guests'))), row('Guests seated (tables)', String(n('seated')))]),
      section(`Sales${label}`, [row('Booked total', d('booked_cents'), true), row('Paid so far', d('paid_cents')), row('Balance still due', d('balance_cents')), row('Discounts', d('discount_cents'))]),
      section(`Collected at the club${label}`, [
        row('Payments', String(n('payments'))),
        row('Collected', d('collected_cents'), true),
        row('Cash', d('cash_cents')),
        row('Card (debit, credit and the card part of splits)', d('card_cents')),
        row('Cash counted at handover', d('cash_counted_cents')),
        row('Cash shortages', d('shortage_cents')),
        row('Cash overages', d('overage_cents')),
        row('Cash still held by staff', d('held_cents')),
      ]),
      section(`Bottle orders${label}`, [row('Bottles ordered', String(n('bottle_lines'))), row('Value', d('bottle_value_cents'), true), row('Served', String(n('bottles_served')))]),
      section('Needing attention', [
        row('Payments not yet verified', String(n('unverified'))),
        row('Disputed by the guest', String(n('disputed'))),
        row('Without a receipt photo', String(n('no_receipt'))),
        row('Flagged payments still open', String(n('flags_open'))),
        row('Requests from tables still open', String(n('requests_open'))),
        row('Security alerts not resolved', String(n('alerts_unresolved'))),
        row('Nights closed with exceptions', String(n('closed_with_exceptions'))),
      ]),
    );
  }

  const clubFigures = (c: ConsolidatedReport['venues'][number]): string => {
    const b = c.report.sections.bookings;
    if (!b) return 'No figures';
    const tables = opsInt(b, 'count');
    return `${tables} ${tables === 1 ? 'table' : 'tables'} · ${formatDollars(opsInt(b, 'total_cents'))}`;
  };
  const currencyLabel = (c: ConsolidatedReport['venues'][number]): string | null => (c.currencies.length === 0 ? null : c.currencies.length === 1 ? c.currencies[0].toUpperCase() : 'mixed currencies');

  if (r.venues.length > 0) sections.push(section('By club', r.venues.map((c) => row(`${c.venueName} · ${c.report.isFinal ? 'FINAL' : 'PRELIMINARY'}`, clubFigures(c)))));
  for (const c of r.venues) {
    const b = c.report.sections.bookings;
    const p = c.report.sections.payments;
    const bt = c.report.sections.bottles;
    const f = c.report.sections.flags;
    const cur = currencyLabel(c);
    const rows: ReportRow[] = [];
    if (b) {
      rows.push(
        row('Tables booked', String(opsInt(b, 'count'))),
        row('Guests', String(opsInt(b, 'guests'))),
        row('Booked total', formatDollars(opsInt(b, 'total_cents')), true),
        row('Paid so far', formatDollars(opsInt(b, 'paid_cents'))),
        row('Balance still due', formatDollars(opsInt(b, 'balance_cents'))),
      );
    }
    if (p) rows.push(row('Collected at the club', formatDollars(opsInt(p, 'collected_cents'))));
    if (bt) rows.push(row('Bottle orders', formatDollars(opsInt(bt, 'value_cents'))));
    if (f) rows.push(row('Flagged payments still open', String(opsInt(f, 'open'))));
    if (c.report.isFinal && c.report.exceptions.length > 0) rows.push(row('Closed with exceptions', String(c.report.exceptions.length)));
    sections.push(section(`${c.venueName} · ${c.report.isFinal ? 'FINAL' : 'PRELIMINARY'}${cur === null ? '' : ` · ${cur}`}`, rows));
  }

  let status: string;
  if (r.venuesTotal === 0) status = 'No venues in this business yet';
  else if (allFinal) status = 'FINAL · every club has closed the night';
  else {
    const at = r.generatedAt === null ? '' : `; figures as of ${timeOfDay(r.generatedAt, timeZone)}`;
    status = `PRELIMINARY · ${r.venuesFinal} of ${r.venuesTotal} clubs have closed the night${at}; the totals are not final until every club has`;
  }
  const s = slug(r.orgName);
  return {
    title: 'All venues',
    subtitle: `${r.orgName} · ${formatNight(r.night)}`,
    statusLine: status,
    sections,
    fileName: `${s === '' ? 'business' : s}-all-venues-${r.night}-${allFinal ? 'final' : 'preliminary'}.pdf`,
  };
}

// ---------------------------------------------------------------------------------------------------------------------------------------------------------------------
// 4. The organizer's event report (organizer_event_sales): only what each club has chosen to share
// ---------------------------------------------------------------------------------------------------------------------------------------------------------------------

const ACCESS_KEYS: Record<string, string> = {
  bar_sales: 'Bar sales', ticket_checkins: 'Ticket check-ins', capacity: 'Capacity', table_sales: 'Table sales', chat: 'Operational chat', settlement: 'Settlement details',
};

interface AccessGrant {
  key: string;
  allowed: boolean;
  available: boolean;
  data: Json | null;
}
const grantLabel = (g: AccessGrant): string => ACCESS_KEYS[g.key];
const grantState = (g: AccessGrant): string => (!g.allowed ? 'Not shared' : g.available ? 'Shared' : 'Allowed, not available yet');

function parseGrants(list: unknown): AccessGrant[] {
  if (!Array.isArray(list)) return [];
  const out: AccessGrant[] = [];
  for (const raw of list) {
    if (!isMap(raw)) continue;
    const key = opsStr(raw, 'key');
    if (key === null || !(key in ACCESS_KEYS)) continue;
    out.push({ key, allowed: opsBool(raw, 'allowed'), available: opsBool(raw, 'available'), data: isMap(raw.data) ? raw.data : null });
  }
  return out;
}

export interface EventSales {
  eventTitle: string;
  eventStart: Date | null;
  eventEnd: Date | null;
  eventStatus: string;
  venueName: string;
  eventCapacity: number | null;
  generatedAt: Date | null;
  tickets: {
    orders: number; ticketsSold: number; checkedIn: number; refundedOrders: number; refundedCents: number; currencyMixed: boolean; grossCents: number | null; currency: string | null;
    tiers: { name: string; priceCents: number; capacity: number; sold: number; checkedIn: number; grossCents: number; currency: string | null }[];
  };
  clubs: { agreementId: string; venueName: string; status: string; inForce: boolean; grants: AccessGrant[] }[];
}

export function parseEventSales(r: unknown): EventSales | null {
  if (!isMap(r)) return null;
  const ev = r.event;
  const tm = r.tickets;
  if (!isMap(ev) || !isMap(tm)) return null;
  const tiers: EventSales['tickets']['tiers'] = [];
  if (Array.isArray(tm.by_tier)) {
    for (const x of tm.by_tier) {
      if (!isMap(x)) return null;
      const name = opsStr(x, 'tier');
      if (name === null) return null;
      tiers.push({ name, priceCents: opsInt(x, 'price_cents'), capacity: opsInt(x, 'capacity'), sold: opsInt(x, 'sold'), checkedIn: opsInt(x, 'checked_in'), grossCents: opsInt(x, 'gross_cents'), currency: opsStr(x, 'currency') });
    }
  }
  const mixed = opsBool(tm, 'currency_mixed');
  const clubs: EventSales['clubs'] = [];
  if (Array.isArray(r.venues)) {
    for (const x of r.venues) {
      if (!isMap(x)) return null;
      const id = opsStr(x, 'agreement_id');
      if (id === null) return null;
      clubs.push({ agreementId: id, venueName: opsStr(x, 'venue_name') ?? 'Club', status: opsStr(x, 'status') ?? '', inForce: opsBool(x, 'in_force'), grants: parseGrants(x.grants) });
    }
  }
  return {
    eventTitle: opsStr(ev, 'title') ?? 'Event',
    eventStart: opsTime(ev, 'start'),
    eventEnd: opsTime(ev, 'end'),
    eventStatus: opsStr(ev, 'status') ?? '',
    venueName: opsStr(ev, 'venue_name') ?? '',
    eventCapacity: ev.capacity === null || ev.capacity === undefined ? null : opsInt(ev, 'capacity'),
    generatedAt: opsTime(r, 'generated_at'),
    tickets: {
      orders: opsInt(tm, 'orders'),
      ticketsSold: opsInt(tm, 'tickets_sold'),
      checkedIn: opsInt(tm, 'checked_in'),
      refundedOrders: opsInt(tm, 'refunded_orders'),
      refundedCents: opsInt(tm, 'refunded_cents'),
      currencyMixed: mixed,
      // Money is only ever shown for a single currency, whatever else the answer holds.
      grossCents: mixed || tm.gross_cents === null || tm.gross_cents === undefined ? null : opsInt(tm, 'gross_cents'),
      currency: mixed ? null : opsStr(tm, 'currency'),
      tiers,
    },
    clubs,
  };
}

/** The event's status in words. */
export function eventStatusWords(s: string): string {
  if (s === 'draft') return 'Draft (private)';
  if (s === 'published') return 'Published';
  if (s === '') return 'Unknown';
  return s[0].toUpperCase() + s.slice(1).replaceAll('_', ' ');
}

/** What the state of a club's agreement means for sharing, when it is not in force. */
function notActiveLine(status: string): string {
  if (status === 'requested') return 'Asked for: the club has not answered yet. Nothing is shared.';
  if (status === 'negotiating') return 'Being agreed. Nothing is shared until both sides accept.';
  return 'Not active. Nothing is shared.';
}

const plural = (n: number, one: string, many: string): string => `${n} ${n === 1 ? one : many}`;
// Like the app's string interpolation: nothing is written as the word null.
const str = (v: unknown): string => (v === null || v === undefined ? 'null' : String(v));

/** The rows one club's shared things make, in the brief's order. A thing that is not shared, or not available yet, says so instead of leaving a gap. */
function sharedSections(club: EventSales['clubs'][number], timeZone: string): ReportSection[] {
  const out: ReportSection[] = [];
  if (!club.inForce) {
    out.push(section(`${club.venueName} · not active`, [row('Shared with you', notActiveLine(club.status))]));
    return out;
  }
  const notShared: ReportRow[] = [];
  for (const g of club.grants) {
    const d = g.data;
    if (!g.allowed || !g.available || d === null) {
      notShared.push(row(grantLabel(g), grantState(g)));
      continue;
    }
    if (g.key === 'table_sales') {
      const mixed = d.currency_mixed === true;
      const label = d.currency === null || d.currency === undefined ? '' : ` (${str(d.currency)})`;
      out.push(section(`Table sales at ${club.venueName}${label} · ${formatNight(str(d.night))}`, [
        row('Tables booked', String(opsInt(d, 'tables'))),
        row('Guests', String(opsInt(d, 'guests'))),
        ...(mixed ? [row('Money', 'Not added: more than one currency')] : [row('Booked total', formatDollars(opsInt(d, 'booked_cents')), true), row('Paid so far', formatDollars(opsInt(d, 'paid_cents')))]),
      ]));
    } else if (g.key === 'capacity') {
      const agreed = d.agreed === null || d.agreed === undefined ? null : opsInt(d, 'agreed');
      out.push(section(`Capacity at ${club.venueName}`, [
        row('Agreed capacity', agreed === null ? 'Not set in the agreement' : String(agreed)),
        row('Tickets sold', String(opsInt(d, 'tickets_sold'))),
        row('Checked in', String(opsInt(d, 'checked_in'))),
        ...(agreed !== null ? [row('Room left (agreed less checked in)', String(agreed - opsInt(d, 'checked_in')))] : []),
      ]));
    } else if (g.key === 'ticket_checkins') {
      const last = d.last_check_in_at === null || d.last_check_in_at === undefined ? null : opsTime(d, 'last_check_in_at');
      out.push(section(`Check-ins at ${club.venueName}`, [
        row('Checked in', `${opsInt(d, 'checked_in')} of ${opsInt(d, 'tickets_sold')}`),
        row('Last check-in', last === null ? 'None yet' : timeOfDay(last, timeZone)),
      ]));
    } else {
      notShared.push(row(grantLabel(g), grantState(g)));
    }
  }
  if (notShared.length > 0) out.push(section(`Not available from ${club.venueName}`, notShared));
  return out;
}

export function buildEventDocument(s: EventSales, timeZone: string): ReportDocument {
  const t = s.tickets;
  const label = t.currency === null ? '' : ` (${t.currency})`;
  const when = (d: Date | null) => (d === null ? 'Not set' : whenLabel(d, timeZone));
  const sections: ReportSection[] = [
    section('Event', [
      row('Event', s.eventTitle),
      row('Starts', when(s.eventStart)),
      ...(s.eventEnd !== null ? [row('Ends', when(s.eventEnd))] : []),
      row('Status', eventStatusWords(s.eventStatus)),
      ...(s.venueName !== '' ? [row('Venue', s.venueName)] : []),
      ...(s.eventCapacity !== null ? [row('Capacity set on the event', String(s.eventCapacity))] : []),
    ]),
    section(`Your tickets${label}`, [
      row('Paid orders', String(t.orders)),
      row('Tickets sold', String(t.ticketsSold), true),
      row('Checked in', String(t.checkedIn)),
      row('Gross sales', t.grossCents === null ? 'Not added: more than one currency' : formatDollars(t.grossCents), true),
      ...(t.refundedOrders > 0 ? [row('Refunded', `${plural(t.refundedOrders, 'order', 'orders')} · ${t.currencyMixed ? 'amount not added' : formatDollars(t.refundedCents)}`)] : []),
    ]),
  ];
  if (t.tiers.length > 0) {
    sections.push(section('By ticket type', t.tiers.map((x) => row(`${x.name} · ${formatDollars(x.priceCents)}${x.currency === null ? '' : ` ${x.currency}`} · ${x.sold} of ${x.capacity} sold, ${x.checkedIn} in`, formatDollars(x.grossCents)))));
  }
  if (s.clubs.length === 0) sections.push(section('Shared by the club', [row('Venue', 'No club is linked to this event yet')]));
  for (const c of s.clubs) sections.push(...sharedSections(c, timeZone));
  const sl = slug(s.eventTitle);
  const date = s.eventStart === null ? '' : eventDate(s.eventStart, timeZone);
  return {
    title: 'Event report',
    subtitle: s.eventTitle,
    statusLine: `${s.generatedAt === null ? 'Figures as they stand now' : `Figures as of ${timeOfDay(s.generatedAt, timeZone)}`}. Only what each club has chosen to share is included.`,
    sections,
    fileName: `${sl === '' ? 'event' : sl}${date === '' ? '' : `-${date}`}-event-report.pdf`,
  };
}

/** "2026-11-14" in a time zone (the app's yyyy-MM-dd). */
export function eventDate(d: Date, timeZone: string): string {
  const p = parts(d, timeZone, { year: 'numeric', month: '2-digit', day: '2-digit' });
  return `${p.year}-${p.month}-${p.day}`;
}

// ---------------------------------------------------------------------------------------------------------------------------------------------------------------------
// What the job asks for: the data the database gave a job, as a document
// ---------------------------------------------------------------------------------------------------------------------------------------------------------------------

export type ReportKind = 'owner_combined' | 'venue_night' | 'organizer_sales';

/** A file name the delivery log accepts: letters, numbers, spaces and . _ ( ) -, at most 95 before ".pdf". */
export function safeFileName(name: string): string {
  if (/^[A-Za-z0-9 _.()-]{1,95}\.pdf$/.test(name)) return name;
  const base = name.replace(/\.pdf$/i, '').replace(/[^A-Za-z0-9 _.()-]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 95).replace(/-+$/, '');
  return `${base === '' ? 'report' : base}.pdf`;
}

/** The document for a job's data (what report_job_data returned), or null when the data cannot be read (nothing is sent). */
export function documentForJob(data: unknown): ReportDocument | null {
  if (!isMap(data)) return null;
  const kind = data.kind;
  const timeZone = typeof data.time_zone === 'string' && data.time_zone !== '' ? data.time_zone : 'America/Toronto';
  try {
    new Intl.DateTimeFormat('en-US', { timeZone });
  } catch {
    return null;
  }
  let doc: ReportDocument | null = null;
  if (kind === 'venue_night') {
    const r = parseNightReport(data.report);
    if (r === null) return null;
    doc = documentWithSales(buildNightDocument(r, timeZone), parseNightSales(data.sales), timeZone);
  } else if (kind === 'owner_combined') {
    const r = parseConsolidatedReport(data.report);
    if (r === null) return null;
    doc = buildConsolidatedDocument(r, timeZone);
  } else if (kind === 'organizer_sales') {
    const r = parseEventSales(data.report);
    if (r === null) return null;
    doc = buildEventDocument(r, timeZone);
  }
  return doc === null ? null : { ...doc, fileName: safeFileName(doc.fileName) };
}
