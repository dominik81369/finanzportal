/**
 * lib/spending.ts
 *
 * Ausgaben-Dashboard: Ergebnis von public.spending_report() je Währung
 * auswerten – Kopfzahlen, Veränderung zur Vergleichsperiode, Kategorien
 * mit Unterkategorien, Verlauf und Hinweise. Reine Funktionen, gerechnet
 * in Cent (ganze Zahlen); Beträge werden nie zwischen Währungen umgerechnet.
 *
 * Einordnung der Buchungen siehe supabase/migrations/20261015100000_spending_report.sql:
 * expense (Ausgaben, netto), income (Einnahmen), saved (Gespart/getilgt),
 * Umbuchungen über erfasste eigene IBANs zählen nirgends.
 */
import { SUPPORTED_CURRENCIES } from '@/lib/currency';
import { bucketStarts, type SpendingPeriod } from '@/lib/spending-period';

type Amount = number | string;

export type SpendingReport = {
  categories: {
    currency: string;
    category_id: string | null;
    class: 'expense' | 'income' | 'saved';
    amount: Amount;
    credits: Amount;
    count: number;
  }[];
  buckets: { currency: string; bucket: string; expenses: Amount; income: Amount; saved: Amount }[];
  flagged: { currency: string; count: number; expenses: Amount; income: Amount }[];
  same_holder: { currency: string; count: number; ibans: number; outflow: Amount; inflow: Amount }[];
  transfers: { currency: string; count: number; outflow: Amount; inflow: Amount }[];
  counterparties: { currency: string; counterparty_key: string; label: string | null; count: number; expenses: Amount }[];
  largest: {
    currency: string;
    id: string;
    booking_date: string;
    amount: Amount;
    counterparty: string | null;
    purpose: string | null;
    category_id: string | null;
  }[];
};

export const EMPTY_REPORT: SpendingReport = {
  categories: [],
  buckets: [],
  flagged: [],
  same_holder: [],
  transfers: [],
  counterparties: [],
  largest: [],
};

/** Ab so vielen Buchungen an fremde IBANs mit eigenem Namen erscheint der Hinweis. */
export const SAME_HOLDER_MIN_COUNT = 2;

export function toCents(value: Amount): number {
  return Math.round(Number(value) * 100);
}

/** Währungen mit Buchungen im Bericht, Reihenfolge wie SUPPORTED_CURRENCIES. */
export function reportCurrencies(report: SpendingReport): string[] {
  const found = new Set<string>([
    ...report.categories.map((row) => row.currency),
    ...report.transfers.map((row) => row.currency),
  ]);
  const order = (currency: string) => {
    const index = (SUPPORTED_CURRENCIES as readonly string[]).indexOf(currency);
    return index === -1 ? SUPPORTED_CURRENCIES.length : index;
  };
  return [...found].sort((a, b) => order(a) - order(b) || a.localeCompare(b));
}

/** Gewünschte Währung, sonst EUR, sonst die erste vorhandene; null ohne Buchungen. */
export function pickCurrency(available: string[], requested: string | null): string | null {
  if (requested && available.includes(requested)) {
    return requested;
  }
  return available.includes('EUR') ? 'EUR' : (available[0] ?? null);
}

export type SpendingFigures = {
  /** Ausgaben netto (Erstattungen gemindert) */
  expenses: number;
  income: number;
  /** Einnahmen − Ausgaben */
  balance: number;
  /** Gespart/getilgt (netto) */
  saved: number;
  /** Erstattungen und Gutschriften in Ausgabenkategorien (bereits verrechnet) */
  refunds: number;
};

export function figuresOf(report: SpendingReport, currency: string): SpendingFigures {
  let expenses = 0;
  let income = 0;
  let saved = 0;
  let refunds = 0;
  for (const row of report.categories) {
    if (row.currency !== currency) {
      continue;
    }
    const cents = toCents(row.amount);
    if (row.class === 'expense') {
      expenses -= cents;
      refunds += toCents(row.credits);
    } else if (row.class === 'income') {
      income += cents;
    } else {
      saved -= cents;
    }
  }
  return { expenses, income, balance: income - expenses, saved, refunds };
}

export type Change = {
  /** Differenz in Cent (aktuell − Vergleich) */
  delta: number;
  /** Veränderung in Prozent; null, wenn der Vergleichswert 0 ist */
  pct: number | null;
};

export function changeOf(current: number, previous: number): Change {
  return { delta: current - previous, pct: previous === 0 ? null : ((current - previous) / Math.abs(previous)) * 100 };
}

export type SpendingCategoryInfo = { id: string; parentId: string | null; label: string };

export type CategoryRow = {
  /** Kategorie-ID; null = ohne Kategorie */
  categoryId: string | null;
  label: string;
  /** Ausgaben netto in Cent (inkl. Unterkategorien) */
  cents: number;
  compareCents: number;
  count: number;
  /** Anteil an den Ausgaben in Prozent; null ohne Ausgaben */
  share: number | null;
  children: CategoryRow[];
};

/**
 * Ausgaben je Kategorie: Oberkategorien mit Unterkategorien (Summe der
 * Oberkategorie inkl. Unterkategorien), absteigend nach Betrag; „ohne
 * Kategorie“ zuletzt. Nur Einordnung expense.
 */
