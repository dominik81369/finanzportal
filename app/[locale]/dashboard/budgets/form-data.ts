/**
 * Daten des Budgetformulars: Ausgabenkategorien in Baumreihenfolge (mit
 * Kennzeichnung, ob sie schon ein Budget haben), aktive Verträge je
 * Kategorie (Hinweis „meist Fixkosten“) und Vorschläge aus den Ausgaben
 * der letzten 3 bzw. 12 vollen Monate. Nur eigene Daten.
 */
import 'server-only';

import { getFormatter } from 'next-intl/server';

import type { MonthRange } from '@/lib/budget-rule';
import { budgetSuggestions, suggestionWindows, type BudgetSuggestions, type CategoryBudgetPeriod } from '@/lib/category-budgets';
import { createClient } from '@/lib/supabase/server';
import { todayInGermany } from '@/lib/transactions';

import { loadBudgetCategories, loadCategoryBudgets, loadCategoryTotals } from './budget-data';

export type CategoryBudgetOption = {
  id: string;
  label: string;
  depth: number;
  /** Hat schon ein Budget (außer dem gerade bearbeiteten). */
  taken: boolean;
  /** Aktive Verträge in der Kategorie oder ihren Unterkategorien. */
  contracts: string[];
};

export type CategoryBudgetFormData = {
  categories: CategoryBudgetOption[];
  suggestions: BudgetSuggestions;
  /** Grundlage der Vorschläge als Text, z. B. „August bis Oktober 2026“. */
  windows: Record<CategoryBudgetPeriod, string>;
};

/** null, wenn eine der Abfragen fehlschlägt. */
export async function loadCategoryBudgetFormData(
  userId: string,
  editingId: string | null,
): Promise<CategoryBudgetFormData | null> {
  const supabase = await createClient();
  const format = await getFormatter();
  const currentMonth = todayInGermany().slice(0, 7);
  const windows = suggestionWindows(currentMonth);

  const [categories, budgets, totals, contracts] = await Promise.all([
    loadBudgetCategories(userId),
    loadCategoryBudgets(userId),
    loadCategoryTotals(userId, windows.yearly),
    supabase
      .from('recurring_contracts')
      .select('name, category_id')
      .eq('user_id', userId)
      .in('status', ['active', 'cancellation_pending'])
      .not('category_id', 'is', null)
      .order('name'),
  ]);
  if (contracts.error) {
    console.error('[budgets] Verträge für das Budgetformular nicht ladbar', { code: contracts.error.code });
  }
  if (!categories || !budgets || !totals || contracts.error) {
    return null;
  }

  const taken = new Set(budgets.filter((budget) => budget.id !== editingId).map((budget) => budget.category_id));
  const children = new Map<string, string[]>();
  for (const category of categories) {
    if (category.parentId) {
      children.set(category.parentId, [...(children.get(category.parentId) ?? []), category.id]);
    }
  }
  const contractNames = (id: string, seen = new Set<string>()): string[] => {
    if (seen.has(id)) {
      return [];
    }
    seen.add(id);
    return [
      ...contracts.data.filter((contract) => contract.category_id === id).map((contract) => contract.name),
      ...(children.get(id) ?? []).flatMap((child) => contractNames(child, seen)),
    ];
  };

  const monthText = (month: string, withYear: boolean) =>
    format.dateTime(new Date(`${month}-01T00:00:00Z`), {
      month: 'long',
      ...(withYear ? { year: 'numeric' } : {}),
      timeZone: 'UTC',
    });
  const windowText = (window: MonthRange) =>
    `${monthText(window.from, window.from.slice(0, 4) !== window.to.slice(0, 4))} – ${monthText(window.to, true)}`;

  return {
    categories: categories
      .filter((category) => category.kind === 'expense')
      .map((category) => ({
        id: category.id,
        label: category.label,
        depth: category.depth,
        taken: taken.has(category.id),
        contracts: [...new Set(contractNames(category.id))],
      })),
    suggestions: budgetSuggestions(totals, categories, currentMonth),
    windows: { monthly: windowText(windows.monthly), yearly: windowText(windows.yearly) },
  };
}
