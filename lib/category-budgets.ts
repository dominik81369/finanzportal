/**
 * lib/category-budgets.ts
 *
 * Einzelbudgets je Kategorie (Budget-2): Auswertung, Summe je Gruppe,
 * Hinweise, Vorschläge aus dem Durchschnitt und Formularprüfung. Reine
 * Funktionen ohne Server-Abhängigkeiten; gerechnet wird in Cent (Ganzzahlen).
 *
 * Ausgaben eines Budgets: Kategorie samt Unterkategorien, nur in der Währung
 * des Budgets, netto nach Erstattungen. Grundlage sind die Summen aus
 * public.budget_category_totals(); Buchungen „nicht im Budget“ fehlen dort.
 *
 * Zeitraum in der Liste:
 *   Monat – der angezeigte Zeitraum, Höchstbetrag × Anzahl der Monate.
 *   Jahr  – 1. Januar bis Ende des Zeitraums, im Jahr des Zeitraumendes
 *           (auch bei Zeiträumen über den Jahreswechsel), voller Jahresbetrag.
 *
 * Summe je Gruppe (50/30/20-Tabelle): Monatsbudget × Monate, Jahresbudget
 * je Monat ein Zwölftel. Es zählt die Gruppe der Kategorie, die das Budget
 * trägt; Budgets unter einer Oberkategorie mit Budget (gleiche Währung)
 * zählen nicht noch einmal. Gibt es nur Unterbudgets, zählt deren Summe.
 */
import type { AppLocale } from '@/i18n/routing';
import {
  addMonths,
  monthsOf,
  type BudgetGroupKey,
  type CategoryTotalRow,
  type MonthKey,
  type MonthRange,
} from '@/lib/budget-rule';
import { SUPPORTED_CURRENCIES, isSupportedCurrency } from '@/lib/currency';
import { parseAmountInput } from '@/lib/transactions';

/** Zeiträume mit Oberfläche (budget_period kennt auch Woche und Quartal). */
export const CATEGORY_BUDGET_PERIODS = ['monthly', 'yearly'] as const;
export type CategoryBudgetPeriod = (typeof CATEGORY_BUDGET_PERIODS)[number];

/** Standard-Warnschwelle in Prozent des Höchstbetrags. */
export const DEFAULT_THRESHOLD_PCT = 80;

export function isCategoryBudgetPeriod(value: string): value is CategoryBudgetPeriod {
  return (CATEGORY_BUDGET_PERIODS as readonly string[]).includes(value);
}

/** Eine Zeile aus public.budgets (nur Kategoriebudgets). */
export type CategoryBudgetRow = {
  id: string;
  category_id: string;
  period: string;
  amount: number | string;
  currency: string;
  alert_threshold_pct: number;
};

/** Kategorie mit Oberkategorie und Gruppe – in Anzeigereihenfolge. */
export type BudgetCategory = {
  id: string;
  parentId: string | null;
  group: BudgetGroupKey | null;
  kind: 'income' | 'expense' | 'transfer';
};

/** ok: unter der Schwelle · warning: Schwelle erreicht · over: überschritten. */
export type BudgetStatus = 'ok' | 'warning' | 'over';

