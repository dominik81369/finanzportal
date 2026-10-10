/**
 * lib/import/n26-pdf.ts
 *
 * Kontoauszug von N26 als PDF (monatlich „Kontoauszug Nr. MM/JJJJ“ oder
 * „Vorläufiger Kontoauszug“) in Buchungen je Konto zerlegen. Eine PDF
 * enthält das Hauptkonto und alle Spaces, jeweils mit eigener IBAN im
 * Seitenfuß; zu jedem Konto gehören Buchungsseiten und eine
 * Zusammenfassung (alter Stand, Aus- und Eingänge, neuer Stand).
 *
 * Aufbau einer Buchung (Positionen aus pdf.js, siehe ./pdf-text.ts):
 *   Gegenpartei (große Schrift, ggf. mehrzeilig) | Verbuchungsdatum | Betrag
 *   Art-Zeile („Mastercard • Lebensmittel“, „Lastschriften“ …; fehlt bei
 *     internen Buchungen „An <Space>“ / „Von Hauptkonto“)
 *   „IBAN: … • BIC: …“ (optional)
 *   Verwendungszweck (0–n Zeilen, auch über einen Seitenumbruch)
 *   „Wertstellung TT.MM.JJJJ“
 *
 * Seitenkopf (Titel, Space, Zeitraum, Spaltenkopf) und Seitenfuß (Name,
 * Adresse, IBAN, Seitenzahl) werden über ihre Position ausgeblendet;
 * „Anmerkung“ und Rechnungsabschluss tragen keine Buchungen.
 *
 * Prüfung je Konto: alter Stand + Eingänge − Ausgänge = neuer Stand, und
 * die gelesenen Buchungen ergeben genau Ein- und Ausgänge der
 * Zusammenfassung. Jede Abweichung ist ein Fehler (kein Teilimport).
 *
 * Reine Funktionen (ohne pdf.js), in Tests direkt nutzbar.
 */
import { COUNTERPARTY_MAX_LENGTH, PURPOSE_MAX_LENGTH } from '@/lib/transactions';

import { TRANSACTION_TYPE_MAX_LENGTH, normalizeIban, type ImportRow } from '@/lib/import/statement';

export type PdfTextItem = { text: string; x: number; y: number; width: number; size: number };
export type PdfPage = { items: PdfTextItem[] };

export type N26Section = {
  iban: string;
  bic: string | null;
  kind: 'main' | 'space';
  /** Name des Space; null beim Hauptkonto. */
  name: string | null;
  /** Beträge in Euro (zwei Nachkommastellen); outgoing ist negativ. */
  opening: number;
  incoming: number;
  outgoing: number;
  closing: number;
  rows: ImportRow[];
  /** Buchungen mit Betrag 0 (nicht importiert). */
  skippedZero: number;
};

export type N26Statement = {
  provisional: boolean;
  /** „09/2026“ beim Monatsauszug, sonst null. */
  number: string | null;
  period: { from: string; to: string };
  sections: N26Section[];
};

export type N26Error =
  | { code: 'notN26' }
  | { code: 'noSections' }
  | { code: 'layout'; page: number; text: string }
  | { code: 'missingSummary'; iban: string; name: string | null }
  | {
      code: 'balanceMismatch';
      iban: string;
      name: string | null;
      opening: number;
      incoming: number;
      outgoing: number;
      closing: number;
    }
  | {
      code: 'sumMismatch';
      iban: string;
      name: string | null;
      direction: 'incoming' | 'outgoing';
      expected: number;
      actual: number;
    };

export type N26Result = { ok: true; statement: N26Statement } | { ok: false; error: N26Error };

const N26_BIC = /^NTSB/;
const DATE = /^(\d{2})\.(\d{2})\.(\d{4})$/;
const PERIOD = /^(\d{2}\.\d{2}\.\d{4}) bis (\d{2}\.\d{2}\.\d{4})$/;
const FOOTER_IBAN = /^(Space )?IBAN: ([A-Z]{2}[0-9]{2}[0-9A-Z ]{11,40}?) • BIC: ([A-Z0-9]{8,11})\b/;
const BOOKING_IBAN = /^IBAN: ([A-Z]{2}[0-9]{2}[0-9A-Z ]{11,40}?)(?: • BIC: ([A-Z0-9]{8,11}))?$/;
const VALUE_DATE = /^Wertstellung (\d{2}\.\d{2}\.\d{4})$/;
const INTERNAL = /^(An|Von) (.+)$/;
/**
 * Art-Zeilen von N26: Karte (mit Kartenkategorie nach „•“) sowie die
 * Buchungsarten im Plural („Lastschriften“, „Gutschriften“ …).
 */
