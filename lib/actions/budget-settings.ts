'use server';

/**
 * lib/actions/budget-settings.ts
 *
 * Server Action: 50/30/20-Einstellungen speichern (Prozentziele,
 * Voreinstellung der Bezugsgröße, fester Monatsbetrag). Prüfung in
 * lib/budget-settings.ts und erneut in public.save_budget_settings()
 * (SECURITY INVOKER, nur eigene Zeile). Siehe
 * supabase/migrations/20261011100000_budget_b1.sql.
 */
import { revalidatePath } from 'next/cache';
import { getLocale, getTranslations } from 'next-intl/server';

import { toAppLocale } from '@/i18n/routing';
import {
  parseBudgetSettingsForm,
  type BudgetSettingsError,
  type BudgetSettingsField,
  type BudgetSettingsValues,
} from '@/lib/budget-settings';
import { createClient, requireOnboardedUser } from '@/lib/supabase/server';

export type BudgetSettingsState = {
  status: 'idle' | 'success' | 'error';
  message?: string;
  fieldErrors?: Partial<Record<BudgetSettingsField, string>>;
  values?: BudgetSettingsValues;
};

const RPC_ERRORS: Record<string, { field: BudgetSettingsField; key: BudgetSettingsError }> = {
  invalid_basis: { field: 'basis', key: 'basisInvalid' },
  invalid_percentages: { field: 'targets', key: 'percentSum' },
  invalid_fixed_amount: { field: 'fixedAmount', key: 'fixedAmountInvalid' },
};

export async function saveBudgetSettings(
  _prevState: BudgetSettingsState,
  formData: FormData,
): Promise<BudgetSettingsState> {
  await requireOnboardedUser('/dashboard/budgets');
  const t = await getTranslations('Budgets.settings');
  const parsed = parseBudgetSettingsForm(formData, toAppLocale(await getLocale()));
  if (!parsed.ok) {
    const fieldErrors: Partial<Record<BudgetSettingsField, string>> = {};
    for (const [field, key] of Object.entries(parsed.errors) as [BudgetSettingsField, BudgetSettingsError][]) {
      fieldErrors[field] = t(`errors.${key}`);
    }
    return { status: 'error', message: t('errors.summary'), fieldErrors, values: parsed.values };
  }

  const supabase = await createClient();
  const { error } = await supabase.rpc('save_budget_settings', parsed.params);
  if (error) {
    const mapped = RPC_ERRORS[error.message];
    if (mapped) {
      return {
        status: 'error',
        message: t('errors.summary'),
        fieldErrors: { [mapped.field]: t(`errors.${mapped.key}`) },
        values: parsed.values,
      };
    }
    console.error('[budget-settings] Speichern fehlgeschlagen', { code: error.code });
    return { status: 'error', message: t('errors.generic'), values: parsed.values };
  }

  revalidatePath('/[locale]/dashboard/budgets', 'page');
  return { status: 'success', message: t('saved'), values: parsed.values };
}
