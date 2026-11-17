import { PDFDocument, StandardFonts } from 'pdf-lib';
import { describe, expect, it } from 'vitest';
import type { ReportDocument } from '../../supabase/functions/_shared/reportDocs.ts';
import { buildReportPdf, pdfSafe, toBase64, wrap } from '../../supabase/functions/_shared/reportPdf.ts';
import { pdfDrawn, pdfPages, pdfText } from './helpers/pdfText.ts';

const doc = (over: Partial<ReportDocument> = {}): ReportDocument => ({
  title: 'Nightly report',
  subtitle: 'Club A · Saturday Nov 14',
  statusLine: 'FINAL · closed 03:12 by Mia',
  fileName: 'club-a.pdf',
  sections: [
    { title: 'Sales', rows: [{ label: 'Booked total', value: '$9,600.00', strong: true }, { label: 'Paid so far', value: '$4,825.50', strong: false }] },
    { title: 'Cash', rows: [{ label: 'Counted', value: '$1,185.00', strong: false }] },
  ],
  ...over,
});
const NOW = new Date('2026-11-15T03:12:00Z');

describe('the PDF', () => {
  it('is a PDF, one page, with the title, who and when, the status and every section', async () => {
    const bytes = await buildReportPdf(doc(), NOW);
    expect(Buffer.from(bytes.subarray(0, 5)).toString()).toBe('%PDF-');
    const pages = pdfPages(bytes);
    expect(pages).toHaveLength(1);
    const text = pages[0];
    expect(text).toContain('Nightly report');
    expect(text).toContain('Club A - Saturday Nov 14');
    expect(text).toContain('FINAL - closed 03:12 by Mia');
    for (const t of ['Sales', 'Booked total', '$9,600.00', 'Paid so far', '$4,825.50', 'Cash', 'Counted', '$1,185.00']) expect(text).toContain(t);
  });
  it('says BottlesUp and which page of how many at the top of every page', async () => {
    expect(pdfText(await buildReportPdf(doc(), NOW))).toContain('BottlesUp  -  page 1 of 1');
  });
  it('is made by BottlesUp, titled, and stamped with the time it was made', async () => {
    const pdf = await PDFDocument.load(await buildReportPdf(doc({ title: 'All venues' }), NOW), { updateMetadata: false });
    expect([pdf.getTitle(), pdf.getAuthor(), pdf.getProducer(), pdf.getCreator()]).toEqual(['All venues', 'BottlesUp', 'BottlesUp', 'BottlesUp']);
    expect(pdf.getCreationDate()?.toISOString()).toBe('2026-11-15T03:12:00.000Z');
    expect(pdf.getPageCount()).toBe(1);
    const page = pdf.getPage(0).getSize();
    expect([Math.round(page.width), Math.round(page.height)]).toEqual([595, 842]);
  });
  it('uses both the regular and the bold font', async () => {
    const raw = Buffer.from(await buildReportPdf(doc(), NOW)).toString('latin1');
    expect(raw).toContain('Helvetica-Bold');
    expect(raw).toMatch(/\/BaseFont \/Helvetica\b/);
  });
  it('flows onto more pages when it is long, numbering them, and never splits a row across pages', async () => {
    const rows = Array.from({ length: 120 }, (_, i) => ({ label: `Row number ${i + 1}`, value: `$${i + 1}.00`, strong: false }));
    const pages = pdfPages(await buildReportPdf(doc({ sections: [{ title: 'Long', rows }] }), NOW));
    expect(pages.length).toBeGreaterThanOrEqual(3);
    pages.forEach((p, i) => expect(p).toContain(`BottlesUp  -  page ${i + 1} of ${pages.length}`));
    const all = pages.flat();
    for (let i = 1; i <= 120; i++) expect(all.filter((t) => t === `Row number ${i}`)).toHaveLength(1);
    for (const p of pages) {
      const labels = p.filter((t) => t.startsWith('Row number')).length;
      const values = p.filter((t) => /^\$\d+\.00$/.test(t)).length;
      expect(labels).toBe(values);
    }
  });
  it('wraps a long label and a long value, and still prints all of both', async () => {
    const label = 'A very long label that has to wrap over several lines because it is far wider than the column that holds it ' + 'word '.repeat(10);
    const value = 'And a value that is long too, so long that it has to be wrapped as well, which a number never is';
    const text = pdfText(await buildReportPdf(doc({ sections: [{ title: 'Wide', rows: [{ label, value, strong: false }] }] }), NOW));
    // every word of both is there as often as it was written (the two are drawn line by line side by side, so their words are interleaved)
    const count = (s: string) => s.split(/\s+/).filter(Boolean).reduce<Record<string, number>>((m, w) => ({ ...m, [w]: (m[w] ?? 0) + 1 }), {});
    const drawn = count(text);
    for (const [w, n] of Object.entries(count(`${label} ${value}`))) expect(drawn[w] ?? 0, w).toBeGreaterThanOrEqual(n);
  });
  it('prints a word wider than a line in pieces rather than running off the page', async () => {
    const text = pdfText(await buildReportPdf(doc({ sections: [{ title: 'W', rows: [{ label: 'x'.repeat(300), value: '1', strong: false }] }] }), NOW));
    expect(text.replace(/\n/g, '').match(/x/g)!.length).toBe(300);
  });
  it('prints only what the standard fonts can: Latin-1 letters stay, typographic marks are swapped, other alphabets become ?', async () => {
    const text = pdfText(await buildReportPdf(doc({ title: 'Café “Münch” – 100% … done', sections: [{ title: 'N', rows: [{ label: 'Name', value: 'Борис', strong: false }] }] }), NOW));
    expect(text).toContain('Café "Münch" - 100% ... done');
    expect(text).toContain('?????');
  });
  it('never fails on a line break, a tab or a control character in a name', async () => {
    const bytes = await buildReportPdf(doc({ subtitle: 'Club\nA\tB\u0007C\u0085D', sections: [{ title: 'S', rows: [{ label: 'a\r\nb', value: 'c', strong: false }] }] }), NOW);
    expect(pdfText(bytes)).toContain('Club A B C D');
  });
  it('an empty document is still a PDF', async () => {
    const pages = pdfPages(await buildReportPdf(doc({ sections: [] }), NOW));
    expect(pages).toHaveLength(1);
  });
  it('stays well inside what can be e-mailed (5 MB) for a very large report', async () => {
    const rows = Array.from({ length: 2000 }, (_, i) => ({ label: `Row ${i}`, value: `$${i}.00`, strong: i % 7 === 0 }));
    const bytes = await buildReportPdf(doc({ sections: [{ title: 'Big', rows }] }), NOW);
    expect(bytes.length).toBeLessThan(5 * 1024 * 1024);
  });
});

