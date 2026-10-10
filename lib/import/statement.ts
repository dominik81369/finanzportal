/**
 * lib/import/statement.ts
 *
 * Aus den Zellen eines Kontoauszugs (CSV oder Excel, siehe ./parse.ts) die
 * Buchungen gewinnen:
 *
 * 1. findHeaderRow():   Kopfzeile per Schlüsselwortsuche – nicht fest Zeile 1,
 *                       weil manche Banken (z. B. DKB) Meta-Zeilen davor setzen.
 * 2. detectColumns():   Spalten über ein Alias-Wörterbuch zuordnen; nicht
 *                       eindeutig → confident = false (die Oberfläche zeigt
 *                       dann die manuelle Zuordnung statt eines Fehlers).
 * 3. buildRows():       Zeilen normalisieren (Datum, Betrag), Fehler je Zeile
 *                       sammeln, Salden aus Meta-Zeilen bzw. Saldo-Spalte
 *                       lesen und die Summe dagegen prüfen. Vorgemerkte
 *                       Umsätze (Buchungsstatus, z. B. „Umsatz vorgemerkt“)
 *                       werden nicht übernommen, nur gezählt.
 *
 * Reine Funktionen, im Browser (Vorschau) und in Tests nutzbar. Der Server
 * prüft die Zeilen beim Import erneut (public.import_transactions).
 */
import { COUNTERPARTY_MAX_LENGTH, PURPOSE_MAX_LENGTH } from '@/lib/transactions';

import { parseAmount, parseDate, roundCents } from '@/lib/import/parse';

/** Höchstzahl Buchungen je Import (Grenze von public.import_transactions). */
export const MAX_IMPORT_ROWS = 5000;

/** Eine Zelle: Text (CSV), Zahl oder Datum (Excel), leer. */
export type Cell = string | number | Date | boolean | null;

export const IMPORT_FIELDS = [
  'date',
  'amount',
  'purpose',
  'counterparty',
  'valueDate',
  'currency',
  'balance',
  'transactionType',
  'counterpartyIban',
  'description',
  'mandateReference',
  'creditorId',
  'bookingStatus',
] as const;
export type ImportField = (typeof IMPORT_FIELDS)[number];
export const REQUIRED_FIELDS: readonly ImportField[] = ['date', 'amount', 'purpose'];

/** Spaltenindex je Feld; null = nicht vorhanden. */
export type ColumnMapping = Record<ImportField, number | null>;

/**
 * Alias-Wörterbuch, je Feld in absteigender Präferenz (normalisierte
 * Schreibweise, siehe normalizeLabel). Ein früherer Alias schlägt einen
 * späteren: „Buchungstag“ wird Datum, „Wertstellung“ dann Valutadatum.
 */
export const COLUMN_ALIASES: Record<ImportField, readonly string[]> = {
  date: ['buchungstag', 'buchungsdatum', 'datum', 'buchung', 'belegdatum', 'wertstellung', 'valuta', 'valutadatum'],
  valueDate: ['wertstellung', 'valuta', 'valutadatum', 'wertstellungsdatum'],
  amount: ['betrag', 'umsatz', 'buchungsbetrag', 'umsatz in', 'betrag in'],
  purpose: ['verwendungszweck', 'beschreibung', 'buchungstext', 'umsatztext', 'vorgang/verwendungszweck', 'text'],
  counterparty: [
    'beguenstigter/zahlungspflichtiger',
    'zahlungsempfaenger',
    'zahlungspflichtige',
    'auftraggeber / beguenstigter',
    'auftraggeber/beguenstigter',
    'auftraggeber/empfaenger',
    'name zahlungsbeteiligter',
    'beguenstigter',
    'auftraggeber',
    'empfaenger',
    'gegenkonto name',
    'name',
  ],
  currency: ['waehrung', 'currency'],
  balance: ['saldo', 'kontostand'],
  // „Buchungstext“ ist bei Dateien mit eigenem Verwendungszweck die
  // Buchungsart (Sparkasse), sonst der Zweck selbst (purpose greift zuerst).
  transactionType: [
    'umsatztyp',
    'buchungsart',
    'transaktionstyp',
    'umsatzart',
    'vorgang',
    'buchungstext',
    'typ',
  ],
  counterpartyIban: [
    'iban',
    'iban zahlungsbeteiligter',
    'kontonummer/iban',
    'iban auftraggeber/empfaenger',
    'iban empfaenger',
    'iban auftraggeber',
    'gegenkonto iban',
    'empfaenger iban',
  ],
  // Nur zusätzlich zum Verwendungszweck – allein ist „Beschreibung“ der Zweck.
  description: ['beschreibung'],
  // SEPA-Lastschrift (DKB, Sparkasse CSV-CAMT u. a.).
  mandateReference: ['mandatsreferenz', 'mandatsref', 'mandat', 'mandate reference'],
  creditorId: ['glaeubiger id', 'glaeubigerid', 'glaeubiger identifikationsnummer', 'glaeubiger identifikation', 'creditor id'],
  // „Umsatz gebucht“ / „Umsatz vorgemerkt“ (Sparkasse), „Gebucht“ / „Vorgemerkt“ (DKB).
  bookingStatus: ['status', 'buchungsstatus', 'umsatzstatus', 'info'],
};

