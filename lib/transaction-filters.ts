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
};

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
    filters.to !== null
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