export function categoryTree(
  report: SpendingReport,
  compare: SpendingReport | null,
  currency: string,
  categories: SpendingCategoryInfo[],
  labels: { uncategorized: string; unknown: string },
): CategoryRow[] {
  const byId = new Map(categories.map((category) => [category.id, category]));
  const sums = (source: SpendingReport | null) => {
    const map = new Map<string | null, { cents: number; count: number }>();
    for (const row of source?.categories ?? []) {
      if (row.currency !== currency || row.class !== 'expense') {
        continue;
      }
      const entry = map.get(row.category_id) ?? { cents: 0, count: 0 };
      entry.cents -= toCents(row.amount);
      entry.count += row.count;
      map.set(row.category_id, entry);
    }
    return map;
  };
  const current = sums(report);
  const previous = sums(compare);
  const total = [...current.values()].reduce((sum, entry) => sum + entry.cents, 0);
  const share = (cents: number) => (total > 0 ? (cents / total) * 100 : null);

  // Oberkategorie einer Kategorie (eine Ebene; unbekannte Eltern: selbst oben).
  const topOf = (id: string) => {
    const parentId = byId.get(id)?.parentId;
    return parentId && byId.has(parentId) ? parentId : id;
  };
  const leaf = (id: string | null): CategoryRow => {
    const now = current.get(id) ?? { cents: 0, count: 0 };
    const before = previous.get(id)?.cents ?? 0;
    return {
      categoryId: id,
      label: id === null ? labels.uncategorized : (byId.get(id)?.label ?? labels.unknown),
      cents: now.cents,
      compareCents: before,
      count: now.count,
      share: share(now.cents),
      children: [],
    };
  };

  const ids = new Set<string>();
  for (const id of [...current.keys(), ...previous.keys()]) {
    if (id !== null) {
      ids.add(id);
    }
  }
  const tops = new Map<string, CategoryRow>();
  for (const id of ids) {
    const top = topOf(id);
    let row = tops.get(top);
    if (!row) {
      row = leaf(top);
      tops.set(top, row);
    }
    if (top !== id) {
      const child = leaf(id);
      row.children.push(child);
      row.cents += child.cents;
      row.compareCents += child.compareCents;
      row.count += child.count;
    }
  }
  const byAmount = (a: CategoryRow, b: CategoryRow) => b.cents - a.cents || a.label.localeCompare(b.label);
  const rows = [...tops.values()]
    .filter((row) => row.cents !== 0 || row.count > 0)
    .map((row) => ({
      ...row,
      share: share(row.cents),
      children: row.children.filter((child) => child.cents !== 0 || child.count > 0).sort(byAmount),
    }))
    .sort(byAmount);
  const uncategorized = leaf(null);
  if (uncategorized.cents !== 0 || uncategorized.count > 0) {
    rows.push(uncategorized);
  }
  return rows;
}

export type BucketPoint = {
  /** Beginn des Teilzeitraums (ggf. vor dem Zeitraum, z. B. Montag der ersten Woche) */
  start: string;
  expenses: number;
  /** Gleicher Teilzeitraum (nach Position) im Vergleichszeitraum; null, wenn es ihn nicht gibt */
  compareExpenses: number | null;
};

/** Ausgaben je Teilzeitraum, auch leere, mit dem Wert gleicher Position der Vergleichsperiode. */
export function bucketSeries(
  report: SpendingReport,
  compare: SpendingReport | null,
  currency: string,
  period: Pick<SpendingPeriod, 'bucket' | 'evaluated' | 'compare'>,
): BucketPoint[] {
  const values = (source: SpendingReport | null) => {
    const map = new Map<string, number>();
    for (const row of source?.buckets ?? []) {
      if (row.currency === currency) {
        map.set(row.bucket, toCents(row.expenses));
      }
    }
    return map;
  };
  const current = values(report);
  const previous = values(compare);
  const compareStarts = bucketStarts(period.bucket, period.compare);
  return bucketStarts(period.bucket, period.evaluated).map((start, index) => ({
    start,
    expenses: current.get(start) ?? 0,
    compareExpenses: compare && index < compareStarts.length ? (previous.get(compareStarts[index]!) ?? 0) : null,
  }));
}

export type SpendingHints = {
  /** Ohne Kategorie oder in „Sonstige Ausgaben/Einnahmen“ */
  flagged: { count: number; expenses: number; income: number } | null;
  /** Fremde IBANs mit eigenem Namen (ab SAME_HOLDER_MIN_COUNT Buchungen) */
  sameHolder: { count: number; ibans: number; outflow: number; inflow: number } | null;
  /** Umbuchungen über erfasste eigene Konten (zählen nicht) */
  transfers: { count: number; outflow: number; inflow: number } | null;
};

export function hintsOf(report: SpendingReport, currency: string): SpendingHints {
  const flagged = report.flagged.find((row) => row.currency === currency);
  const sameHolder = report.same_holder.find((row) => row.currency === currency);
  const transfers = report.transfers.find((row) => row.currency === currency);
  return {
    flagged:
      flagged && flagged.count > 0
        ? { count: flagged.count, expenses: toCents(flagged.expenses), income: toCents(flagged.income) }
        : null,
    sameHolder:
      sameHolder && sameHolder.count >= SAME_HOLDER_MIN_COUNT
        ? {
            count: sameHolder.count,
            ibans: sameHolder.ibans,
            outflow: toCents(sameHolder.outflow),
            inflow: toCents(sameHolder.inflow),
          }
        : null,
    transfers:
      transfers && transfers.count > 0
        ? { count: transfers.count, outflow: toCents(transfers.outflow), inflow: toCents(transfers.inflow) }
        : null,
  };
}

/** Durchschnittliche Ausgaben pro Tag in Cent. */
export function perDay(expenses: number, days: number): number {
  return days > 0 ? Math.round(expenses / days) : 0;
}