describe('where things are drawn', () => {
  const W = 595.28;
  const H = 841.89;
  const M = 36;
  const contentWidth = W - 2 * M;
  const labelWidth = (contentWidth * 3) / 5;
  const valueWidth = contentWidth - labelWidth;
  const fonts = async () => {
    const pdf = await PDFDocument.create();
    return { regular: await pdf.embedFont(StandardFonts.Helvetica), bold: await pdf.embedFont(StandardFonts.HelveticaBold) };
  };
  const rowDoc = (n: number): ReportDocument =>
    doc({ sections: [{ title: 'Rows', rows: Array.from({ length: n }, (_, i) => ({ label: `Label ${i}`, value: `$${i}.00`, strong: false })) }] });

  it('the page header is at the top right, in small type, inside the margins', async () => {
    const { regular } = await fonts();
    const h = pdfDrawn(await buildReportPdf(doc(), NOW)).text.find((d) => d.text.startsWith('BottlesUp  -  page'))!;
    expect(h.size).toBe(8);
    expect(h.y).toBeCloseTo(H - M - 4, 2);
    expect(h.x + regular.widthOfTextAtSize(h.text, 8)).toBeCloseTo(W - M, 2);
  });

  it('the title, the subtitle and the status are at the left margin, in the sizes and weights the app uses, one below the other', async () => {
    const d = pdfDrawn(await buildReportPdf(doc(), NOW)).text;
    const title = d.find((x) => x.text === 'Nightly report')!;
    const sub = d.find((x) => x.text.startsWith('Club A'))!;
    const status = d.find((x) => x.text.startsWith('FINAL'))!;
    expect([title.size, sub.size, status.size]).toEqual([20, 12, 10]);
    expect([title.bold, sub.bold, status.bold]).toEqual([true, false, true]);
    expect([title.x, sub.x, status.x]).toEqual([M, M, M]);
    expect(title.y).toBeCloseTo(H - M - 16 - 20, 2);
    expect(title.y - sub.y).toBeCloseTo(20 * 0.25 + 2 + 12, 2);
    expect(sub.y - status.y).toBeCloseTo(12 * 0.25 + 4 + 10, 2);
  });

  it('everything is inside the margins, on every page, whatever the length', async () => {
    const { regular, bold } = await fonts();
    const rows = Array.from({ length: 90 }, (_, i) => ({ label: `A label of some length that wraps ${'word '.repeat(i % 12)}`, value: `${'v'.repeat(i % 30)} $${i}.00`, strong: i % 5 === 0 }));
    const drawn = pdfDrawn(await buildReportPdf(doc({ sections: [{ title: 'Long', rows }] }), NOW));
    expect(drawn.text.length).toBeGreaterThan(200);
    for (const d of drawn.text) {
      const w = (d.bold ? bold : regular).widthOfTextAtSize(d.text, d.size);
      expect(d.x, d.text).toBeGreaterThanOrEqual(M - 0.01);
      expect(d.x + w, d.text).toBeLessThanOrEqual(W - M + 0.01);
      expect(d.y, d.text).toBeGreaterThanOrEqual(M);
      expect(d.y, d.text).toBeLessThanOrEqual(H - M);
    }
    for (const r of drawn.rules) {
      expect(r.x).toBe(M);
      expect(r.x2).toBeCloseTo(W - M, 2);
      expect(r.y).toBeGreaterThanOrEqual(M - 0.01);
    }
  });

  it('a label stays in the left column and a value is right-aligned to the right margin, each wrapped to its own column', async () => {
    const { regular } = await fonts();
    const label = 'A label long enough that it must wrap in its column because the column is only three fifths of the page ' + 'more '.repeat(8);
    const value = 'and a value that is long as well, so that it wraps in the narrower column on the right of the page';
    const drawn = pdfDrawn(await buildReportPdf(doc({ sections: [{ title: 'Wide', rows: [{ label, value, strong: false }] }] }), NOW)).text.filter((d) => d.size === 10 && !d.text.startsWith('FINAL'));
    const labels = drawn.filter((d) => d.x === M);
    const values = drawn.filter((d) => d.x > M);
    expect(labels.length).toBeGreaterThan(2);
    expect(values.length).toBeGreaterThan(2);
    for (const l of labels) expect(regular.widthOfTextAtSize(l.text, 10)).toBeLessThanOrEqual(labelWidth - 4 + 0.01);
    for (const v of values) {
      expect(regular.widthOfTextAtSize(v.text, 10)).toBeLessThanOrEqual(valueWidth - 4 + 0.01);
      expect(v.x + regular.widthOfTextAtSize(v.text, 10)).toBeCloseTo(W - M, 2);
    }
  });

  it('rows are 18.5 points apart and the lines of a wrapped row 12.5, so nothing overlaps; each row has a rule under it', async () => {
    const d = pdfDrawn(await buildReportPdf(rowDoc(6), NOW));
    const labels = d.text.filter((x) => x.text.startsWith('Label')).map((x) => x.y);
    expect(labels).toHaveLength(6);
    for (let i = 1; i < labels.length; i++) expect(labels[i - 1] - labels[i]).toBeCloseTo(18.5, 2);
    const rules = d.rules.map((r) => r.y);
    expect(rules).toHaveLength(6);
    labels.forEach((y, i) => expect(y - rules[i]).toBeCloseTo(5.5, 2));
    const wrapped = pdfDrawn(await buildReportPdf(doc({ sections: [{ title: 'W', rows: [{ label: 'word '.repeat(60), value: '1', strong: false }] }] }), NOW)).text.filter((x) => x.x === M && x.size === 10 && x.text.startsWith('word'));
    expect(wrapped.length).toBeGreaterThan(2);
    for (let i = 1; i < wrapped.length; i++) expect(wrapped[i - 1].y - wrapped[i].y).toBeCloseTo(12.5, 2);
  });

  it('the first row of a section sits under its title', async () => {
    const d = pdfDrawn(await buildReportPdf(doc(), NOW));
    const sales = d.text.find((x) => x.text === 'Sales')!;
    const first = d.text.find((x) => x.text === 'Booked total')!;
    expect(sales.size).toBe(13);
    expect(sales.bold).toBe(true);
    expect(sales.y - first.y).toBeCloseTo(13 * 0.25 + 4 + 3 + 10, 2);
    const paid = d.text.find((x) => x.text === 'Paid so far')!;
    const cash = d.text.find((x) => x.text === 'Cash')!;
    expect(paid.y - cash.y).toBeGreaterThan(20);
  });

  it('a strong row is bold and the others are not', async () => {
    const d = pdfDrawn(await buildReportPdf(doc(), NOW)).text;
    expect(d.find((x) => x.text === 'Booked total')!.bold).toBe(true);
    expect(d.find((x) => x.text === '$9,600.00')!.bold).toBe(true);
    expect(d.find((x) => x.text === 'Paid so far')!.bold).toBe(false);
    expect(d.find((x) => x.text === '$4,825.50')!.bold).toBe(false);
  });

  it('a long document breaks pages so that no row is cut and every page starts under its header', async () => {
    const d = pdfDrawn(await buildReportPdf(rowDoc(120), NOW));
    const pages = [...new Set(d.text.map((x) => x.page))];
    expect(pages.length).toBeGreaterThanOrEqual(3);
    for (const p of pages) {
      const onPage = d.text.filter((x) => x.page === p && x.text.startsWith('Label'));
      expect(onPage.length).toBeGreaterThan(p === pages[pages.length - 1] ? 0 : 20);
      expect(Math.max(...onPage.map((x) => x.y))).toBeLessThanOrEqual(H - M - 16);
      expect(Math.min(...onPage.map((x) => x.y))).toBeGreaterThanOrEqual(M + 5);
    }
    const counts = pages.map((p) => d.text.filter((x) => x.page === p && x.text.startsWith('Label')).length);
    // the first page has the title block, the last is what is left over; every page between is full
    const middle = counts.slice(1, -1);
    expect(middle.length).toBeGreaterThanOrEqual(1);
    expect(Math.max(...middle) - Math.min(...middle)).toBeLessThanOrEqual(1);
    expect(counts[0]).toBeLessThan(Math.max(...middle));
  });

  it('a section title is never left alone at the bottom of a page', async () => {
    for (let n = 30; n <= 42; n++) {
      const first = { title: 'First', rows: Array.from({ length: n }, (_, i) => ({ label: `Row ${i}`, value: '1', strong: false })) };
      const d = pdfDrawn(await buildReportPdf(doc({ sections: [first, { title: 'Second section', rows: [{ label: 'Only row', value: '2', strong: false }] }] }), NOW));
      const title = d.text.find((x) => x.text === 'Second section')!;
      const row = d.text.find((x) => x.text === 'Only row')!;
      expect(title.page, `with ${n} rows before it`).toBe(row.page);
    }
  });
});

