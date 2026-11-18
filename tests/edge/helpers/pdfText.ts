import { inflateSync } from 'node:zlib';

function streams(bytes: Uint8Array): string[] {
  const raw = Buffer.from(bytes).toString('latin1');
  const out: string[] = [];
  const re = /stream\r?\n([\s\S]*?)\r?\nendstream/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(raw)) !== null) {
    const body = Buffer.from(m[1], 'latin1');
    try {
      out.push(inflateSync(body).toString('latin1'));
    } catch {
      out.push(body.toString('latin1'));
    }
  }
  return out;
}

/** The text drawn on each page of a PDF made by pdf-lib with the standard fonts: the hex strings of the Tj operators, decoded as Latin-1, per page, in the order drawn. */
export function pdfPages(bytes: Uint8Array): string[][] {
  const pages: string[][] = [];
  for (const content of streams(bytes)) {
    if (!content.includes('Tj')) continue;
    const lines: string[] = [];
    for (const t of content.matchAll(/<([0-9A-Fa-f]*)>\s*Tj/g)) lines.push(Buffer.from(t[1], 'hex').toString('latin1'));
    pages.push(lines);
  }
  return pages;
}

export const pdfText = (bytes: Uint8Array): string => pdfPages(bytes).flat().join('\n');

export interface Drawn {
  page: number;
  text: string;
  x: number;
  y: number;
  size: number;
  bold: boolean;
}
export interface Rule {
  page: number;
  x: number;
  x2: number;
  y: number;
}

/** Where every piece of text and every rule was drawn (in PDF points, from the bottom left of the page), from the drawing operators of each page. */
export function pdfDrawn(bytes: Uint8Array): { text: Drawn[]; rules: Rule[] } {
  const text: Drawn[] = [];
  const rules: Rule[] = [];
  let page = -1;
  for (const content of streams(bytes)) {
    if (!content.includes('Tj')) continue;
    page += 1;
    for (const block of content.split(/\bQ\b/)) {
      const font = /\/(Helvetica[-A-Za-z]*?)-?\d* (\d+(?:\.\d+)?) Tf/.exec(block);
      const pos = /1 0 0 1 (-?\d+(?:\.\d+)?) (-?\d+(?:\.\d+)?) Tm/.exec(block);
      const str = /<([0-9A-Fa-f]*)>\s*Tj/.exec(block);
      if (font && pos && str) text.push({ page, text: Buffer.from(str[1], 'hex').toString('latin1'), x: Number(pos[1]), y: Number(pos[2]), size: Number(font[2]), bold: font[1].includes('Bold') });
      const line = /(-?\d+(?:\.\d+)?) (-?\d+(?:\.\d+)?) m\s+(-?\d+(?:\.\d+)?) (-?\d+(?:\.\d+)?) l/.exec(block);
      if (line) rules.push({ page, x: Number(line[1]), y: Number(line[2]), x2: Number(line[3]) });
    }
  }
  return { text, rules };
}