/**
 * Spaltenüberschrift vergleichbar machen: Kleinschreibung, Umlaute
 * ausgeschrieben, Klammerzusätze („(€)“, „(EUR)“), Gendersternchen und
 * Währungsangaben entfernt, Leerraum zusammengefasst.
 */
export function normalizeLabel(label: Cell): string {
  return String(label ?? '')
    .toLowerCase()
    .replace(/ä/g, 'ae')
    .replace(/ö/g, 'oe')
    .replace(/ü/g, 'ue')
    .replace(/ß/g, 'ss')
    .replace(/\([^)]*\)/g, ' ')
    .replace(/\*in(nen)?\b|:in(nen)?\b/g, '')
    .replace(/\b(eur|euro)\b|€/g, ' ')
    .replace(/[^a-z0-9/ ]+/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

/** Rang eines Alias für eine Überschrift (0 = bester), null = kein Treffer. */
function aliasRank(field: ImportField, label: string): number | null {
  const aliases = COLUMN_ALIASES[field];
  for (let i = 0; i < aliases.length; i++) {
    const alias = aliases[i];
    if (label === alias) {
      return i * 2;
    }
    // Alias als Wortanfang, z. B. „betrag eur“ → betrag, „umsatz in eur“.
    if (label.startsWith(`${alias} `)) {
      return i * 2 + 1;
    }
  }
  return null;
}

const HEADER_SEARCH_ROWS = 60;

/**
 * Index der Kopfzeile: die erste Zeile mit Datums- UND Betragsspalte; sonst
 * die Zeile mit den meisten Alias-Treffern (mindestens zwei). null = keine.
 */
export function findHeaderRow(rows: Cell[][]): number | null {
  let best: { index: number; score: number } | null = null;
  const limit = Math.min(rows.length, HEADER_SEARCH_ROWS);
  for (let index = 0; index < limit; index++) {
    const labels = (rows[index] ?? []).map(normalizeLabel);
    const matches = (field: ImportField) => labels.some((label) => aliasRank(field, label) !== null);
    const score = IMPORT_FIELDS.filter(matches).length;
    if (matches('date') && matches('amount')) {
      return index;
    }
    if (score >= 2 && (!best || score > best.score)) {
      best = { index, score };
    }
  }
  return best?.index ?? null;
}

export type ColumnDetection = {
  mapping: ColumnMapping;
  /** Alle Pflichtfelder gefunden und keines mehrdeutig. */
  confident: boolean;
  /** Pflichtfelder, die fehlen. */
  missing: ImportField[];
  /** Felder, für die mehrere Spalten gleich gut passen. */
  ambiguous: ImportField[];
};

/**
 * Spalten der Kopfzeile den Feldern zuordnen. Jede Spalte höchstens einmal;
 * Pflichtfelder zuerst, damit z. B. „Wertstellung“ als Datum nur greift,
 * wenn es keinen „Buchungstag“ gibt.
 */
export function detectColumns(header: Cell[]): ColumnDetection {
  const labels = header.map(normalizeLabel);
  const mapping = Object.fromEntries(IMPORT_FIELDS.map((f) => [f, null])) as ColumnMapping;
  const used = new Set<number>();
  const ambiguous: ImportField[] = [];

  const order: ImportField[] = [
    'date',
    'amount',
    'purpose',
    'counterparty',
    'transactionType',
    'counterpartyIban',
    'valueDate',
    'currency',
    'balance',
    'description',
    'mandateReference',
    'creditorId',
    'bookingStatus',
  ];
  for (const field of order) {
    let bestRank: number | null = null;
    let candidates: number[] = [];
    labels.forEach((label, index) => {
      if (used.has(index)) {
        return;
      }
      const rank = aliasRank(field, label);
      if (rank === null) {
        return;
      }
      if (bestRank === null || rank < bestRank) {
        bestRank = rank;
        candidates = [index];
      } else if (rank === bestRank) {
        candidates.push(index);
      }
    });
    const [first] = candidates;
    if (first !== undefined) {
      mapping[field] = first;
      used.add(first);
      if (candidates.length > 1 && REQUIRED_FIELDS.includes(field)) {
        ambiguous.push(field);
      }
    }
  }

  const missing = REQUIRED_FIELDS.filter((field) => mapping[field] === null);
  return { mapping, confident: missing.length === 0 && ambiguous.length === 0, missing, ambiguous };
}

// ---------------------------------------------------------------------
// Zeilen
// ---------------------------------------------------------------------

/** Eine normalisierte Buchung – so geht sie an public.import_transactions. */
export type ImportRow = {
  booking_date: string;
  value_date: string | null;
  amount: number;
  currency: string | null;
  counterparty: string | null;
  purpose: string | null;
  transaction_type: string | null;
  counterparty_iban: string | null;
  description: string | null;
  mandate_reference: string | null;
  creditor_id: string | null;
};

export type RowError = {
  /** 1-basierte Zeilennummer in der Datei (bzw. im Tabellenblatt). */
  line: number;
  reason: 'invalidDate' | 'invalidAmount';
  value: string;
};

export type StatementBalances = {
  /** Anfangssaldo laut Datei (Meta-Zeile oder aus Saldo-Spalte berechnet). */
  opening: number | null;
  /** Endsaldo laut Datei. */
  closing: number | null;
};

export type BalanceCheck =
  | { status: 'none' }
  /** Nur Endsaldo bekannt – Abgleich nach dem Import gegen den Kontostand. */
  | { status: 'closingOnly'; closing: number }
  | { status: 'ok'; opening: number; closing: number; sum: number }
  | { status: 'mismatch'; opening: number; closing: number; sum: number; difference: number };

export type BuiltStatement = {
  rows: ImportRow[];
  errors: RowError[];
  /** Zeilen mit Betrag 0 (reine Info-Buchungen), nicht importiert. */
  skippedZero: number;
  /** Vorgemerkte Umsätze, nicht importiert (kommen gebucht mit dem nächsten Auszug). */
  skippedPending: number;
  /** Summe aller Beträge der Datei (in Cent gerundet). */
  sum: number;
  balances: StatementBalances;
  balanceCheck: BalanceCheck;
};

function cellText(cell: Cell | undefined): string {
  if (cell == null) {
    return '';
  }
  if (cell instanceof Date) {
    return cell.toISOString().slice(0, 10);
  }
  return String(cell).trim();
}

function isEmptyRow(row: Cell[]): boolean {
  return row.every((cell) => cellText(cell) === '');
}

function clip(text: string, max: number): string | null {
  const value = text.replace(/\s+/g, ' ').trim();
  return value === '' ? null : value.slice(0, max);
}

export const TRANSACTION_TYPE_MAX_LENGTH = 100;

/**
 * IBAN in Großbuchstaben ohne Leerzeichen; keine gültige Form (manche Banken
 * liefern dort Kontonummern) → null. Die Prüfsumme prüfen wir nicht.
 */
export function normalizeIban(text: string): string | null {
  const iban = text.replace(/\s+/g, '').toUpperCase();
  return /^[A-Z]{2}[0-9]{2}[0-9A-Z]{11,30}$/.test(iban) ? iban : null;
}

/** IBAN zur Anzeige in Vierergruppen („DE89 3704 0044 …“). */
export function formatIban(iban: string): string {
  return iban.replace(/\s+/g, '').replace(/(.{4})(?=.)/g, '$1 ');
}

/** SEPA-Mandatsreferenz: höchstens 35 Zeichen, sonst null (dann liest der Server sie aus dem Zweck). */
export const MANDATE_REFERENCE_MAX_LENGTH = 35;

export function normalizeMandateReference(text: string): string | null {
  const value = text.replace(/\s+/g, ' ').trim();
  return value !== '' && value.length <= MANDATE_REFERENCE_MAX_LENGTH ? value : null;
}

/** Gläubiger-ID in Großbuchstaben ohne Leerzeichen (z. B. DE98ZZZ09999999999), sonst null. */
export function normalizeCreditorId(text: string): string | null {
  const id = text.replace(/\s+/g, '').toUpperCase();
  return /^[A-Z]{2}[0-9]{2}[A-Z0-9]{3}[A-Z0-9]{1,28}$/.test(id) ? id : null;
}

/**
 * Vorgemerkter (noch nicht gebuchter) Umsatz laut Status-Spalte bzw. als
 * Buchungstag („offen“, comdirect).
 */
export function isPendingStatus(text: string): boolean {
  return /\b(vorgemerkt|vormerkung|pending|offen|nicht gebucht|in bearbeitung)\b/i.test(text);
}

const BALANCE_LABEL = /(konto)?stand|saldo/i;
const OPENING_LABEL = /anfang|alter|alt\b|eroeffnung|eröffnung|vortrag|opening/i;

/** Saldo aus einer Meta-Zeile wie „Kontostand vom 30.09.2026:;2.500,00 EUR“. */
function metaBalance(row: Cell[]): { kind: 'opening' | 'closing'; amount: number } | null {
  const texts = row.map(cellText).filter((t) => t !== '');
  const labelIndex = texts.findIndex((t) => BALANCE_LABEL.test(t));
  if (labelIndex === -1) {
    return null;
  }
  const label = texts[labelIndex] ?? '';
  // Von hinten: der Betrag steht nach dem Label, ein Datum im Label zählt nicht.
  for (const text of texts.slice(labelIndex + 1).reverse()) {
    const amount = parseAmount(text);
    if (amount !== null && parseDate(text) === null) {
      return { kind: OPENING_LABEL.test(label) ? 'opening' : 'closing', amount };
    }
  }
  return null;
}

const round = roundCents;

/**
 * Buchungen ab der Zeile nach der Kopfzeile. Leere Zeilen werden
 * übersprungen; Zeilen ohne gültiges Datum UND ohne Betrag gelten als
 * Meta-/Fußzeilen (dort ggf. Salden), alle anderen ungültigen als Fehler.
 */
export function buildRows(rows: Cell[][], headerIndex: number, mapping: ColumnMapping): BuiltStatement {
  const result: ImportRow[] = [];
  const errors: RowError[] = [];
  const balances: StatementBalances = { opening: null, closing: null };
  let skippedZero = 0;
  let skippedPending = 0;
  let sum = 0;
  const rowBalances: { amount: number; balance: number; date: string }[] = [];

  // Meta-Zeilen vor der Kopfzeile (z. B. DKB: „Kontostand vom …“).
  for (const row of rows.slice(0, headerIndex)) {
    const meta = metaBalance(row);
    if (meta) {
      balances[meta.kind] = meta.amount;
    }
  }

  const get = (row: Cell[], field: ImportField) => {
    const index = mapping[field];
    return index === null ? undefined : row[index];
  };

  rows.slice(headerIndex + 1).forEach((row, offset) => {
    const line = headerIndex + 2 + offset;
    if (isEmptyRow(row)) {
      return;
    }
    const rawDate = get(row, 'date');
    const rawAmount = get(row, 'amount');
    const date = parseDate(rawDate instanceof Date ? rawDate : cellText(rawDate));
    const amount = parseAmount(typeof rawAmount === 'number' ? rawAmount : cellText(rawAmount));

    // Vorgemerkt: nicht übernehmen und nicht in die Summe (Salden zählen nur
    // gebuchte Umsätze).
    if (
      amount !== null &&
      (isPendingStatus(cellText(get(row, 'bookingStatus'))) || (date === null && isPendingStatus(cellText(rawDate))))
    ) {
      skippedPending += 1;
      return;
    }

    if (date === null) {
      // Fuß-/Meta-Zeile, z. B. „Endsaldo;;;1.234,56“ – der Betrag steht
      // dabei oft genau in der Betragsspalte.
      const meta = metaBalance(row);
      if (meta) {
        balances[meta.kind] = meta.amount;
        return;
      }
      if (amount === null) {
        return;
      }
    }
    if (date === null) {
      errors.push({ line, reason: 'invalidDate', value: cellText(rawDate) });
      return;
    }
    if (amount === null) {
      errors.push({ line, reason: 'invalidAmount', value: cellText(rawAmount) });
      return;
    }

    const rawBalance = get(row, 'balance');
    if (rawBalance !== undefined) {
      const balance = parseAmount(typeof rawBalance === 'number' ? rawBalance : cellText(rawBalance));
      if (balance !== null) {
        rowBalances.push({ amount, balance, date });
      }
    }

    sum = round(sum + amount);
    if (amount === 0) {
      skippedZero += 1;
      return;
    }
    const rawValueDate = get(row, 'valueDate');
    const currency = cellText(get(row, 'currency')).toUpperCase();
    result.push({
      booking_date: date,
      value_date: rawValueDate === undefined ? null : parseDate(rawValueDate instanceof Date ? rawValueDate : cellText(rawValueDate)),
      amount,
      currency: /^[A-Z]{3}$/.test(currency) ? currency : null,
      counterparty: clip(cellText(get(row, 'counterparty')), COUNTERPARTY_MAX_LENGTH),
      purpose: clip(cellText(get(row, 'purpose')), PURPOSE_MAX_LENGTH),
      transaction_type: clip(cellText(get(row, 'transactionType')), TRANSACTION_TYPE_MAX_LENGTH),
      counterparty_iban: normalizeIban(cellText(get(row, 'counterpartyIban'))),
      description: clip(cellText(get(row, 'description')), PURPOSE_MAX_LENGTH),
      mandate_reference: normalizeMandateReference(cellText(get(row, 'mandateReference'))),
      creditor_id: normalizeCreditorId(cellText(get(row, 'creditorId'))),
    });
  });

  // Saldo-Spalte je Zeile (z. B. ING): Anfangs- und Endsaldo aus der ersten
  // und letzten Buchung in zeitlicher Reihenfolge ableiten, falls die Datei
  // keine Meta-Zeilen hat.
  const first = rowBalances[0];
  const last = rowBalances[rowBalances.length - 1];
  if (first && last && balances.opening === null && balances.closing === null) {
    const descending = first.date > last.date;
    const oldest = descending ? last : first;
    const newest = descending ? first : last;
    balances.opening = round(oldest.balance - oldest.amount);
    balances.closing = newest.balance;
  }

  let balanceCheck: BalanceCheck = { status: 'none' };
  if (balances.opening !== null && balances.closing !== null) {
    const difference = round(sum - (balances.closing - balances.opening));
    balanceCheck =
      difference === 0
        ? { status: 'ok', opening: balances.opening, closing: balances.closing, sum }
        : { status: 'mismatch', opening: balances.opening, closing: balances.closing, sum, difference };
  } else if (balances.closing !== null) {
    balanceCheck = { status: 'closingOnly', closing: balances.closing };
  }

  return { rows: result, errors, skippedZero, skippedPending, sum, balances, balanceCheck };
}