describe('what is safe to print', () => {
  it('is exact at the edges: space and tilde stay, the last control character and DEL go, the next one stays, Latin-1 ends at the y-diaeresis', () => {
    expect([' ', '~', '\u001f', '\u007f', '\u009f', ' ', 'ÿ', 'Ā'].map(pdfSafe)).toEqual([' ', '~', ' ', ' ', ' ', ' ', 'ÿ', '?']);
  });

  it('swaps the typographic marks the app swaps', () => {
    expect(pdfSafe('a · b – c — d ‘e’ “f” … g • h')).toBe("a - b - c - d 'e' \"f\" ... g - h");
  });
  it('keeps Latin-1, replaces other characters with ? and unprintable ones with a space', () => {
    expect(pdfSafe('Zoë Ñandú £5 ©')).toBe('Zoë Ñandú £5 ©');
    expect(pdfSafe('Δ日本')).toBe('???');
    expect(pdfSafe('a\nb\tc\u0000d\u007fe\u0090f')).toBe('a b c d e f');
  });
});

describe('wrapping', () => {
  it('keeps words together, breaks between them, and returns one empty line for nothing', async () => {
    const pdf = await PDFDocument.create();
    const font = await pdf.embedFont(StandardFonts.Helvetica);
    const lines = wrap('one two three four five six', font, 10, font.widthOfTextAtSize('one two', 10) + 1);
    expect(lines).toEqual(['one two', 'three', 'four five', 'six']);
    expect(wrap('', font, 10, 100)).toEqual(['']);
    expect(wrap('short', font, 10, 100)).toEqual(['short']);
    for (const l of wrap('x'.repeat(200), font, 10, 50)) expect(font.widthOfTextAtSize(l, 10)).toBeLessThanOrEqual(50);
  });
  it('fills each line as far as it will go: a line that exactly fits stays whole, and a cut word is cut as late as possible', async () => {
    const pdf = await PDFDocument.create();
    const font = await pdf.embedFont(StandardFonts.Helvetica);
    expect(wrap('ab cd', font, 10, font.widthOfTextAtSize('ab cd', 10))).toEqual(['ab cd']);
    expect(wrap('abcd', font, 10, font.widthOfTextAtSize('abcd', 10))).toEqual(['abcd']);
    const pieces = wrap('x'.repeat(200), font, 10, 50);
    expect(pieces.join('')).toBe('x'.repeat(200));
    for (const p of pieces.slice(0, -1)) expect(font.widthOfTextAtSize(`${p}x`, 10)).toBeGreaterThan(50);
    const withText = wrap(`start ${'y'.repeat(100)} end`, font, 10, 50);
    expect(withText[0]).toBe('start');
    expect(withText.join('').replace(/ /g, '')).toBe(`start${'y'.repeat(100)}end`);
  });
});

describe('base64', () => {
  it('round-trips bytes, including a large buffer', () => {
    const bytes = new Uint8Array(100000).map((_, i) => i % 251);
    expect(Buffer.from(toBase64(bytes), 'base64').equals(Buffer.from(bytes))).toBe(true);
    expect(toBase64(new Uint8Array([37, 80, 68, 70]))).toBe('JVBERg==');
  });
  it('a PDF starts with the text the e-mail function checks for', async () => {
    expect(toBase64(await buildReportPdf(doc(), NOW)).startsWith('JVBERi0')).toBe(true);
  });
});