export type CategoryBudgetResult = {
  id: string;
  categoryId: string;
  period: CategoryBudgetPeriod;
  currency: string;
  thresholdPct: number;
  /** Eingestellter Höchstbetrag (je Monat bzw. Jahr). */
  amountCents: number;
  /** Höchstbetrag im ausgewerteten Zeitraum. */
  limitCents: number;
  /** Ausgaben netto im ausgewerteten Zeitraum (Erstattungen mindern, auch < 0). */
  actualCents: number;
  /** Höchstbetrag − Ausgaben (negativ = überschritten). */
  remainingCents: number;
  /** Ausgaben in Prozent des Höchstbetrags. */
  usedPct: number;
  status: BudgetStatus;
  /** Ausgewertete Monate (Jahr: Januar bis Zeitraumende). */
  window: MonthRange;
  /** Jahresbudget: vergangene Monate des Jahres (1–12); Monatsbudget: null. */
  elapsedMonths: number | null;
  /** Jahresbudget und Zeitraum über den Jahreswechsel: es gilt das Jahr des Zeitraumendes. */
  crossesYear: boolean;
  /** Gruppe der Kategorie, die das Budget trägt. */
  group: BudgetGroupKey | null;
  /** Anteil für die Summe je Gruppe im angezeigten Zeitraum. */
  groupShareCents: number;
  /** Zählt in der Summe je Gruppe (keine Oberkategorie mit Budget in derselben Währung). */
  countsInGroupSum: boolean;
  /** Unterkategorien, deren Gruppe von der Gruppe dieses Budgets abweicht. */
  divergentChildren: { categoryId: string; group: BudgetGroupKey | null }[];
  /** Nächstes Budget einer Oberkategorie in derselben Währung. */
  parentBudget: { id: string; categoryId: string; period: CategoryBudgetPeriod; amountCents: number } | null;
  /** Höher als das Budget der Oberkategorie (auf ein Jahr gerechnet). */
  exceedsParent: boolean;
  /** Summe der Unterbudgets in diesem Zeitraum, wenn sie dieses Budget übersteigt; sonst null. */
  childrenExceedCents: number | null;
};

export function toCents(value: number | string): number {
  return Math.round(Number(value) * 100);
}

function yearOf(month: MonthKey): string {
  return month.slice(0, 4);
}

function annualCents(period: CategoryBudgetPeriod, amountCents: number): number {
  return period === 'monthly' ? amountCents * 12 : amountCents;
}

type Tree = { byId: Map<string, BudgetCategory>; children: Map<string, string[]> };

function buildTree(categories: BudgetCategory[]): Tree {
  const byId = new Map(categories.map((category) => [category.id, category]));
  const children = new Map<string, string[]>();
  for (const category of categories) {
    if (category.parentId && byId.has(category.parentId)) {
      const list = children.get(category.parentId) ?? [];
      list.push(category.id);
      children.set(category.parentId, list);
    }
  }
  return { byId, children };
}

/** Alle Unterkategorien (beliebig tief, ohne die Kategorie selbst). */
function descendantsOf(id: string, tree: Tree): string[] {
  const result: string[] = [];
  const seen = new Set([id]);
  const queue = [...(tree.children.get(id) ?? [])];
  while (queue.length > 0) {
    const next = queue.shift()!;
    if (seen.has(next)) {
      continue;
    }
    seen.add(next);
    result.push(next);
    queue.push(...(tree.children.get(next) ?? []));
  }
  return result;
}

/** Oberkategorien, die nächste zuerst. */
function ancestorsOf(id: string, tree: Tree): string[] {
  const result: string[] = [];
  const seen = new Set([id]);
  let current = tree.byId.get(id)?.parentId ?? null;
  while (current && tree.byId.has(current) && !seen.has(current)) {
    seen.add(current);
    result.push(current);
    current = tree.byId.get(current)?.parentId ?? null;
  }
  return result;
}

/** Ausgaben in Cent je Währung, Monat und Kategorie (Abfluss positiv). */
type SpendingIndex = Map<string, Map<MonthKey, Map<string, number>>>;

function indexSpending(rows: CategoryTotalRow[]): SpendingIndex {
  const index: SpendingIndex = new Map();
  for (const row of rows) {
    if (row.category_id === null) {
      continue;
    }
    const month = row.month.slice(0, 7);
    let perMonth = index.get(row.currency);
    if (!perMonth) {
      perMonth = new Map();
      index.set(row.currency, perMonth);
    }
    let perCategory = perMonth.get(month);
    if (!perCategory) {
      perCategory = new Map();
      perMonth.set(month, perCategory);
    }
    perCategory.set(row.category_id, (perCategory.get(row.category_id) ?? 0) - toCents(row.amount));
  }
  return index;
}

