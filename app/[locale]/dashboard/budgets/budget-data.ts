/**
 * Summen für die 50/30/20-Auswertung (public.budget_category_totals) – für
 * die eigene Seite und die Leseansicht des Beraters. Die Abfrage nennt
 * user_id ausdrücklich: RLS lässt Beratern zusätzlich die Daten ihrer
 * Mandanten lesen.
 */
import 'server-only';

import { rangeDates, type CategoryTotalRow, type MonthRange } from '@/lib/budget-rule';
import { createClient } from '@/lib/supabase/server';

/** Summen je Monat, Währung und Kategorie; null bei Fehler. */
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