const TYPE_LINE =
  /^(?:(?:Mastercard|Maestro|Visa)(?: • .+)?|(?:Lastschrift|Gutschrift|Belastung|Überweisung|Echtzeitüberweisung|Dauerauftr[aä]g|Gebühr|Zins|Rücklastschrift|Rückbuchung|Barabhebung|Bargeldabhebung|Bargeldeinzahlung|MoneyBeam)(?:en|e)?)$/;

const SUMMARY_LABELS = {
  opening: /^Dein alter Kontostand$/,
  outgoing: /^Ausgehende Transaktionen$/,
  incoming: /^(Einkommende|Eingehende) Transaktionen$/,
  closing: /^Dein neuer Kontostand$/,
} as const;

/** „+1.900,00€“, „-19,99€“, „0,00€“ → Cent; sonst null. */
export function parseEuroCents(text: string): number | null {
  const match = /^([+\-−])?\s?(\d{1,3}(?:\.\d{3})*|\d+),(\d{2})\s?€$/.exec(text.replace(/ /g, ' ').trim());
  if (!match) {
    return null;
  }
  const cents = Number(match[2]!.replace(/\./g, '')) * 100 + Number(match[3]);
  return match[1] === '-' || match[1] === '−' ? -cents : cents;
}

/** „01.10.2026“ → „2026-10-01“ (gültiges Datum), sonst null. */
export function parseGermanDate(text: string): string | null {
  const match = DATE.exec(text.trim());
  if (!match) {
    return null;
  }
  const [, day, month, year] = match;
  const iso = `${year}-${month}-${day}`;
  const date = new Date(`${iso}T00:00:00Z`);
  return Number.isNaN(date.getTime()) || date.toISOString().slice(0, 10) !== iso ? null : iso;
}

const euros = (cents: number) => Math.round(cents) / 100;

function clip(text: string, max: number): string | null {
  const value = text.replace(/\s+/g, ' ').trim();
  return value === '' ? null : value.slice(0, max);
}

/** Vergleichsform eines Kontonamens („Ulmer  Straße 3“ = „ulmer straße 3“). */
function nameKey(text: string): string {
  return text.replace(/\s+/g, ' ').trim().toLocaleLowerCase('de-DE');
}

type Line = { text: string; x: number; y: number; size: number };

/** Textstücke derselben Grundlinie zu Zeilen zusammenfassen (von oben nach unten). */
function toLines(items: PdfTextItem[]): Line[] {
  const sorted = [...items].sort((a, b) => b.y - a.y || a.x - b.x);
  const lines: { items: PdfTextItem[]; y: number }[] = [];
  for (const item of sorted) {
    const line = lines[lines.length - 1];
    if (line && Math.abs(line.y - item.y) < 1) {
      line.items.push(item);
    } else {
      lines.push({ items: [item], y: item.y });
    }
  }
  return lines.map((line) => {
    const parts = line.items.sort((a, b) => a.x - b.x);
    let text = '';
    let end: number | null = null;
    for (const part of parts) {
      text += end !== null && part.x - end > 1 ? ` ${part.text}` : part.text;
      end = part.x + part.width;
    }
    return {
      text: text.replace(/\s+/g, ' ').trim(),
      x: parts[0]!.x,
      y: line.y,
      size: Math.max(...parts.map((p) => p.size)),
    };
  });
}

type PageInfo =
  | { kind: 'ignore' }
  | {
      kind: 'bookings' | 'summary';
      title: string;
      iban: string;
      bic: string;
      space: boolean;
      name: string | null;
      period: { from: string; to: string } | null;
      body: Line[];
      /** Grenze zwischen Beschreibung und Datum/Betrag (x). */
      split: number;
    };

