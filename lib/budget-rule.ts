/**
 * lib/budget-rule.ts
 *
 * 50/30/20-Regel: Zeitraum aus der URL lesen und die Summen aus
 * public.budget_category_totals() (je Monat, Währung und Kategorie)
 * auswerten. Reine Funktionen ohne Server-Abhängigkeiten.
 *
 * Gesamtausgaben = Needs + Wants + Sparen & Schulden + ohne Kategorie.
 * Einkommen, Umbuchungen und Kategorien ohne Gruppe zählen nicht. Die
 * Regel ist fest: Zielbeträge = 50/30/20 % der Gesamtausgaben des
 * Zeitraums (keine Einstellungen, keine andere Bezugsgröße). Gerechnet
 * wird in Cent.
 *
 * Mehrwährungsregel (lib/currency.ts): Summen und Anteile werden immer
 * innerhalb EINER Währung gebildet, nie über Währungen hinweg.
 */
import { SUPPORTED_CURRENCIES } from '@/lib/currency';

export const BUDGET_GROUPS = ['needs', 'wants', 'savings'] as const;
export type BudgetGroupKey = (typeof BUDGET_GROUPS)[number];

/** Formularwert für „wird nicht gezählt“ (categories.budget_group NULL). */
export const EXCLUDED = 'none';

/** Feste Prozentziele der Regel (Summe 100). */
export const BUDGET_TARGETS: Readonly<Record<BudgetGroupKey, number>> = { needs: 50, wants: 30, savings: 20 };

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