function spendingOf(index: SpendingIndex, currency: string, categoryIds: string[], months: MonthKey[]): number {
  const perMonth = index.get(currency);
  if (!perMonth) {
    return 0;
  }
  let total = 0;
  for (const month of months) {
    const perCategory = perMonth.get(month);
    if (!perCategory) {
      continue;
    }
    for (const id of categoryIds) {
      total += perCategory.get(id) ?? 0;
    }
  }
  return total;
}

export function budgetStatus(actualCents: number, limitCents: number, thresholdPct: number): BudgetStatus {
  if (actualCents > limitCents) {
    return 'over';
  }
  // Ganzzahlig: actual / limit ≥ threshold / 100
  return actualCents * 100 >= limitCents * thresholdPct ? 'warning' : 'ok';
}

/**
 * Monate, die rows für evaluateCategoryBudgets() abdecken muss: der
 * Zeitraum und für Jahresbudgets der Januar im Jahr des Zeitraumendes.
 */
export function evaluationStart(range: MonthRange): MonthKey {
  const january = `${yearOf(range.to)}-01`;
  return january < range.from ? january : range.from;
}

/**
 * Wertet die Kategoriebudgets für den angezeigten Zeitraum aus. Reihenfolge
 * wie categories (Anzeigereihenfolge), bei gleicher Kategorie nach Währung
 * (wie SUPPORTED_CURRENCIES).
 * Budgets ohne bekannte Kategorie oder mit anderem Zeitraum fehlen.
 */
export function evaluateCategoryBudgets(
  budgets: CategoryBudgetRow[],
  categories: BudgetCategory[],
  rows: CategoryTotalRow[],
  range: MonthRange,
): CategoryBudgetResult[] {
  const tree = buildTree(categories);
  const order = new Map(categories.map((category, index) => [category.id, index]));
  const spending = indexSpending(rows);
  const rangeMonths = monthsOf(range);
  const yearWindow: MonthRange = { from: `${yearOf(range.to)}-01`, to: range.to };
  const yearMonths = monthsOf(yearWindow);
  const crossesYear = yearOf(range.from) !== yearOf(range.to);

  const valid = budgets.filter(
    (budget): budget is CategoryBudgetRow & { period: CategoryBudgetPeriod } =>
      isCategoryBudgetPeriod(budget.period) && tree.byId.has(budget.category_id),
  );
  // Budget je Kategorie und Währung (für Ober-/Unterbudgets).
  const byCategoryCurrency = new Map(valid.map((budget) => [`${budget.category_id}|${budget.currency}`, budget]));

  const results: CategoryBudgetResult[] = valid.map((budget) => {
    const category = tree.byId.get(budget.category_id)!;
    const descendants = descendantsOf(category.id, tree);
    const yearly = budget.period === 'yearly';
    const months = yearly ? yearMonths : rangeMonths;
    const amountCents = toCents(budget.amount);
    const limitCents = yearly ? amountCents : amountCents * rangeMonths.length;
    const actualCents = spendingOf(spending, budget.currency, [category.id, ...descendants], months);
    const thresholdPct = Number(budget.alert_threshold_pct);

    const parentId = ancestorsOf(category.id, tree).find((id) => byCategoryCurrency.has(`${id}|${budget.currency}`));
    const parent = parentId ? byCategoryCurrency.get(`${parentId}|${budget.currency}`)! : null;
    const parentBudget = parent
      ? {
          id: parent.id,
          categoryId: parent.category_id,
          period: parent.period,
          amountCents: toCents(parent.amount),
        }
      : null;

    return {
      id: budget.id,
      categoryId: category.id,
      period: budget.period,
      currency: budget.currency,
      thresholdPct,
      amountCents,
      limitCents,
      actualCents,
      remainingCents: limitCents - actualCents,
      usedPct: limitCents > 0 ? (actualCents / limitCents) * 100 : 0,
      status: budgetStatus(actualCents, limitCents, thresholdPct),
      window: yearly ? yearWindow : range,
      elapsedMonths: yearly ? yearMonths.length : null,
      crossesYear: yearly && crossesYear,
      group: category.group,
      groupShareCents: yearly ? Math.round((amountCents * rangeMonths.length) / 12) : amountCents * rangeMonths.length,
      countsInGroupSum: parentBudget === null,
      divergentChildren: descendants
        .map((id) => tree.byId.get(id)!)
        .filter((child) => child.group !== category.group)
        .map((child) => ({ categoryId: child.id, group: child.group })),
      parentBudget,
      exceedsParent:
        parentBudget !== null &&
        annualCents(budget.period, amountCents) > annualCents(parentBudget.period, parentBudget.amountCents),
      childrenExceedCents: null,
    };
  });

  // Unterbudgets zusammen höher als das Budget der Oberkategorie?
  for (const result of results) {
    const childAnnual = results
      .filter((child) => child.parentBudget?.id === result.id)
      .reduce((sum, child) => sum + annualCents(child.period, child.amountCents), 0);
    if (childAnnual > annualCents(result.period, result.amountCents)) {
      result.childrenExceedCents = result.period === 'monthly' ? Math.round(childAnnual / 12) : childAnnual;
    }
  }

  const currencyOrder = (currency: string) => {
    const index = (SUPPORTED_CURRENCIES as readonly string[]).indexOf(currency);
    return index === -1 ? SUPPORTED_CURRENCIES.length : index;
  };
  return results.sort(
    (a, b) =>
      (order.get(a.categoryId) ?? 0) - (order.get(b.categoryId) ?? 0) ||
      currencyOrder(a.currency) - currencyOrder(b.currency),
  );
}

