/**
 * lib/transaction-filters.ts
 *
 * Filter und Suche der Transaktionsliste. Die Filter stehen als
 * Query-Parameter in der URL (teilbar, Zurück-Taste, funktioniert als
 * GET-Formular ohne JavaScript). Unbekannte oder ungültige Werte werden
 * ignoriert, nie an die Datenbank durchgereicht.
 */
import { isUuid, parseIsoDate } from '@/lib/transactions';

export const SEARCH_MAX_LENGTH = 100;

/** Wert des Kategorie-Filters für Buchungen ohne Kategorie. */
export const UNCATEGORIZED = 'none';

export type TransactionFilters = {
  /** Suche in Empfänger/Zahler und Verwendungszweck. */
  q: string;
  type: 'expense' | 'income' | null;
  accountId: string | null;
  /** UUID oder UNCATEGORIZED. */
  categoryId: string | null;
  tagId: string | null;
  /** YYYY-MM-DD, jeweils einschließlich. */
  from: string | null;
  to: string | null;
  /** Herkunft der Kategorie: manuell gesetzt oder automatisch per Regel. */
  assigned: Assignment | null;
};

export const ASSIGNMENTS = ['manual', 'auto'] as const;
export type Assignment = (typeof ASSIGNMENTS)[number];

type SearchParams = Record<string, string | string[] | undefined>;

function single(value: string | string[] | undefined): string {
  return typeof value === 'string' ? value.trim() : '';
}

export function parseTransactionFilters(params: SearchParams): TransactionFilters {
  const q = single(params.q).replace(/\s+/g, ' ').slice(0, SEARCH_MAX_LENGTH);
  const type = single(params.type);
  const account = single(params.account);
  const category = single(params.category);
  const tag = single(params.tag);
  const assigned = single(params.assigned);
  let from = parseIsoDate(single(params.from));
  let to = parseIsoDate(single(params.to));

  // Vertauschter Zeitraum: großzügig korrigieren statt nichts zu finden.
  if (from && to && from > to) {
    [from, to] = [to, from];
  }

  return {
    q,
    type: type === 'expense' || type === 'income' ? type : null,
    accountId: isUuid(account) ? account : null,
    categoryId: category === UNCATEGORIZED || isUuid(category) ? category : null,
    tagId: isUuid(tag) ? tag : null,
    from,
    to,
    assigned: (ASSIGNMENTS as readonly string[]).includes(assigned) ? (assigned as Assignment) : null,
  };
}

export function hasActiveFilters(filters: TransactionFilters): boolean {
  return (
    filters.q !== '' ||
    filters.type !== null ||
    filters.accountId !== null ||
    filters.categoryId !== null ||
    filters.tagId !== null ||
    filters.from !== null ||
    filters.to !== null ||
    filters.assigned !== null
  );
}

/**
 * Suchtext als ilike-Muster für einen PostgREST-or()-Filter.
 *
 * Zwei Ebenen: Zuerst werden die LIKE-Platzhalter % und _ sowie der
 * Backslash maskiert, damit der Text wörtlich gesucht wird. Danach wird der
 * Wert für PostgREST in doppelte Anführungszeichen gesetzt (Backslash und
 * Anführungszeichen maskiert) – sonst würden Komma, Klammern oder Punkt im
 * Suchtext die Filter-Syntax von or() aufbrechen. `*` ist bei PostgREST ein
 * Platzhalter für `%` und umschließt den Text.
 */
export function ilikeContainsPattern(text: string): string {
  const likeEscaped = text.replace(/[\\%_]/g, (char) => `\\${char}`);
  const quoted = likeEscaped.replace(/[\\"]/g, (char) => `\\${char}`);
  return `"*${quoted}*"`;
}


/** Buchungen je Seite der Transaktionsliste. */
export const PAGE_SIZE = 50;

/** Obergrenze gegen absurde Offsets aus manipulierten URLs. */
const PAGE_MAX = 10_000;

/** Seitennummer aus ?page= (ganze Zahl ≥ 1), sonst 1. */
export function parsePage(params: SearchParams): number {
  const raw = single(params.page);
  if (!/^\d{1,5}$/.test(raw)) {
    return 1;
  }
  const page = Number(raw);
  return page >= 1 && page <= PAGE_MAX ? page : 1;
}

/** Nullbasierte, einschließliche Zeilengrenzen für .range(from, to). */
export function pageRange(page: number): { from: number; to: number } {
  const from = (page - 1) * PAGE_SIZE;
  return { from, to: from + PAGE_SIZE - 1 };
}

export function pageCount(total: number): number {
  return Math.max(1, Math.ceil(total / PAGE_SIZE));
}

/**
 * Query-String mit den aktiven Filtern und der Seite (Seite 1 wird
 * weggelassen). Für Seitenlinks – die Filter bleiben beim Blättern erhalten.
 * Das Filterformular selbst enthält KEIN page-Feld: Jede Filteränderung
 * beginnt dadurch wieder auf Seite 1.
 */
export function listQueryString(filters: TransactionFilters, page: number): string {
  const params = new URLSearchParams();
  if (filters.q) params.set('q', filters.q);
  if (filters.type) params.set('type', filters.type);
  if (filters.accountId) params.set('account', filters.accountId);
  if (filters.categoryId) params.set('category', filters.categoryId);
  if (filters.tagId) params.set('tag', filters.tagId);
  if (filters.from) params.set('from', filters.from);
  if (filters.to) params.set('to', filters.to);
  if (filters.assigned) params.set('assigned', filters.assigned);
  if (page > 1) params.set('page', String(page));
  const query = params.toString();
  return query ? `?${query}` : '';
}
