'use client';

/**
 * 50/30/20-Einstellungen: Voreinstellung der Bezugsgröße, Prozentziele je
 * Gruppe (eine Nachkommastelle, Summe 100 – live angezeigt) und fester
 * Monatsbetrag mit Währung. Gespeichert über lib/actions/budget-settings.ts;
 * die Seite wird danach neu berechnet (revalidatePath).
 */
import { useFormatter, useLocale, useTranslations } from 'next-intl';
import { startTransition, useActionState, useState, type FormEvent, type ReactNode } from 'react';

import { saveBudgetSettings, type BudgetSettingsState } from '@/lib/actions/budget-settings';
import { BUDGET_BASES, BUDGET_GROUPS, type BudgetGroupKey, type BudgetSettings } from '@/lib/budget-rule';
import { parsePercentTenths, type BudgetSettingsField } from '@/lib/budget-settings';
import { SUPPORTED_CURRENCIES } from '@/lib/currency';

const initialState: BudgetSettingsState = { status: 'idle' };

export function BudgetSettingsForm({ settings }: { settings: BudgetSettings }) {
  const t = useTranslations('Budgets');
  const format = useFormatter();
  const locale = useLocale();
  const [state, formAction, isPending] = useActionState(saveBudgetSettings, initialState);
  const fieldErrors = state.fieldErrors ?? {};
  const decimal = (value: number) =>
    new Intl.NumberFormat(locale, { maximumFractionDigits: 2, useGrouping: false }).format(value);

  // Kontrolliert, damit die Summe live angezeigt wird.
  const [targets, setTargets] = useState<Record<BudgetGroupKey, string>>(() => ({
    needs: state.values?.needs ?? decimal(settings.targets.needs),
    wants: state.values?.wants ?? decimal(settings.targets.wants),
    savings: state.values?.savings ?? decimal(settings.targets.savings),
  }));
  const tenths = BUDGET_GROUPS.map((group) => parsePercentTenths(targets[group]));
  const sum = tenths.every((value) => value !== null) ? tenths.reduce((a, b) => a + (b ?? 0), 0) / 10 : null;

  const errorProps = (field: BudgetSettingsField, id: string, hintId?: string) => {
    const describedBy = [fieldErrors[field] ? `${id}-error` : null, hintId].filter(Boolean).join(' ');
    return { 'aria-invalid': fieldErrors[field] ? true : undefined, 'aria-describedby': describedBy || undefined };
  };
  const fieldError = (field: BudgetSettingsField, id: string): ReactNode =>
    fieldErrors[field] ? (
      <p id={`${id}-error`} className="field-error">
        {fieldErrors[field]}
      </p>
    ) : null;

  const handleSubmit = (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    const formData = new FormData(event.currentTarget);
    startTransition(() => formAction(formData));
  };

  return (
    <form action={formAction} onSubmit={handleSubmit} className="form budget-settings-form">
      {state.status === 'error' && state.message ? (
        <p role="alert" className="form-error">
          {state.message}
        </p>
      ) : null}
      {state.status === 'success' && state.message ? (
        <p role="status" className="form-success">
          {state.message}
        </p>
      ) : null}

      <label htmlFor="budget-default-basis">{t('settings.basis')}</label>
      <select
        id="budget-default-basis"
        name="basis"
        defaultValue={state.values?.basis ?? settings.basis}
        {...errorProps('basis', 'budget-default-basis')}
      >
        {BUDGET_BASES.map((basis) => (
          <option key={basis} value={basis}>
            {t(`basis.options.${basis}`)}
          </option>
        ))}
      </select>
      {fieldError('basis', 'budget-default-basis')}

      <fieldset className="budget-targets" {...errorProps('targets', 'budget-targets', 'budget-targets-sum')}>
        <legend>{t('settings.targets')}</legend>
        <div className="budget-target-fields">
          {BUDGET_GROUPS.map((group) => {
            const id = `budget-target-${group}`;
            return (
              <div key={group} className="budget-target-field">
                <label htmlFor={id}>{t(`groups.${group}`)}</label>
                <input
                  id={id}
                  name={group}
                  type="text"
                  inputMode="decimal"
                  autoComplete="off"
                  required
                  maxLength={5}
                  value={targets[group]}
                  onChange={(event) => {
                    const value = event.target.value;
                    setTargets((current) => ({ ...current, [group]: value }));
                  }}
                  {...errorProps(group, id)}
                />
                {fieldError(group, id)}
              </div>
            );
          })}
        </div>
        <p
          id="budget-targets-sum"
          className={`budget-sum ${sum !== null && sum !== 100 ? 'budget-sum-invalid' : ''}`}
          aria-live="polite"
        >
          {t('settings.sum', {
            sum: sum === null ? '–' : format.number(sum / 100, { style: 'percent', maximumFractionDigits: 1 }),
          })}
        </p>
      </fieldset>
      {fieldError('targets', 'budget-targets')}

      <div className="budget-fixed-fields">
        <div className="budget-target-field">
          <label htmlFor="budget-fixed-amount">{t('settings.fixedAmount')}</label>
          <input
            id="budget-fixed-amount"
            name="fixed_amount"
            type="text"
            inputMode="decimal"
            autoComplete="off"
            maxLength={20}
            defaultValue={
              state.values?.fixedAmount ??
              (settings.fixedAmount === null
                ? ''
                : new Intl.NumberFormat(locale, { minimumFractionDigits: 2, useGrouping: false }).format(
                    settings.fixedAmount,
                  ))
            }
            {...errorProps('fixedAmount', 'budget-fixed-amount', 'budget-fixed-hint')}
          />
          {fieldError('fixedAmount', 'budget-fixed-amount')}
        </div>
        <div className="budget-target-field">
          <label htmlFor="budget-fixed-currency">{t('settings.fixedCurrency')}</label>
          <select
            id="budget-fixed-currency"
            name="fixed_currency"
            defaultValue={state.values?.fixedCurrency ?? settings.fixedCurrency}
            {...errorProps('fixedCurrency', 'budget-fixed-currency')}
          >
            {SUPPORTED_CURRENCIES.map((code) => (
              <option key={code} value={code}>
                {code}
              </option>
            ))}
          </select>
        </div>
      </div>
      <p id="budget-fixed-hint" className="hint">
        {t('settings.fixedHint')}
      </p>

      <button type="submit" disabled={isPending}>
        {isPending ? t('settings.saving') : t('settings.save')}
      </button>
    </form>
  );
}
