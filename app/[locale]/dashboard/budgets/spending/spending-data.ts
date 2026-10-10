/**
 * Daten des Ausgaben-Dashboards: public.spending_report() für einen
 * Zeitraum und die Kategorien mit Anzeigenamen. Für die eigene Seite, die
 * Kachel auf der Übersicht und die Leseansicht des Beraters; die Abfragen
 * nennen user_id ausdrücklich (RLS gibt Beratern zusätzlich die Daten ihrer
 * Mandanten frei).
 */
import 'server-only';

import { getTranslations } from 'next-intl/server';

import { categoryDisplayName } from '@/lib/categories';
import { EMPTY_REPORT, type SpendingCategoryInfo, type SpendingReport } from '@/lib/spending';
import type { Bucket, DateRange } from '@/lib/spending-period';
import { createClient } from '@/lib/supabase/server';

/** Bericht für einen Zeitraum; null bei Fehler. */
export async function loadSpendingReport(
  userId: string,
  range: DateRange,
  bucket: Bucket,
  details: boolean,
): Promise<SpendingReport | null> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc('spending_report', {
    p_user_id: userId,
    p_from: range.from,
    p_to: range.to,
    p_bucket: bucket,
    p_details: details,
    p_limit: 10,
  });
  if (error) {
    console.error('[spending] Auswertung nicht ladbar', { code: error.code });
    return null;
  }
  return { ...EMPTY_REPORT, ...((data ?? {}) as Partial<SpendingReport>) };
}

/** Kategorien mit Anzeigename und Oberkategorie; null bei Fehler. */
export async function loadSpendingCategories(userId: string): Promise<SpendingCategoryInfo[] | null> {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('categories')
    .select('id, name, default_key, parent_category_id')
    .eq('user_id', userId);
  if (error) {
    console.error('[spending] Kategorien nicht ladbar', { code: error.code });
    return null;
  }
  const tCategories = await getTranslations('DefaultCategories');
  return data.map((category) => ({
    id: category.id,
    parentId: category.parent_category_id,
    label: categoryDisplayName(category, tCategories),
  }));
}

/** Gibt es überhaupt Buchungen? (Leerzustand mit Import) */
export async function hasTransactions(userId: string): Promise<boolean> {
  const supabase = await createClient();
  const { count } = await supabase.from('transactions').select('id', { count: 'exact', head: true }).eq('user_id', userId);
  return (count ?? 0) > 0;
}
