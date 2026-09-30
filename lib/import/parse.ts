/**
 * lib/import/parse.ts
 *
 * Grundbausteine für den Import von Kontoauszügen (CSV/Excel) deutscher
 * Banken – reine Funktionen ohne Server- oder Browser-Abhängigkeiten:
 *
 * - decodeBytes():      Encoding erkennen (UTF-8 mit/ohne BOM, UTF-16 mit
 *                       BOM, sonst ISO-8859-1/Windows-1252)
 * - detectDelimiter():  Semikolon, Komma oder Tab
 * - parseCsv():         RFC-4180-CSV (Anführungszeichen, Zeilenumbrüche im Feld)
 * - parseAmount():      deutsches Zahlenformat (1.234,56), auch 1,234.56,
 *                       Vorzeichen hinten, Soll/Haben-Kürzel, Währungszeichen
 * - parseDate():        TT.MM.JJJJ, TT.MM.JJ, JJJJ-MM-TT
 */
import { parseIsoDate } from '@/lib/transactions';

// ---------------------------------------------------------------------
// Encoding
// ---------------------------------------------------------------------

export type DetectedEncoding = 'utf-8' | 'utf-16le' | 'utf-16be' | 'iso-8859-1';

/**
 * Text aus den Rohbytes einer Datei. UTF-8 wird nur angenommen, wenn die
 * Bytes gültiges UTF-8 sind; sonst ISO-8859-1 (als Windows-1252 dekodiert –
 * die übliche Obermenge, die Banken tatsächlich liefern, z. B. für „€“).
 */
export function decodeBytes(bytes: Uint8Array): { text: string; encoding: DetectedEncoding } {
  if (bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf) {
    return { text: new TextDecoder('utf-8').decode(bytes.subarray(3)), encoding: 'utf-8' };
  }
  if (bytes[0] === 0xff && bytes[1] === 0xfe) {
    return { text: new TextDecoder('utf-16le').decode(bytes.subarray(2)), encoding: 'utf-16le' };
  }
  if (bytes[0] === 0xfe && bytes[1] === 0xff) {
    return { text: new TextDecoder('utf-16be').decode(bytes.subarray(2)), encoding: 'utf-16be' };
  }
  try {
    return { text: new TextDecoder('utf-8', { fatal: true }).decode(bytes), encoding: 'utf-8' };
  } catch {
    return { text: new TextDecoder('windows-1252').decode(bytes), encoding: 'iso-8859-1' };
  }
}

// ---------------------------------------------------------------------
// CSV
// ---------------------------------------------------------------------

export const DELIMITERS = [';', ',', '\t'] as const;
export type Delimiter = (typeof DELIMITERS)[number];

/** Anzahl eines Trennzeichens außerhalb von Anführungszeichen je Zeile. */
function countOutsideQuotes(line: string, delimiter: string): number {
  let count = 0;
  let quoted = false;
  for (const char of line) {
    if (char === '"') {
      quoted = !quoted;
    } else if (char === delimiter && !quoted) {
      count += 1;
    }
  }
  return count;
}

/**
 * Trennzeichen, das in den meisten der ersten Zeilen gleich oft vorkommt
 * (Meta-Zeilen vor der Tabelle, z. B. bei der DKB, fallen dadurch nicht ins
 * Gewicht). Gleichstand → Semikolon, der deutsche Standard.
 */
export function detectDelimiter(text: string): Delimiter {
  const lines = text
    .split(/\r?\n/)
    .filter((line) => line.trim() !== '')
    .slice(0, 40);

  let best: { delimiter: Delimiter; lines: number; fields: number } = { delimiter: ';', lines: 0, fields: 0 };
  for (const delimiter of DELIMITERS) {
    const frequency = new Map<number, number>();
    for (const line of lines) {
      const count = countOutsideQuotes(line, delimiter);
      if (count > 0) {
        frequency.set(count, (frequency.get(count) ?? 0) + 1);
      }
    }
    for (const [fields, occurrences] of frequency) {
      if (occurrences > best.lines || (occurrences === best.lines && fields > best.fields)) {
        best = { delimiter, lines: occurrences, fields };
      }
    }
  }
  return best.delimiter;
}

/** CSV nach RFC 4180; Zeilenende \n oder \r\n, "" als maskiertes Anführungszeichen. */
export function parseCsv(text: string, delimiter: Delimiter): string[][] {
  const rows: string[][] = [];
  let row: string[] = [];
  let field = '';
  let quoted = false;

  for (let i = 0; i < text.length; i++) {
    const char = text[i];
    if (quoted) {
      if (char === '"') {
        if (text[i + 1] === '"') {
          field += '"';
          i++;
        } else {
          quoted = false;
        }
      } else {
        field += char;
      }
    } else if (char === '"') {
      quoted = true;
    } else if (char === delimiter) {
      row.push(field);
      field = '';
    } else if (char === '\n' || char === '\r') {
      if (char === '\r' && text[i + 1] === '\n') {
        i++;
      }
      row.push(field);
      rows.push(row);
      row = [];
      field = '';
    } else {
      field += char;
    }
  }
  if (field !== '' || row.length > 0) {
    row.push(field);
    rows.push(row);
  }
  return rows;
}

// ---------------------------------------------------------------------
// Beträge
// ---------------------------------------------------------------------

const AMOUNT_LIMIT = 1_000_000_000_000;