export type GroupBudgetSum = { cents: number; count: number };

/** Summe je Währung und Gruppe (nur zählende Budgets mit Gruppe). */
export function groupBudgetSums(results: CategoryBudgetResult[]): Map<string, Partial<Record<BudgetGroupKey, GroupBudgetSum>>> {
  const sums = new Map<string, Partial<Record<BudgetGroupKey, GroupBudgetSum>>>();
  for (const result of results) {
    if (!result.countsInGroupSum || result.group === null) {
      continue;
    }
    const perGroup = sums.get(result.currency) ?? {};
    const current = perGroup[result.group] ?? { cents: 0, count: 0 };
    perGroup[result.group] = { cents: current.cents + result.groupShareCents, count: current.count + 1 };
    sums.set(result.currency, perGroup);
  }
  return sums;
}

export type BudgetAlerts = {
  total: number;
  /** Schwelle erreicht oder überschritten */
  atThreshold: number;
  /** davon überschritten */
  over: number;
};

export function budgetAlerts(results: CategoryBudgetResult[]): BudgetAlerts {
  return {
    total: results.length,
    atThreshold: results.filter((result) => result.status !== 'ok').length,
    over: results.filter((result) => result.status === 'over').length,
  };
}

// ---------------------------------------------------------------------
// Vorschläge „Aus Durchschnitt übernehmen“
// ---------------------------------------------------------------------

/** Vorschlag in Cent je Zeitraum; null ohne Ausgaben. */
export type BudgetSuggestion = Record<CategoryBudgetPeriod, number | null>;

/** Je Kategorie und Währung. */
export type BudgetSuggestions = Record<string, Record<string, BudgetSuggestion>>;

/**
 * Grundlage der Vorschläge, bezogen auf den laufenden Monat:
 * Monat – Durchschnitt der letzten drei vollen Monate,
 * Jahr  – Summe der letzten zwölf vollen Monate.
 */
export function suggestionWindows(currentMonth: MonthKey): Record<CategoryBudgetPeriod, MonthRange> {
  const lastFull = addMonths(currentMonth, -1);
  return {
    monthly: { from: addMonths(currentMonth, -3), to: lastFull },
    yearly: { from: addMonths(currentMonth, -12), to: lastFull },
  };
}

