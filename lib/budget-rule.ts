/**
 * lib/budget-rule.ts
 *
 * 50/30/20-Regel: Zeitraum und Bezugsgröße aus der URL lesen und die
 * Summen aus public.budget_category_totals() (je Monat, Währung und
 * Kategorie) auswerten. Reine Funktionen ohne Server-Abhängigkeiten.
 *
 * Gesamtausgaben = Needs + Wants + Sparen & Schulden + ohne Kategorie.
 * Umbuchungen und Kategorien ohne Gruppe zählen nicht. Zielbeträge =
 * Prozentziel × Bezugsgröße (Standard: Gesamtausgaben des Zeitraums).
 * Nicht erfasst = Einkommen − Gesamtausgaben. Gerechnet wird in Cent.
 *
 * Mehrwährungsregel (lib/currency.ts): Summen und Anteile werden immer
 * innerhalb EINER Währung gebildet, nie über Währungen hinweg.
 */
import { SUPPORTED_CURRENCIES } from '@/lib/currency';

export const BUDGET_GROUPS = ['needs', 'wants', 'savings'] as const;
export type BudgetGroupKey = (typeof BUDGET_GROUPS)[number];

/** Formularwert für „wird nicht gezählt“ (categories.budget_group NULL). */
export const EXCLUDED = 'none';

/** Bezugsgrößen der Zielbeträge (public.budget_basis). */
export const BUDGET_BASES = ['expenses', 'expenses_avg3', 'fixed', 'income'] as const;
export type BudgetBasis = (typeof BUDGET_BASES)[number];

export type BudgetTargets = Record<BudgetGroupKey, number>;

/** Standard-Prozentziele (Summe 100). */
export const DEFAULT_TARGETS: BudgetTargets = { needs: 50, wants: 30, savings: 20 };

export type BudgetSettings = {
  basis: BudgetBasis;
  targets: BudgetTargets;
  /** Fester Monatsbetrag für die Bezugsgröße fixed (in fixedCurrency). */
  fixedAmount: number | null;
  fixedCurrency: string;
};

/** Gilt, solange der Nutzer nichts gespeichert hat. */
export const DEFAULT_BUDGET_SETTINGS: BudgetSettings = {
  basis: 'expenses',
  targets: DEFAULT_TARGETS,
  fixedAmount: null,
  fixedCurrency: 'EUR',
};

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

export function isBudgetBasis(value: string): value is BudgetBasis {
  return (BUDGET_BASES as readonly string[]).includes(value);
}

/** ?basis= aus der URL (nur für diese Ansicht), sonst die Voreinstellung. */
export function parseBasis(params: SearchParams, fallback: BudgetBasis): BudgetBasis {
  const raw = single(params.basis);
  return isBudgetBasis(raw) ? raw : fallback;
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
  income: number;
  groups: Record<BudgetGroupKey, GroupFigures>;
  /** Abflüsse ohne Kategorie */
  unassigned: number;
  /** Needs + Wants + Sparen & Schulden + ohne Kategorie */
  expenses: number;
  /** Umbuchungen (Kategorien ohne Gruppe der Art Transfer), netto abgeflossen */
  ownTransfers: number;
  /** Einkommen − Gesamtausgaben */
  notCaptured: number;
};

export type BasisResolution = {
  requested: BudgetBasis;
  /** Verwendete Bezugsgröße – bei fehlenden Daten ersatzweise expenses. */
  used: BudgetBasis;
  /** Bezugsgröße in Währungseinheiten; null, wenn sie nicht positiv ist. */
  amount: number | null;
  fallback: 'fixedMissing' | 'fixedOtherCurrency' | 'noHistory' | null;
};

export type GroupResult = GroupFigures & {
  /** Anteil an der Bezugsgröße in Prozent */
  share: number | null;
  targetPct: number;
  targetAmount: number | null;
  /** Ist − Zielbetrag */
  deviation: number | null;
};

export type MonthResult = {
  month: MonthKey;
  figures: PeriodFigures;
  basis: BasisResolution;
  shares: Record<BudgetGroupKey, number | null>;
};

export type CurrencyBudget = {
  currency: string;
  figures: PeriodFigures;
  basis: BasisResolution;
  groups: Record<BudgetGroupKey, GroupResult>;
  unassignedShare: number | null;
  /** Je Monat des Zeitraums (aufsteigend) */
  months: MonthResult[];
};

/** Interne Summen in Cent. */
type Cents = {
  income: number;
  groups: Record<BudgetGroupKey, GroupFigures>;
  unassigned: number;
  ownTransfers: number;
};

function toCents(value: number | string): number {
  return Math.round(Number(value) * 100);
}

function emptyCents(): Cents {
  const group = (): GroupFigures => ({ actual: 0, taxes: 0, loan: 0, ownSavings: 0 });
  return { income: 0, groups: { needs: group(), wants: group(), savings: group() }, unassigned: 0, ownTransfers: 0 };
}

