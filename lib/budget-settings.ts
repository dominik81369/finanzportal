/**
 * lib/budget-settings.ts
 *
 * 50/30/20-Einstellungen: Zeile aus public.budget_settings in
 * BudgetSettings umsetzen und das Einstellungsformular prüfen. Reine
 * Funktionen (Server Action, Unit-Tests). Die Datenbank prüft dasselbe
 * noch einmal (public.save_budget_settings).
 */
import type { AppLocale } from '@/i18n/routing';
import {
  BUDGET_GROUPS,
  DEFAULT_BUDGET_SETTINGS,
  isBudgetBasis,
  type BudgetBasis,
  type BudgetGroupKey,
  type BudgetSettings,
} from '@/lib/budget-rule';
import { isSupportedCurrency } from '@/lib/currency';
import { parseAmountInput } from '@/lib/transactions';

export type BudgetSettingsRow = {
  basis: string;
  needs_pct: number | string;
  wants_pct: number | string;
  savings_pct: number | string;
  fixed_amount: number | string | null;
  fixed_currency: string;
};

/** Gespeicherte Einstellungen oder die Standardwerte. */
export function toBudgetSettings(row: BudgetSettingsRow | null | undefined): BudgetSettings {
  if (!row) {
    return DEFAULT_BUDGET_SETTINGS;
  }
  return {
    basis: isBudgetBasis(row.basis) ? row.basis : DEFAULT_BUDGET_SETTINGS.basis,
    targets: { needs: Number(row.needs_pct), wants: Number(row.wants_pct), savings: Number(row.savings_pct) },
    fixedAmount: row.fixed_amount === null ? null : Number(row.fixed_amount),
    fixedCurrency: row.fixed_currency,
  };
}

export type BudgetSettingsField = 'basis' | 'targets' | BudgetGroupKey | 'fixedAmount' | 'fixedCurrency';
export type BudgetSettingsError =
  | 'basisInvalid'
  | 'percentInvalid'
  | 'percentSum'
  | 'fixedAmountInvalid'
  | 'fixedAmountRequired'
  | 'currencyInvalid';

export type BudgetSettingsValues = {
  basis: string;
  needs: string;
  wants: string;
  savings: string;
  fixedAmount: string;
  fixedCurrency: string;
};

export type BudgetSettingsParams = {
  p_basis: BudgetBasis;
  p_needs_pct: number;
  p_wants_pct: number;
  p_savings_pct: number;
  p_fixed_amount: number | null;
  p_fixed_currency: string;
};

export type ParsedBudgetSettings =
  | { ok: true; values: BudgetSettingsValues; params: BudgetSettingsParams }
  | { ok: false; values: BudgetSettingsValues; errors: Partial<Record<BudgetSettingsField, BudgetSettingsError>> };

/** Prozentwert mit höchstens einer Nachkommastelle (Komma oder Punkt) in Zehnteln, sonst null. */
export function parsePercentTenths(input: string): number | null {
  const value = input.trim().replace(',', '.');
  if (!/^\d{1,3}(\.\d)?$/.test(value)) {
    return null;
  }
  const tenths = Math.round(Number(value) * 10);
  return tenths <= 1000 ? tenths : null;
}

type FormLike = { get(name: string): FormDataEntryValue | null };

export function parseBudgetSettingsForm(formData: FormLike, locale: AppLocale): ParsedBudgetSettings {
  const text = (name: string) => String(formData.get(name) ?? '').trim();
  const values: BudgetSettingsValues = {
    basis: text('basis'),
    needs: text('needs'),
    wants: text('wants'),
    savings: text('savings'),
    fixedAmount: text('fixed_amount'),
    fixedCurrency: text('fixed_currency') || 'EUR',
  };
  const errors: Partial<Record<BudgetSettingsField, BudgetSettingsError>> = {};

  if (!isBudgetBasis(values.basis)) {
    errors.basis = 'basisInvalid';
  }
  const tenths = {} as Record<BudgetGroupKey, number | null>;
  for (const group of BUDGET_GROUPS) {
    tenths[group] = parsePercentTenths(values[group]);
    if (tenths[group] === null) {
      errors[group] = 'percentInvalid';
    }
  }
  if (BUDGET_GROUPS.every((group) => tenths[group] !== null)) {
    const sum = BUDGET_GROUPS.reduce((total, group) => total + (tenths[group] ?? 0), 0);
    if (sum !== 1000) {
      errors.targets = 'percentSum';
    }
  }
  const fixedAmount = values.fixedAmount === '' ? null : parseAmountInput(values.fixedAmount, locale);
  if (values.fixedAmount !== '' && fixedAmount === null) {
    errors.fixedAmount = 'fixedAmountInvalid';
  } else if (values.basis === 'fixed' && fixedAmount === null) {
    errors.fixedAmount = 'fixedAmountRequired';
  }
  if (!isSupportedCurrency(values.fixedCurrency)) {
    errors.fixedCurrency = 'currencyInvalid';
  }

  if (Object.keys(errors).length > 0 || !isBudgetBasis(values.basis)) {
    return { ok: false, values, errors };
  }
  return {
    ok: true,
    values,
    params: {
      p_basis: values.basis,
      p_needs_pct: (tenths.needs ?? 0) / 10,
      p_wants_pct: (tenths.wants ?? 0) / 10,
      p_savings_pct: (tenths.savings ?? 0) / 10,
      p_fixed_amount: fixedAmount,
      p_fixed_currency: values.fixedCurrency,
    },
  };
}
