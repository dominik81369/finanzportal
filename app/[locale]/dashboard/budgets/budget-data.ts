/**
 * Daten für Einzelbudgets (Budget-2): Kategorien in Baumreihenfolge mit
 * Anzeigenamen, Kategoriebudgets und deren Auswertung für einen Zeitraum.
 * Gemeinsam für Budgetseite, Formulare, Übersicht und Leseansicht des
 * Beraters.
 *
 * Alle Abfragen filtern ausdrücklich auf user_id = userId: RLS lässt
 * Beratern zusätzlich die Daten ihrer Mandanten lesen.
 */
import 'server-only';

import { getTranslations } from 'next-intl/server';

import { rangeDates, type CategoryTotalRow, type MonthRange } from '@/lib/budget-rule';
import { categoryDisplayName, orderCategoryTree } from '@/lib/categories';
import {
  evaluateCategoryBudgets,
  evaluationStart,
  type BudgetCategory,
  type CategoryBudgetResult,
  type CategoryBudgetRow,
} from '@/lib/category-budgets';
import { createClient } from '@/lib/supabase/server';

/** Kategorie mit Anzeigename („Oberkategorie › Unterkategorie“) und Tiefe. */
export type BudgetCategoryInfo = BudgetCategory & { name: string; label: string; depth: number };

/** Alle Kategorien des Nutzers in Baumreihenfolge; null bei Fehler. */
export async function loadBudgetCategories(userId: string): Promise<BudgetCategoryInfo[] | null> {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('categories')
    .select('id, name, default_key, kind, parent_category_id, budget_group')
    .eq('user_id', userId)
    .order('sort_order')
    .order('name');
  if (error) {
    console.error('[budgets] Kategorien nicht ladbar', { code: error.code });
    return null;
  }
  const tCategories = await getTranslations('DefaultCategories');
  const names = new Map(data.map((c) => [c.id, categoryDisplayName(c, tCategories)]));
  return orderCategoryTree(data).map(({ category, depth }) => {
    const name = names.get(category.id) ?? category.name;
    const parent = category.parent_category_id ? names.get(category.parent_category_id) : undefined;
    return {
      id: category.id,
      parentId: category.parent_category_id,
      group: category.budget_group,
      kind: category.kind,
      name,
      label: parent ? `${parent} › ${name}` : name,
      depth,
    };
  });
}

/** Aktive Kategoriebudgets des Nutzers; null bei Fehler. */
export async function loadCategoryBudgets(userId: string): Promise<CategoryBudgetRow[] | null> {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('budgets')
    .select('id, category_id, period, amount, currency, alert_threshold_pct')
    .eq('user_id', userId)
    .eq('is_active', true)
    .not('category_id', 'is', null);
  if (error) {
    console.error('[budgets] Einzelbudgets nicht ladbar', { code: error.code });
    return null;
  }
  return data.map((row) => ({ ...row, category_id: row.category_id! }));
}

/** Summen je Monat, Währung und Kategorie (public.budget_category_totals); null bei Fehler. */
export async function loadCategoryTotals(userId: string, range: MonthRange): Promise<CategoryTotalRow[] | null> {
  const supabase = await createClient();
  const { fromDate, toDate } = rangeDates(range);
  const { data, error } = await supabase.rpc('budget_category_totals', {
    p_user_id: userId,
    p_from: fromDate,
    p_to: toDate,
  });
  if (error) {
    console.error('[budgets] Summen nicht ladbar', { code: error.code });
    return null;
  }
  return (data ?? []) as CategoryTotalRow[];
}

export type EvaluatedBudgets = {
  categories: BudgetCategoryInfo[];
  results: CategoryBudgetResult[];
};

/**
 * Einzelbudgets für den Zeitraum auswerten (Übersicht). rows dürfen
 * übergeben werden, wenn sie den Bereich ab evaluationStart(range) schon
 * abdecken; sonst werden sie geladen. null bei Fehler.
 */
export async function evaluateBudgetsFor(
  userId: string,
  range: MonthRange,
  rows?: CategoryTotalRow[],
): Promise<EvaluatedBudgets | null> {
  const [categories, budgets, totals] = await Promise.all([
    loadBudgetCategories(userId),
    loadCategoryBudgets(userId),
    rows ?? loadCategoryTotals(userId, { from: evaluationStart(range), to: range.to }),
  ]);
  if (!categories || !budgets || !totals) {
    return null;
  }
  return { categories, results: evaluateCategoryBudgets(budgets, categories, totals, range) };
}