/** Vorschläge für alle Ausgabenkategorien (samt Unterkategorien) und Währungen. */
export function budgetSuggestions(
  rows: CategoryTotalRow[],
  categories: BudgetCategory[],
  currentMonth: MonthKey,
): BudgetSuggestions {
  const tree = buildTree(categories);
  const spending = indexSpending(rows);
  const windows = suggestionWindows(currentMonth);
  const monthly = monthsOf(windows.monthly);
  const yearly = monthsOf(windows.yearly);
  const result: BudgetSuggestions = {};
  for (const category of categories) {
    if (category.kind !== 'expense') {
      continue;
    }
    const ids = [category.id, ...descendantsOf(category.id, tree)];
    for (const currency of spending.keys()) {
      const threeMonths = spendingOf(spending, currency, ids, monthly);
      const twelveMonths = spendingOf(spending, currency, ids, yearly);
      if (threeMonths <= 0 && twelveMonths <= 0) {
        continue;
      }
      result[category.id] ??= {};
      result[category.id]![currency] = {
        monthly: threeMonths > 0 ? Math.round(threeMonths / monthly.length) : null,
        yearly: twelveMonths > 0 ? twelveMonths : null,
      };
    }
  }
  return result;
}

// ---------------------------------------------------------------------
// Formular
// ---------------------------------------------------------------------

export type CategoryBudgetField = 'category' | 'period' | 'amount' | 'currency' | 'threshold';

export type CategoryBudgetFieldError =
  | 'categoryRequired'
  | 'periodInvalid'
  | 'amountInvalid'
  | 'currencyInvalid'
  | 'thresholdInvalid';

/** Formularwerte als Strings – zum Vorbelegen (Bearbeiten, nach Fehlern). */
export type CategoryBudgetFormValues = {
  categoryId: string;
  period: string;
  amount: string;
  currency: string;
  threshold: string;
};

export type CategoryBudgetRpcParams = {
  p_category_id: string;
  p_period: CategoryBudgetPeriod;
  p_amount: number;
  p_currency: string;
  p_threshold_pct: number;
};

export type ParsedCategoryBudgetForm =
  | { ok: true; values: CategoryBudgetFormValues; params: CategoryBudgetRpcParams }
  | {
      ok: false;
      values: CategoryBudgetFormValues;
      errors: Partial<Record<CategoryBudgetField, CategoryBudgetFieldError>>;
    };

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

type FormLike = { get(name: string): FormDataEntryValue | null };

/** Warnschwelle als ganze Zahl 1–100 („80“ oder „80 %“), sonst null. */
export function parseThreshold(input: string): number | null {
  const value = input.replace(/[\s%]/g, '');
  if (!/^\d{1,3}$/.test(value)) {
    return null;
  }
  const threshold = Number(value);
  return threshold >= 1 && threshold <= 100 ? threshold : null;
}

/** Formular prüfen und in Parameter für public.save_category_budget() umsetzen. */
export function parseCategoryBudgetForm(formData: FormLike, locale: AppLocale): ParsedCategoryBudgetForm {
  const text = (name: string) => String(formData.get(name) ?? '').trim();
  const values: CategoryBudgetFormValues = {
    categoryId: text('category'),
    period: text('period'),
    amount: text('amount'),
    currency: text('currency'),
    threshold: text('threshold'),
  };
  const errors: Partial<Record<CategoryBudgetField, CategoryBudgetFieldError>> = {};

  if (!UUID.test(values.categoryId)) {
    errors.category = 'categoryRequired';
  }
  if (!isCategoryBudgetPeriod(values.period)) {
    errors.period = 'periodInvalid';
  }
  const amount = parseAmountInput(values.amount, locale);
  if (amount === null) {
    errors.amount = 'amountInvalid';
  }
  if (!isSupportedCurrency(values.currency)) {
    errors.currency = 'currencyInvalid';
  }
  const threshold = values.threshold === '' ? DEFAULT_THRESHOLD_PCT : parseThreshold(values.threshold);
  if (threshold === null) {
    errors.threshold = 'thresholdInvalid';
  }

  if (Object.keys(errors).length > 0 || amount === null || threshold === null || !isCategoryBudgetPeriod(values.period)) {
    return { ok: false, values, errors };
  }
  return {
    ok: true,
    values,
    params: {
      p_category_id: values.categoryId,
      p_period: values.period,
      p_amount: amount,
      p_currency: values.currency,
      p_threshold_pct: threshold,
    },
  };
}