/** Kaufmännisch auf Cent runden, symmetrisch um 0 (−12,345 → −12,35). */
export function roundCents(value: number): number {
  const cents = Math.round(Math.abs(value) * 100 + 1e-7);
  return cents === 0 ? 0 : (Math.sign(value) * cents) / 100;
}

/**
 * Betrag aus deutscher (oder englischer) Schreibweise, auf Cent gerundet;
 * null, wenn keine eindeutige Zahl. Beispiele: "1.234,56", "-12,50 €",
 * "12,50-", "12,50 S" (Soll = negativ), "+1.000", "1,234.56", 12.5 (Excel).
 */
export function parseAmount(raw: string | number | null | undefined): number | null {
  if (typeof raw === 'number') {
    return Number.isFinite(raw) && Math.abs(raw) < AMOUNT_LIMIT ? roundCents(raw) : null;
  }
  if (raw == null) {
    return null;
  }
  let text = raw.replace(/[\s  ']/g, '').replace(/€|eur(o)?/gi, '');
  if (text === '') {
    return null;
  }

  let sign = 1;
  // Soll/Haben-Kennzeichen am Ende (z. B. Postbank, Volksbank).
  const debitCredit = /^(.*?)([SH])$/i.exec(text);
  if (debitCredit) {
    text = debitCredit[1] ?? '';
    sign = debitCredit[2]?.toUpperCase() === 'S' ? -1 : 1;
  }
  // Vorzeichen vorne oder hinten.
  const signMatch = /^([+-]?)(.*?)([+-]?)$/.exec(text);
  const [, leading = '', body = '', trailing = ''] = signMatch ?? [];
  if (leading && trailing) {
    return null;
  }
  if (leading === '-' || trailing === '-') {
    sign = -sign;
  }
  text = body;

  if (!/^[\d.,]+$/.test(text) || !/\d/.test(text)) {
    return null;
  }

  const split = splitNumber(text);
  if (!split) {
    return null;
  }
  const [integerPart, decimals] = split;
  if (!/^\d+$/.test(integerPart || '0') || !/^\d{0,2}$/.test(decimals)) {
    return null;
  }
  const value = Number(`${integerPart || '0'}.${decimals || '0'}`);
  if (!Number.isFinite(value) || value >= AMOUNT_LIMIT) {
    return null;
  }
  return roundCents(sign * value);
}

/**
 * Ganzzahl- und Nachkommateil aus Ziffern mit Punkt/Komma; null bei
 * mehrdeutiger oder ungültiger Gruppierung.
 */
function splitNumber(text: string): [string, string] | null {
  const lastComma = text.lastIndexOf(',');
  const lastDot = text.lastIndexOf('.');
  if (lastComma !== -1 && lastDot !== -1) {
    // Beide vorhanden: das hintere ist das Dezimaltrennzeichen.
    const decimalSeparator = lastComma > lastDot ? ',' : '.';
    const thousandsSeparator = decimalSeparator === ',' ? '.' : ',';
    const parts = text.split(decimalSeparator);
    const head = parts[0] ?? '';
    if (parts.length !== 2 || !new RegExp(`^\\d{1,3}(\\${thousandsSeparator}\\d{3})*$`).test(head)) {
      return null;
    }
    return [head.split(thousandsSeparator).join(''), parts[1] ?? ''];
  }
  if (lastComma !== -1) {
    // Nur Komma: deutsches Dezimaltrennzeichen.
    const parts = text.split(',');
    return parts.length === 2 ? [parts[0] ?? '', parts[1] ?? ''] : null;
  }
  if (lastDot !== -1) {
    // Nur Punkt: Tausendertrennzeichen (1.234 / 1.234.567) oder Dezimalpunkt (12.50).
    if (/^\d{1,3}(\.\d{3})+$/.test(text)) {
      return [text.split('.').join(''), ''];
    }
    const parts = text.split('.');
    return parts.length === 2 ? [parts[0] ?? '', parts[1] ?? ''] : null;
  }
  return [text, ''];
}

// ---------------------------------------------------------------------
// Datum
// ---------------------------------------------------------------------

/**
 * Datum als 'YYYY-MM-DD' aus TT.MM.JJJJ, TT.MM.JJ (→ 20JJ), JJJJ-MM-TT
 * oder einem Date-Objekt (Excel, Kalendertag in UTC); null bei ungültigem
 * Kalenderdatum.
 */
export function parseDate(raw: string | Date | number | null | undefined): string | null {
  if (raw instanceof Date) {
    if (Number.isNaN(raw.getTime())) {
      return null;
    }
    const iso = `${raw.getUTCFullYear()}-${String(raw.getUTCMonth() + 1).padStart(2, '0')}-${String(raw.getUTCDate()).padStart(2, '0')}`;
    return parseIsoDate(iso);
  }
  if (typeof raw !== 'string') {
    return null;
  }
  const text = raw.trim();
  const german = /^(\d{1,2})\.(\d{1,2})\.(\d{2}|\d{4})$/.exec(text);
  if (german) {
    const [, d = '', m = '', y = ''] = german;
    const year = y.length === 2 ? `20${y}` : y;
    return parseIsoDate(`${year}-${m.padStart(2, '0')}-${d.padStart(2, '0')}`);
  }
  const iso = /^(\d{4})-(\d{2})-(\d{2})(?:[T ].*)?$/.exec(text);
  if (iso) {
    return parseIsoDate(`${iso[1]}-${iso[2]}-${iso[3]}`);
  }
  return null;
}