function readPage(page: PdfPage, pageNumber: number): PageInfo | N26Error {
  const lines = toLines(page.items);
  if (lines.length === 0) {
    return { kind: 'ignore' };
  }
  const titleSize = Math.max(...lines.map((line) => line.size));
  const title = lines.find((line) => line.size === titleSize)!.text;

  // Seitenfuß: ab der Zeile „… Erstellt am“ (Name, Adresse, IBAN, Seitenzahl).
  const footerIban = [...lines].reverse().find((line) => FOOTER_IBAN.test(line.text));
  const createdOn = lines.find((line) => /Erstellt am$/.test(line.text));
  const footerTop = createdOn ? createdOn.y : footerIban ? footerIban.y + 32 : null;

  const header = lines.find((line) => /^Beschreibung\b/.test(line.text));
  const hasBookings = header !== undefined && /Verbuchungsdatum/.test(header.text);
  const hasSummary = page.items.some((item) => SUMMARY_LABELS.opening.test(item.text.trim()));
  if (!header || (!hasBookings && !hasSummary)) {
    return { kind: 'ignore' };
  }
  if (!footerIban || footerTop === null) {
    return { code: 'layout', page: pageNumber, text: title };
  }
  const footer = FOOTER_IBAN.exec(footerIban.text)!;
  const iban = normalizeIban(footer[2]!);
  if (!iban) {
    return { code: 'layout', page: pageNumber, text: footerIban.text };
  }

  const above = lines.filter((line) => line.y > header.y + 1);
  const spaceLine = above.find((line) => /^Space: /.test(line.text));
  const periodLine = above.find((line) => PERIOD.test(line.text));
  const periodMatch = periodLine ? PERIOD.exec(periodLine.text) : null;
  const from = periodMatch ? parseGermanDate(periodMatch[1]!) : null;
  const to = periodMatch ? parseGermanDate(periodMatch[2]!) : null;

  // Spaltengrenze: Beginn der Spalte „Verbuchungsdatum“ (Zusammenfassung:
  // Seitenmitte), Beträge stehen rechts davon.
  const headerParts = page.items.filter((item) => Math.abs(item.y - header.y) < 1);
  const dateColumn = headerParts.find((item) => /^Verbuchungsdatum/.test(item.text.trim()));
  const split = dateColumn ? dateColumn.x - 10 : 300;

  // Rumpf: zwischen Spaltenkopf und Fuß, Textstücke einzeln (Datum und
  // Betrag stehen auf eigener Grundlinie neben der Gegenpartei).
  const bodyItems = page.items.filter((item) => item.y < header.y - 1 && item.y > footerTop + 1);
  const body = [
    ...toLines(bodyItems.filter((item) => item.x < split)),
    ...bodyItems
      .filter((item) => item.x >= split)
      .map((item) => ({ text: item.text.trim(), x: item.x, y: item.y, size: item.size })),
  ].sort((a, b) => b.y - a.y || a.x - b.x);

  return {
    kind: hasBookings ? 'bookings' : 'summary',
    title,
    iban,
    bic: footer[3]!,
    space: footer[1] !== undefined,
    name: spaceLine ? spaceLine.text.slice('Space: '.length).trim() : null,
    period: from && to ? { from, to } : null,
    body,
    split,
  };
}

type Draft = {
  bookingDate: string;
  cents: number;
  size: number;
  counterparty: string[];
  type: string | null;
  iban: string | null;
  purpose: string[];
  valueDate: string | null;
  done: boolean;
  /** Schon eine kleine Zeile (Art, IBAN, Zweck) gelesen. */
  details: boolean;
};

type SectionDraft = {
  iban: string;
  bic: string;
  kind: 'main' | 'space';
  name: string | null;
  drafts: Draft[];
  summary: Partial<Record<keyof typeof SUMMARY_LABELS, number>> | null;
};

