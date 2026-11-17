import { describe, expect, it } from 'vitest';
import { buildReportEmail, REPORT_SUBJECT } from '../../supabase/functions/_shared/reportEmailTemplate.ts';

// The e-mail that carries a report: the same fixed text whether a person pressed the button or the server sent it when the night was closed, except for the last line.

const base = { kind: 'venue_night' as const, orgName: 'Club Co', venueName: 'Club A', eventTitle: null, ref: '2026-11-14', senderEmail: 'mia@club.example', filename: 'club-a.pdf' };

describe('the report e-mail', () => {
  it('by the button: says who sent it', () => {
    const m = buildReportEmail(base);
    expect(m.subject).toBe(REPORT_SUBJECT);
    expect(m.text).toContain('Sent by mia@club.example from BottlesUp Business, because your address is on the report list.');
    expect(m.html).toContain('Sent by mia@club.example from BottlesUp Business');
    expect(m.text).not.toContain('automatically');
  });
  it('automatic: says so, names no one, and keeps the rest the same', () => {
    const manual = buildReportEmail(base);
    const auto = buildReportEmail({ ...base, automatic: true });
    expect(auto.subject).toBe(manual.subject);
    expect(auto.text).toContain('Sent automatically by BottlesUp Business when the night was closed, because your address is on the report list. If you were not expecting this, you can ignore it.');
    expect(auto.html).toContain('Sent automatically by BottlesUp Business when the night was closed');
    expect(auto.text).not.toContain('Sent by');
    expect(auto.text).not.toContain('mia@club.example');
    expect(auto.html).not.toContain('mia@club.example');
    expect(auto.text.split('\n').slice(0, 4)).toEqual(manual.text.split('\n').slice(0, 4));
  });
  it('automatic: an empty sender is fine, and the names are still escaped', () => {
    const m = buildReportEmail({ ...base, kind: 'owner_combined', senderEmail: '', automatic: true, orgName: '<b>Club</b> & Co', venueName: null });
    expect(m.html).toContain('&lt;b&gt;Club&lt;/b&gt; &amp; Co');
    expect(m.html).not.toContain('<b>Club</b>');
    expect(m.text).toContain('A report for you');
  });
  it('automatic is off unless it is true', () => {
    expect(buildReportEmail({ ...base, automatic: false }).text).toContain('Sent by mia@club.example');
  });
});