function addRow(target: Cents, row: CategoryTotalRow) {
  const amount = toCents(row.amount);
  if (row.kind === 'income') {
    target.income += amount;
  } else if (row.category_id === null) {
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
  } else if (row.kind === 'transfer') {
    target.ownTransfers -= amount;
  }
  // Ausgabenkategorien ohne Gruppe („nicht gezählt“) bleiben außen vor.
}

function mergeCents(parts: Cents[]): Cents {
  const total = emptyCents();
  for (const part of parts) {
    total.income += part.income;
    total.unassigned += part.unassigned;
    total.ownTransfers += part.ownTransfers;
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
  const expenses = expensesOf(cents);
  return {
    income: euro(cents.income),
    groups: { needs: group('needs'), wants: group('wants'), savings: group('savings') },
    unassigned: euro(cents.unassigned),
    expenses: euro(expenses),
    ownTransfers: euro(cents.ownTransfers),
    notCaptured: euro(cents.income - expenses),
  };
}

/**
 * Bezugsgröße in Cent für die Monate months (zusammenhängend) einer Währung.
 * monthCents liefert die Summen eines Monats (auch vor dem Zeitraum).
 */
function resolveBasis(
  requested: BudgetBasis,
  months: MonthKey[],
  currency: string,
  settings: BudgetSettings,
  monthCents: (month: MonthKey) => Cents,
): { resolution: Omit<BasisResolution, 'amount'>; cents: number } {
  const period = mergeCents(months.map(monthCents));
  const expenses = { resolution: { requested, used: 'expenses' as const, fallback: null }, cents: expensesOf(period) };
  switch (requested) {
    case 'income':
      return { resolution: { requested, used: 'income', fallback: null }, cents: period.income };
    case 'fixed':
      if (settings.fixedAmount === null) {
        return { ...expenses, resolution: { ...expenses.resolution, fallback: 'fixedMissing' } };
      }
      if (settings.fixedCurrency !== currency) {
        return { ...expenses, resolution: { ...expenses.resolution, fallback: 'fixedOtherCurrency' } };
      }
      return { resolution: { requested, used: 'fixed', fallback: null }, cents: toCents(settings.fixedAmount) * months.length };
    case 'expenses_avg3': {
      const start = months[0]!;
      const history = mergeCents([3, 2, 1].map((back) => monthCents(addMonths(start, -back))));
      const historyExpenses = expensesOf(history);
      if (historyExpenses <= 0) {
        return { ...expenses, resolution: { ...expenses.resolution, fallback: 'noHistory' } };
      }
      return {
        resolution: { requested, used: 'expenses_avg3', fallback: null },
        cents: Math.round((historyExpenses * months.length) / 3),
      };
    }
    default:
      return expenses;
  }
}

function shareOf(valueCents: number, basisCents: number): number | null {
  return basisCents > 0 ? (valueCents / basisCents) * 100 : null;
}

/**
 * Wertet die Zeilen je Währung aus. rows darf Monate vor dem Zeitraum
 * enthalten (für den Durchschnitt der drei Vormonate); sie zählen nur dort.
 * Währungen ohne Buchung im Zeitraum fehlen. Reihenfolge der Währungen wie
 * SUPPORTED_CURRENCIES.
 */
export function summarizeBudget(
  rows: CategoryTotalRow[],
  options: { range: MonthRange; basis: BudgetBasis; settings: BudgetSettings },
): CurrencyBudget[] {
  const { range, basis, settings } = options;
  const months = monthsOf(range);
  const inRange = new Set(months);

  const byCurrency = new Map<string, Map<MonthKey, Cents>>();
  for (const row of rows) {
    const month = row.month.slice(0, 7);
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
    if (![...perMonth.keys()].some((month) => inRange.has(month))) {
      continue;
    }
    const monthCents = (month: MonthKey) => perMonth.get(month) ?? emptyCents();
    const total = mergeCents(months.map(monthCents));
    const resolved = resolveBasis(basis, months, currency, settings, monthCents);
    const basisCents = resolved.cents;
    const figures = toFigures(total);

    const groups = {} as Record<BudgetGroupKey, GroupResult>;
    for (const key of BUDGET_GROUPS) {
      const targetPct = settings.targets[key];
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
      basis: { ...resolved.resolution, amount: basisCents > 0 ? basisCents / 100 : null },
      groups,
      unassignedShare: shareOf(total.unassigned, basisCents),
      months: months.map((month) => {
        const cents = monthCents(month);
        const monthBasis = resolveBasis(basis, [month], currency, settings, monthCents);
        return {
          month,
          figures: toFigures(cents),
          basis: { ...monthBasis.resolution, amount: monthBasis.cents > 0 ? monthBasis.cents / 100 : null },
          shares: {
            needs: shareOf(cents.groups.needs.actual, monthBasis.cents),
            wants: shareOf(cents.groups.wants.actual, monthBasis.cents),
            savings: shareOf(cents.groups.savings.actual, monthBasis.cents),
          },
        };
      }),
    });
  }

  return results.sort((a, b) => order(a.currency) - order(b.currency) || a.currency.localeCompare(b.currency));
}