/** Seiten eines N26-Kontoauszugs in Konten und Buchungen zerlegen und prüfen. */
export function parseN26Statement(pages: PdfPage[]): N26Result {
  const sections = new Map<string, SectionDraft>();
  let provisional = false;
  let number: string | null = null;
  let period: { from: string; to: string } | null = null;
  let isN26 = false;
  let open: { section: SectionDraft; draft: Draft } | null = null;

  for (const [index, page] of pages.entries()) {
    const pageNumber = index + 1;
    const info = readPage(page, pageNumber);
    if ('code' in info) {
      return { ok: false, error: info };
    }
    if (info.kind === 'ignore') {
      continue;
    }
    if (!N26_BIC.test(info.bic)) {
      return { ok: false, error: { code: 'notN26' } };
    }
    isN26 = true;
    if (/^Vorläufige/.test(info.title)) {
      provisional = true;
    }
    number ??= /Nr\. (\d{2}\/\d{4})/.exec(info.title)?.[1] ?? null;
    period ??= info.period;

    let section = sections.get(info.iban);
    if (!section) {
      section = {
        iban: info.iban,
        bic: info.bic,
        kind: info.space ? 'space' : 'main',
        name: info.name,
        drafts: [],
        summary: null,
      };
      sections.set(info.iban, section);
    }
    if (open && open.section !== section) {
      open = null;
    }

    if (info.kind === 'summary') {
      open = null;
      const values: Partial<Record<keyof typeof SUMMARY_LABELS, number>> = {};
      for (const line of info.body.filter((l) => l.x < info.split)) {
        for (const [key, pattern] of Object.entries(SUMMARY_LABELS) as [keyof typeof SUMMARY_LABELS, RegExp][]) {
          if (pattern.test(line.text)) {
            const value = info.body.find((other) => other.x >= info.split && Math.abs(other.y - line.y) < 4);
            const cents = value ? parseEuroCents(value.text) : null;
            if (cents === null) {
              return { ok: false, error: { code: 'layout', page: pageNumber, text: line.text } };
            }
            values[key] = cents;
          }
        }
      }
      if (Object.keys(values).length !== Object.keys(SUMMARY_LABELS).length) {
        return { ok: false, error: { code: 'layout', page: pageNumber, text: info.title } };
      }
      section.summary = values;
      continue;
    }

    // Buchungsseite
    const left = info.body.filter((line) => line.x < info.split);
    const right = info.body.filter((line) => line.x >= info.split);
    const used = new Set<(typeof right)[number]>();
    for (const line of left) {
      const near = right.filter((value) => !used.has(value) && Math.abs(value.y - line.y) < 4);
      const date = near.find((value) => DATE.test(value.text));
      const amount = near.find((value) => parseEuroCents(value.text) !== null);
      if (date && amount) {
        used.add(date);
        used.add(amount);
        const bookingDate = parseGermanDate(date.text);
        if (!bookingDate) {
          return { ok: false, error: { code: 'layout', page: pageNumber, text: date.text } };
        }
        const draft: Draft = {
          bookingDate,
          cents: parseEuroCents(amount.text)!,
          size: line.size,
          counterparty: [line.text],
          type: null,
          iban: null,
          purpose: [],
          valueDate: null,
          done: false,
          details: false,
        };
        section.drafts.push(draft);
        open = { section, draft };
        continue;
      }
      if (!open) {
        return { ok: false, error: { code: 'layout', page: pageNumber, text: line.text } };
      }
      const draft = open.draft;
      // Unbekannte Zusatzzeile nach der Wertstellung: zum Verwendungszweck.
      if (draft.done) {
        draft.purpose.push(line.text);
        continue;
      }
      const valueDate = VALUE_DATE.exec(line.text);
      if (valueDate) {
        draft.valueDate = parseGermanDate(valueDate[1]!);
        draft.done = true;
        continue;
      }
      // Weitere Zeile der Gegenpartei: gleiche Schriftgröße, vor den Details.
      if (!draft.details && line.size >= draft.size - 0.5) {
        draft.counterparty.push(line.text);
        continue;
      }
      if (!draft.details && TYPE_LINE.test(line.text)) {
        draft.type = line.text;
      } else if (draft.iban === null && draft.purpose.length === 0 && BOOKING_IBAN.test(line.text)) {
        draft.iban = normalizeIban(BOOKING_IBAN.exec(line.text)![1]!);
      } else {
        draft.purpose.push(line.text);
      }
      draft.details = true;
    }
    const stray = right.find((value) => !used.has(value));
    if (stray) {
      return { ok: false, error: { code: 'layout', page: pageNumber, text: stray.text } };
    }
  }

  if (!isN26) {
    return { ok: false, error: { code: 'notN26' } };
  }
  if (sections.size === 0 || !period) {
    return { ok: false, error: { code: 'noSections' } };
  }

  // Interne Buchungen („An Ulmer Straße 3“, „Von Hauptkonto“): Konto
  // im selben Auszug suchen und dessen IBAN als Gegenkonto setzen.
  const byName = new Map<string, string>();
  for (const section of sections.values()) {
    byName.set(section.kind === 'main' ? 'hauptkonto' : nameKey(section.name ?? ''), section.iban);
  }

  const result: N26Section[] = [];
  for (const section of sections.values()) {
    const summary = section.summary;
    if (
      !summary ||
      summary.opening === undefined ||
      summary.incoming === undefined ||
      summary.outgoing === undefined ||
      summary.closing === undefined
    ) {
      return { ok: false, error: { code: 'missingSummary', iban: section.iban, name: section.name } };
    }
    const { opening, incoming, outgoing, closing } = summary;
    // N26 schreibt Ausgänge mit Minus; ohne Vorzeichen als Abgang werten.
    const out = -Math.abs(outgoing);
    if (opening + incoming + out !== closing) {
      return {
        ok: false,
        error: {
          code: 'balanceMismatch',
          iban: section.iban,
          name: section.name,
          opening: euros(opening),
          incoming: euros(incoming),
          outgoing: euros(out),
          closing: euros(closing),
        },
      };
    }
    const sumIn = section.drafts.filter((d) => d.cents > 0).reduce((sum, d) => sum + d.cents, 0);
    const sumOut = section.drafts.filter((d) => d.cents < 0).reduce((sum, d) => sum + d.cents, 0);
    if (sumIn !== incoming || sumOut !== out) {
      const direction = sumIn !== incoming ? 'incoming' : 'outgoing';
      return {
        ok: false,
        error: {
          code: 'sumMismatch',
          iban: section.iban,
          name: section.name,
          direction,
          expected: euros(direction === 'incoming' ? incoming : out),
          actual: euros(direction === 'incoming' ? sumIn : sumOut),
        },
      };
    }

    const rows: ImportRow[] = [];
    let skippedZero = 0;
    for (const draft of section.drafts) {
      if (draft.cents === 0) {
        skippedZero += 1;
        continue;
      }
      const counterparty = draft.counterparty.join(' ');
      let counterpartyIban = draft.iban;
      if (counterpartyIban === null && draft.type === null) {
        const internal = INTERNAL.exec(counterparty.trim());
        const target = internal ? byName.get(nameKey(internal[2]!)) : undefined;
        if (target && target !== section.iban) {
          counterpartyIban = target;
        }
      }
      rows.push({
        booking_date: draft.bookingDate,
        value_date: draft.valueDate,
        amount: euros(draft.cents),
        currency: 'EUR',
        counterparty: clip(counterparty, COUNTERPARTY_MAX_LENGTH),
        purpose: clip(draft.purpose.join(' '), PURPOSE_MAX_LENGTH),
        transaction_type: draft.type ? clip(draft.type, TRANSACTION_TYPE_MAX_LENGTH) : null,
        counterparty_iban: counterpartyIban,
        description: null,
        mandate_reference: null,
        creditor_id: null,
      });
    }

    result.push({
      iban: section.iban,
      bic: section.bic,
      kind: section.kind,
      name: section.name,
      opening: euros(opening),
      incoming: euros(incoming),
      outgoing: euros(out),
      closing: euros(closing),
      rows,
      skippedZero,
    });
  }

  // Hauptkonto zuerst, Spaces in der Reihenfolge der PDF.
  result.sort((a, b) => (a.kind === b.kind ? 0 : a.kind === 'main' ? -1 : 1));
  return { ok: true, statement: { provisional, number, period, sections: result } };
}

/** Kartenkategorie aus der Art-Zeile („Mastercard • Lebensmittel“ → „Lebensmittel“). */
export function cardCategory(transactionType: string | null): string | null {
  const match = /^(?:Mastercard|Maestro|Visa) • (.+)$/.exec(transactionType ?? '');
  return match ? match[1]!.trim() : null;
}
