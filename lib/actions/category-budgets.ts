'use server';

/**
 * lib/actions/category-budgets.ts
 *
 * Server Actions für Einzelbudgets (Budget-2): anlegen, ändern, löschen.
 * Prüfung im Formular (lib/category-budgets.ts) und in der Datenbank
 * (public.save_category_budget, SECURITY INVOKER: nur eigene
 * Ausgabenkategorien, ein Budget je Kategorie). Löschen über RLS
 * (budgets_delete_owner) und ausdrücklich user_id = eigener Nutzer.
 *
 * Wie bei den Verträgen kein redirect(): Die Budgetseite streamt ihre
 * Auswertung; die Actions liefern das Ziel ({ redirectTo }), der Client
 * navigiert selbst (action-form.tsx, category-budget-form.tsx).
 */
import { getLocale, getTranslations } from 'next-intl/server';

import { localizedPath } from '@/i18n/paths';
import { toAppLocale } from '@/i18n/routing';
import {
  parseCategoryBudgetForm,
  type CategoryBudgetField,
  type CategoryBudgetFieldError,
  type CategoryBudgetFormValues,
} from '@/lib/category-budgets';
import { createClient, requireOnboardedUser } from '@/lib/supabase/server';
import { isUuid } from '@/lib/transactions';

const BUDGETS_PATH = '/dashboard/budgets';

export type CategoryBudgetFormState = {
  status: 'idle' | 'error' | 'success';
  message?: string;
  fieldErrors?: Partial<Record<CategoryBudgetField, string>>;
  /** Zum Vorbelegen des Formulars nach einem Fehler. */
  values?: CategoryBudgetFormValues;
  /** Nach Erfolg: Ziel der Navigation (lokalisiert, mit Meldung). */
  redirectTo?: string;
};

/** Ergebnis der Knopf-Actions: wohin der Client danach navigiert. */
export type CategoryBudgetActionResult = { redirectTo: string };

async function target(path: string, params: Record<string, string>): Promise<CategoryBudgetActionResult> {
  const query = new URLSearchParams(params).toString();
  return { redirectTo: `${await localizedPath(path)}${query ? `?${query}` : ''}` };
}

const RPC_FIELD_ERRORS: Record<string, { field: CategoryBudgetField; key: CategoryBudgetFieldError | 'categoryTaken' }> = {
  invalid_period: { field: 'period', key: 'periodInvalid' },
  invalid_amount: { field: 'amount', key: 'amountInvalid' },
  invalid_currency: { field: 'currency', key: 'currencyInvalid' },
  invalid_threshold: { field: 'threshold', key: 'thresholdInvalid' },
  invalid_category: { field: 'category', key: 'categoryRequired' },
  budget_exists: { field: 'category', key: 'categoryTaken' },
};

/**
 * Budget anlegen (budgetId null) oder ändern. Bei Erfolg zurück zur
 * Budgetseite mit Meldung, sonst Fehler mit den eingegebenen Werten.
 */
export async function saveCategoryBudget(
  budgetId: string | null,
  _prevState: CategoryBudgetFormState,
  formData: FormData,
): Promise<CategoryBudgetFormState> {
  await requireOnboardedUser(budgetId ? `${BUDGETS_PATH}/${budgetId}` : `${BUDGETS_PATH}/new`);
  const t = await getTranslations('CategoryBudgets.form.errors');
  const locale = toAppLocale(await getLocale());

  const parsed = parseCategoryBudgetForm(formData, locale);
  if (!parsed.ok) {
    const fieldErrors: Partial<Record<CategoryBudgetField, string>> = {};
    for (const [field, key] of Object.entries(parsed.errors) as [CategoryBudgetField, CategoryBudgetFieldError][]) {
      fieldErrors[field] = t(key);
    }
    return { status: 'error', message: t('summary'), fieldErrors, values: parsed.values };
  }
  if (budgetId !== null && !isUuid(budgetId)) {
    return { status: 'error', message: t('notFound'), values: parsed.values };
  }

  const supabase = await createClient();
  const { data, error } = await supabase.rpc('save_category_budget', { p_id: budgetId, ...parsed.params });
  if (error || !data) {
    const mapped = error ? RPC_FIELD_ERRORS[error.message] : undefined;
    if (mapped) {
      return {
        status: 'error',
        message: t('summary'),
        fieldErrors: { [mapped.field]: t(mapped.key) },
        values: parsed.values,
      };
    }
    if (error?.message === 'budget_not_found') {
      return { status: 'error', message: t('notFound'), values: parsed.values };
    }
    console.error('[budgets] Einzelbudget speichern fehlgeschlagen', { code: error?.code });
    return { status: 'error', message: t('generic'), values: parsed.values };
  }

  const { redirectTo } = await target(BUDGETS_PATH, { budget: budgetId ? 'saved' : 'created' });
  return { status: 'success', redirectTo };
}

/** Budget löschen; Buchungen und Kategorie bleiben unverändert. */
export async function deleteCategoryBudget(budgetId: string): Promise<CategoryBudgetActionResult> {
  const user = await requireOnboardedUser(`${BUDGETS_PATH}/${budgetId}`);
  if (!isUuid(budgetId)) {
    return target(BUDGETS_PATH, { budget: 'error' });
  }
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('budgets')
    .delete()
    .eq('id', budgetId)
    .eq('user_id', user.id)
    .not('category_id', 'is', null)
    .select('id');
  if (error || !data || data.length === 0) {
    if (error) {
      console.error('[budgets] Einzelbudget löschen fehlgeschlagen', { code: error.code });
    }
    return target(`${BUDGETS_PATH}/${budgetId}`, { error: '1' });
  }
  return target(BUDGETS_PATH, { budget: 'deleted' });
}
