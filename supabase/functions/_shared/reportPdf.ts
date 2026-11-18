// Draws a report document as a PDF on the server, laid out the way the app draws it on the phone (lib/features/night/logic/report_pdf.dart): the title, who and when, whether it is final,
// then each section as a two-column table, A4 with 36-point margins, "BottlesUp - page X of Y" at the top of every page. The standard PDF fonts only hold Latin-1, so a few typographic
// characters are swapped for plain ones and anything else becomes "?" (a name in another alphabet prints as question marks; the e-mail and the app have it complete).

import { PDFDocument, StandardFonts, rgb, type PDFFont } from 'npm:pdf-lib@1.17.1';
import type { ReportDocument } from './reportDocs.ts';

const SWAPS: Record<string, string> = { '·': '-', '–': '-', '—': '-', '‘': "'", '’': "'", '“': '"', '”': '"', '…': '...', '•': '-' };

/** Only what the standard fonts can print: the swaps above, Latin-1 letters and symbols, and a space for anything that is not printable (a line break, a control character). */
export function pdfSafe(s: string): string {
  let out = '';
  for (const ch of s) {
    const code = ch.codePointAt(0)!;
    if (SWAPS[ch] !== undefined) out += SWAPS[ch];
    else if (code < 32 || (code >= 127 && code <= 159)) out += ' ';
    else if (code < 256) out += ch;
    else out += '?';
  }
  return out;
}

const PAGE = { width: 595.28, height: 841.89 };
const MARGIN = 36;
const GREY_700 = rgb(0.38, 0.38, 0.38);
const GREY_800 = rgb(0.26, 0.26, 0.26);
const GREY_300 = rgb(0.88, 0.88, 0.88);
const BLACK = rgb(0, 0, 0);

interface Placed {
  kind: 'text' | 'line';
  page: number;
  x: number;
  y: number;
  text?: string;
  size?: number;
  bold?: boolean;
  color?: ReturnType<typeof rgb>;
  x2?: number;
}

/** Splits [text] into lines no wider than [max] points. A word wider than a whole line is cut. */
export function wrap(text: string, font: PDFFont, size: number, max: number): string[] {
  const lines: string[] = [];
  let line = '';
  const flush = () => {
    lines.push(line);
    line = '';
  };
  for (const word of text.split(' ')) {
    let w = word;
    while (font.widthOfTextAtSize(w, size) > max && w.length > 1) {
      // cut the word where it stops fitting
      let cut = w.length - 1;
      while (cut > 1 && font.widthOfTextAtSize(w.slice(0, cut), size) > max) cut--;
      if (line !== '') flush();
      lines.push(w.slice(0, cut));
      w = w.slice(cut);
    }
    const candidate = line === '' ? w : `${line} ${w}`;
    if (line !== '' && font.widthOfTextAtSize(candidate, size) > max) {
      flush();
      line = w;
    } else {
      line = candidate;
    }
  }
  if (line !== '' || lines.length === 0) lines.push(line);
  return lines;
}

/** The report as a PDF. [now] is the creation time written into the file. */
export async function buildReportPdf(doc: ReportDocument, now: Date = new Date()): Promise<Uint8Array> {
  const pdf = await PDFDocument.create();
  const regular = await pdf.embedFont(StandardFonts.Helvetica);
  const bold = await pdf.embedFont(StandardFonts.HelveticaBold);
  pdf.setTitle(pdfSafe(doc.title));
  pdf.setAuthor('BottlesUp');
  pdf.setProducer('BottlesUp');
  pdf.setCreator('BottlesUp');
  pdf.setCreationDate(now);
  pdf.setModificationDate(now);

  const contentWidth = PAGE.width - 2 * MARGIN;
  const labelWidth = (contentWidth * 3) / 5;
  const valueWidth = contentWidth - labelWidth;
  const top = PAGE.height - MARGIN - 16; // room for the page header
  const bottom = MARGIN;
  const placed: Placed[] = [];
  let page = 0;
  let y = top;
  const font = (b?: boolean) => (b ? bold : regular);
  const need = (h: number) => {
    if (y - h < bottom) {
      page += 1;
      y = top;
    }
  };
  const text = (t: string, x: number, size: number, opts: { bold?: boolean; color?: ReturnType<typeof rgb> } = {}) => {
    placed.push({ kind: 'text', page, x, y, text: t, size, bold: opts.bold, color: opts.color ?? BLACK });
  };
  const textBlock = (t: string, size: number, opts: { bold?: boolean; color?: ReturnType<typeof rgb> } = {}) => {
    for (const l of wrap(pdfSafe(t), font(opts.bold), size, contentWidth)) {
      need(size * 1.25);
      y -= size;
      text(l, MARGIN, size, opts);
      y -= size * 0.25;
    }
  };

  textBlock(doc.title, 20, { bold: true });
  y -= 2;
  textBlock(doc.subtitle, 12);
  y -= 4;
  textBlock(doc.statusLine, 10, { bold: true, color: GREY_800 });
  y -= 14;

  for (const s of doc.sections) {
    need(13 * 1.25 + 4 + 10 * 1.25 + 6);
    textBlock(s.title, 13, { bold: true });
    y -= 4;
    for (const r of s.rows) {
      const f = font(r.strong);
      const labelLines = wrap(pdfSafe(r.label), f, 10, labelWidth - 4);
      const valueLines = wrap(pdfSafe(r.value), f, 10, valueWidth - 4);
      const count = Math.max(labelLines.length, valueLines.length);
      const height = count * 12.5 + 6;
      need(height);
      const rowTop = y;
      for (let i = 0; i < count; i++) {
        const baseline = rowTop - 3 - 10 - i * 12.5;
        if (labelLines[i] !== undefined) placed.push({ kind: 'text', page, x: MARGIN, y: baseline, text: labelLines[i], size: 10, bold: r.strong, color: BLACK });
        if (valueLines[i] !== undefined) placed.push({ kind: 'text', page, x: MARGIN + contentWidth - f.widthOfTextAtSize(valueLines[i], 10), y: baseline, text: valueLines[i], size: 10, bold: r.strong, color: BLACK });
      }
      y = rowTop - height;
      placed.push({ kind: 'line', page, x: MARGIN, x2: MARGIN + contentWidth, y });
    }
    y -= 12;
  }

  const pages = page + 1;
  const pdfPages = Array.from({ length: pages }, () => pdf.addPage([PAGE.width, PAGE.height]));
  pdfPages.forEach((p, i) => {
    const label = `BottlesUp  -  page ${i + 1} of ${pages}`;
    p.drawText(label, { x: PAGE.width - MARGIN - regular.widthOfTextAtSize(label, 8), y: PAGE.height - MARGIN - 4, size: 8, font: regular, color: GREY_700 });
  });
  for (const o of placed) {
    const p = pdfPages[o.page];
    if (o.kind === 'line') p.drawLine({ start: { x: o.x, y: o.y }, end: { x: o.x2!, y: o.y }, thickness: 0.5, color: GREY_300 });
    else p.drawText(o.text!, { x: o.x, y: o.y, size: o.size!, font: font(o.bold), color: o.color });
  }
  // Plain objects (no object streams): every PDF reader and every mail scanner can read it.
  return pdf.save({ useObjectStreams: false });
}

/** The PDF as base64, for the e-mail. */
export function toBase64(bytes: Uint8Array): string {
  let binary = '';
  const chunk = 0x8000;
  for (let i = 0; i < bytes.length; i += chunk) binary += String.fromCharCode(...bytes.subarray(i, i + chunk));
  return btoa(binary);
}
