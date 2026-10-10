'use server';

/**
 * lib/actions/budget-groups.ts
 *
 * Server Action: 50/30/20-Zuordnung der eigenen Kategorien speichern.
 *
 * Formularfelder group:<Kategorie-ID> = needs | wants | savings | none.
 * Gespeichert wird über public.set_category_budget_groups() in EINER
 * Anweisung (alles oder nichts, SECURITY INVOKER, nur eigene Kategorien).
 * Siehe supabase/migrations/20261002150000_budget_groups.sql.
 */
import { revalidatePath } from 'next/cache';
import { getTranslations } from 'next-intl/server';

import { BUDGET_GROUPS, EXCLUDED, type BudgetGroupKey } from '@/lib/budget-rule';
import { createClient, requireOnboardedUser } from '@/lib/supabase/server';
import { isUuid } from '@/lib/transactions';

export type BudgetGroupsState = { status: 'idle' | 'success' | 'error'; message?: string };

const FIELD_PREFIX = 'group:';
const MAX_ASSIGNMENTS = 500;

export async function saveBudgetGroups(
  _prevState: BudgetGroupsState,
  formData: FormData,
): Promise<BudgetGroupsState> {
  await requireOnboardedUser('/dashboard/budgets/50-30-20');
  const t = await getTranslations('Budgets.assignment');

  const assignments: { id: string; budget_group: BudgetGroupKey | null }[] = [];
  for (const [key, value] of formData.entries()) {
    if (!key.startsWith(FIELD_PREFIX)) {
      continue;
    }
    const id = key.slice(FIELD_PREFIX.length);
    if (
      !isUuid(id) ||
      typeof value !== 'string' ||
      (value !== EXCLUDED && !(BUDGET_GROUPS as readonly string[]).includes(value))
    ) {
      return { status: 'error', message: t('invalid') };
    }
    assignments.push({ id, budget_group: value === EXCLUDED ? null : (value as BudgetGroupKey) });
  }
  if (assignments.length === 0 || assignments.length > MAX_ASSIGNMENTS) {
    return { status: 'error', message: t('invalid') };
  }

  const supabase = await createClient();
  const { data, error } = await supabase.rpc('set_category_budget_groups', {
    p_assignments: assignments,
  });
  if (error) {
    console.error('[budget-groups] Speichern fehlgeschlagen', { code: error.code });
    return { status: 'error', message: error.code === '22023' ? t('invalid') : t('generic') };
  }

  revalidatePath('/[locale]/dashboard/budgets/50-30-20', 'page');
  return { status: 'success', message: t('saved', { count: data ?? 0 }) };
}
