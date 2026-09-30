/**
 * lib/budget-rule.ts
 *
 * 50/30/20-Regel: Zeitraum aus der URL lesen und die Ist-Werte aus
 * public.budget_rule_summary() (je Monat und Währung) zusammenfassen.
 * Reine Funktionen ohne Server-Abhängigkeiten.
 *
 * Mehrwährungsregel (lib/currency.ts): Summen und Anteile werden immer
 * innerhalb EINER Währung gebildet, nie über Währungen hinweg.
 */
import { SUPPORTED_CURRENCIES } from '@/lib/currency';

export const BUDGET_GROUPS = ['needs', 'wants', 'savings'] as const;
export type BudgetGroupKey = (typeof BUDGET_GROUPS)[number];

/** Formularwert für „wird nicht gezählt“ (categories.budget_group NULL). */
export const EXCLUDED = 'none';

/** Ziel-Anteile am Einkommen in Prozent. */
export const BUDGET_TARGETS: Record<BudgetGroupKey, number> = { needs: 50, wants: 30, savings: 20 };

/** Längster wählbarer Zeitraum in Monaten (Grenze der Datenbankfunktion: 5 Jahre). */
export const MAX_RANGE_MONTHS = 60;

type SearchParams = Record<string, string | string[] | undefined>;

/** Monat als 'YYYY-MM'. */
export type MonthKey = string;

export type MonthRange = { from: MonthKey; to: MonthKey };

const MONTH_PATTERN = /^(\d{4})-(0[1-9]|1[0-2])$/;

function single(value: string | string[] | undefined): string {
  return (Array.isArray(value) ? value[0] : value)?.trim() ?? '';
}

function toIndex(month: MonthKey): number {
  const [, y, m] = MONTH_PATTERN.exec(month)!;
  return Number(y) * 12 + Number(m) - 1;
}

function fromIndex(index: number): MonthKey {
  const year = Math.floor(index / 12);
  return `${String(year).padStart(4, '0')}-${String((index % 12) + 1).padStart(2, '0')}`;
}

function isValidMonth(value: string): boolean {
  if (!MONTH_PATTERN.test(value)) {
    return false;
  }
  const year = Number(value.slice(0, 4));
  return year >= 2000 && year <= 2100;
}

export function addMonths(month: MonthKey, delta: number): MonthKey {
  return fromIndex(toIndex(month) + delta);
}

/** Anzahl der Monate von from bis to (einschließlich). */
export function monthCount(range: MonthRange): number {
  return toIndex(range.to) - toIndex(range.from) + 1;
}

/**
 * ?from=YYYY-MM&to=YYYY-MM. Fehlt oder ungültig: currentMonth (z. B. aus
 * todayInGermany()) bzw. der jeweils andere Wert. Vertauschte Grenzen werden getauscht, zu lange
 * Zeiträume auf die letzten MAX_RANGE_MONTHS Monate gekürzt.
 */
export function parseMonthRange(params: SearchParams, currentMonth: MonthKey): MonthRange {
  const rawFrom = single(params.from);
  const rawTo = single(params.to);
  const current = currentMonth;
  let from = isValidMonth(rawFrom) ? rawFrom : null;
  let to = isValidMonth(rawTo) ? rawTo : null;

  if (!from && !to) {
    return { from: current, to: current };
  }
  from ??= to!;
  to ??= from;
  if (toIndex(from) > toIndex(to)) {
    [from, to] = [to, from];
  }
  if (monthCount({ from, to }) > MAX_RANGE_MONTHS) {
    from = addMonths(to, -(MAX_RANGE_MONTHS - 1));
  }
  return { from, to };
}

/** Erster und letzter Kalendertag als 'YYYY-MM-DD' (für die Datenbankfunktion). */
export function rangeDates(range: MonthRange): { fromDate: string; toDate: string } {
  const index = toIndex(range.to);
  // Tag 0 des Folgemonats = letzter Tag von range.to.
  const lastDay = new Date(Date.UTC(Math.floor(index / 12), (index % 12) + 1, 0)).getUTCDate();
  return { fromDate: `${range.from}-01`, toDate: `${range.to}-${String(lastDay).padStart(2, '0')}` };
}

/** Eine Zeile aus budget_rule_summary(). */
export type BudgetSummaryRow = {
  month: string;
  currency: string;
  income: number;
  needs: number;
  wants: number;
  savings: number;
  unassigned: number;
};

export type BudgetTotals = {
  income: number;
  needs: number;
  wants: number;
  savings: number;
  unassigned: number;
};

export type CurrencySummary = {
  currency: string;
  totals: BudgetTotals;
  /** Einkommen − gezählte Ausgaben (needs, wants, savings, ohne Kategorie). */
  remaining: number;
  /** Anteil am Einkommen in Prozent; null ohne positives Einkommen. */
  shares: Record<BudgetGroupKey | 'unassigned', number | null>;
  months: { month: MonthKey; totals: BudgetTotals; shares: Record<BudgetGroupKey, number | null> }[];
};

/** Auf Cent runden – Summen aus numeric(14,2) ohne Gleitkomma-Reste. */
function cents(value: number): number {
  return Math.round(value * 100) / 100;
}

function share(value: number, income: number): number | null {
  return income > 0 ? (value / income) * 100 : null;
}

function emptyTotals(): BudgetTotals {
  return { income: 0, needs: 0, wants: 0, savings: 0, unassigned: 0 };
}

function addInto(target: BudgetTotals, row: BudgetTotals) {
  target.income = cents(target.income + Number(row.income));
  target.needs = cents(target.needs + Number(row.needs));
  target.wants = cents(target.wants + Number(row.wants));
  target.savings = cents(target.savings + Number(row.savings));
  target.unassigned = cents(target.unassigned + Number(row.unassigned));
}

function groupShares(totals: BudgetTotals): Record<BudgetGroupKey, number | null> {
  return {
    needs: share(totals.needs, totals.income),
    wants: share(totals.wants, totals.income),
    savings: share(totals.savings, totals.income),
  };
}

/**
 * Fasst die Monatszeilen je Währung zusammen. Reihenfolge der Währungen wie
 * SUPPORTED_CURRENCIES, Monate aufsteigend.
 */
export function summarizeByCurrency(rows: BudgetSummaryRow[]): CurrencySummary[] {
  const byCurrency = new Map<string, CurrencySummary>();

  for (const row of rows) {
    let summary = byCurrency.get(row.currency);
    if (!summary) {
      summary = {
        currency: row.currency,
        totals: emptyTotals(),
        remaining: 0,
        shares: { needs: null, wants: null, savings: null, unassigned: null },
        months: [],
      };
      byCurrency.set(row.currency, summary);
    }
    addInto(summary.totals, row);
    const monthTotals = emptyTotals();
    addInto(monthTotals, row);
    summary.months.push({ month: row.month.slice(0, 7), totals: monthTotals, shares: groupShares(monthTotals) });
  }

  const order = (currency: string) => {
    const index = (SUPPORTED_CURRENCIES as readonly string[]).indexOf(currency);
    return index === -1 ? SUPPORTED_CURRENCIES.length : index;
  };

  return [...byCurrency.values()]
    .map((summary) => {
      const { totals } = summary;
      summary.months.sort((a, b) => a.month.localeCompare(b.month));
      return {
        ...summary,
        remaining: cents(totals.income - totals.needs - totals.wants - totals.savings - totals.unassigned),
        shares: { ...groupShares(totals), unassigned: share(totals.unassigned, totals.income) },
      };
    })
    .sort((a, b) => order(a.currency) - order(b.currency) || a.currency.localeCompare(b.currency));
}