/** Alle Monate von from bis to (einschließlich). */
export function monthsOf(range: MonthRange): MonthKey[] {
  const months: MonthKey[] = [];
  for (let index = toIndex(range.from); index <= toIndex(range.to); index += 1) {
    months.push(fromIndex(index));
  }
  return months;
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

/** Eine Zeile aus budget_category_totals(). */
export type CategoryTotalRow = {
  month: string;
  currency: string;
  category_id: string | null;
  budget_group: BudgetGroupKey | null;
  kind: 'income' | 'expense' | 'transfer' | null;
  /** taxes | loan (auch für Unterkategorien), sonst null. */
  flag: string | null;
  /** Gegenkonto ist ein eigenes Konto (IBAN-Regel). */
  own_account: boolean;
  /** Summe der Buchungen, Vorzeichen wie in transactions. */
  amount: number | string;
};

export type GroupFigures = {
  /** Ausgaben netto (Erstattungen mindern). */
  actual: number;
  /** davon Steuern & Abgaben */
  taxes: number;
  /** davon Darlehen (Rate, Zinsen, Tilgung) */
  loan: number;
  /** davon auf eigene Sparkonten (nur Sparen & Schulden) */
  ownSavings: number;
};

export type PeriodFigures = {
  groups: Record<BudgetGroupKey, GroupFigures>;
  /** Abflüsse ohne Kategorie */
  unassigned: number;
  /** Needs + Wants + Sparen & Schulden + ohne Kategorie */
  expenses: number;
};

export type GroupResult = GroupFigures & {
  /** Anteil an den Gesamtausgaben in Prozent */
  share: number | null;
  targetPct: number;
  targetAmount: number | null;
  /** Ist − Zielbetrag */
  deviation: number | null;
};

export type MonthResult = {
  month: MonthKey;
  figures: PeriodFigures;
  shares: Record<BudgetGroupKey, number | null>;
};

export type CurrencyBudget = {
  currency: string;
  figures: PeriodFigures;
  groups: Record<BudgetGroupKey, GroupResult>;
  unassignedShare: number | null;
  /** Je Monat des Zeitraums (aufsteigend) */
  months: MonthResult[];
};

/** Interne Summen in Cent. */
type Cents = {
  groups: Record<BudgetGroupKey, GroupFigures>;
  unassigned: number;
};

function toCents(value: number | string): number {
  return Math.round(Number(value) * 100);
}

function emptyCents(): Cents {
  const group = (): GroupFigures => ({ actual: 0, taxes: 0, loan: 0, ownSavings: 0 });
  return { groups: { needs: group(), wants: group(), savings: group() }, unassigned: 0 };
}

function addRow(target: Cents, row: CategoryTotalRow) {
  const amount = toCents(row.amount);
  if (row.kind === 'income') {
    return;
  }
  if (row.category_id === null) {
    target.unassigned -= amount;
  } else if (row.budget_group) {
    const group = target.groups[row.budget_group];
    group.actual -= amount;
    if (row.flag === 'taxes') {
      group.taxes -= amount;
    } else if (row.flag === 'loan') {
      group.loan -= amount;
    }
    if (row.budget_group === 'savings' && row.own_account) {
      group.ownSavings -= amount;
    }
  }
  // Kategorien ohne Gruppe („nicht gezählt“, z. B. Umbuchungen) bleiben außen vor.
}

function mergeCents(parts: Cents[]): Cents {
  const total = emptyCents();
  for (const part of parts) {
    total.unassigned += part.unassigned;
    for (const key of BUDGET_GROUPS) {
      const target = total.groups[key];
      const source = part.groups[key];
      target.actual += source.actual;
      target.taxes += source.taxes;
      target.loan += source.loan;
      target.ownSavings += source.ownSavings;
    }
  }
  return total;
}

function expensesOf(cents: Cents): number {
  return cents.groups.needs.actual + cents.groups.wants.actual + cents.groups.savings.actual + cents.unassigned;
}

function toFigures(cents: Cents): PeriodFigures {
  const euro = (value: number) => value / 100;
  const group = (key: BudgetGroupKey): GroupFigures => ({
    actual: euro(cents.groups[key].actual),
    taxes: euro(cents.groups[key].taxes),
    loan: euro(cents.groups[key].loan),
    ownSavings: euro(cents.groups[key].ownSavings),
  });
  return {
    groups: { needs: group('needs'), wants: group('wants'), savings: group('savings') },
    unassigned: euro(cents.unassigned),
    expenses: euro(expensesOf(cents)),
  };
}

function shareOf(valueCents: number, basisCents: number): number | null {
  return basisCents > 0 ? (valueCents / basisCents) * 100 : null;
}

/**
 * Wertet die Zeilen je Währung aus; Monate außerhalb des Zeitraums zählen
 * nicht. Währungen ohne gezählte Ausgaben im Zeitraum fehlen. Reihenfolge
 * der Währungen wie SUPPORTED_CURRENCIES.
 */
export function summarizeBudget(rows: CategoryTotalRow[], range: MonthRange): CurrencyBudget[] {
  const months = monthsOf(range);
  const inRange = new Set(months);

  const byCurrency = new Map<string, Map<MonthKey, Cents>>();
  for (const row of rows) {
    const month = row.month.slice(0, 7);
    if (!inRange.has(month)) {
      continue;
    }
    let perMonth = byCurrency.get(row.currency);
    if (!perMonth) {
      perMonth = new Map();
      byCurrency.set(row.currency, perMonth);
    }
    let cents = perMonth.get(month);
    if (!cents) {
      cents = emptyCents();
      perMonth.set(month, cents);
    }
    addRow(cents, row);
  }

  const order = (currency: string) => {
    const index = (SUPPORTED_CURRENCIES as readonly string[]).indexOf(currency);
    return index === -1 ? SUPPORTED_CURRENCIES.length : index;
  };

  const results: CurrencyBudget[] = [];
  for (const [currency, perMonth] of byCurrency) {
    const monthCents = (month: MonthKey) => perMonth.get(month) ?? emptyCents();
    const total = mergeCents(months.map(monthCents));
    const counted = [total.unassigned, ...BUDGET_GROUPS.map((key) => total.groups[key].actual)];
    if (counted.every((cents) => cents === 0)) {
      continue;
    }
    const basisCents = expensesOf(total);
    const figures = toFigures(total);

    const groups = {} as Record<BudgetGroupKey, GroupResult>;
    for (const key of BUDGET_GROUPS) {
      const targetPct = BUDGET_TARGETS[key];
      const targetCents = basisCents > 0 ? Math.round((basisCents * targetPct) / 100) : null;
      groups[key] = {
        ...figures.groups[key],
        share: shareOf(total.groups[key].actual, basisCents),
        targetPct,
        targetAmount: targetCents === null ? null : targetCents / 100,
        deviation: targetCents === null ? null : (total.groups[key].actual - targetCents) / 100,
      };
    }

    results.push({
      currency,
      figures,
      groups,
      unassignedShare: shareOf(total.unassigned, basisCents),
      months: months.map((month) => {
        const cents = monthCents(month);
        const monthExpenses = expensesOf(cents);
        return {
          month,
          figures: toFigures(cents),
          shares: {
            needs: shareOf(cents.groups.needs.actual, monthExpenses),
            wants: shareOf(cents.groups.wants.actual, monthExpenses),
            savings: shareOf(cents.groups.savings.actual, monthExpenses),
          },
        };
      }),
    });
  }

  return results.sort((a, b) => order(a.currency) - order(b.currency) || a.currency.localeCompare(b.currency));
}
