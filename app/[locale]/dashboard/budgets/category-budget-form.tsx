'use client';

/**
 * Formular für Einzelbudgets (./new, ./[id]): Kategorie, Zeitraum (Monat
 * oder Jahr), Höchstbetrag, Währung und Warnschwelle. Die Server Action
 * kommt als Prop: saveCategoryBudget.bind(null, null | id); nach Erfolg
 * navigiert das Formular zur Budgetseite.
 *
 * „Aus Durchschnitt übernehmen“ setzt einen Vorschlag aus den eigenen
 * Ausgaben ein (Monat: Durchschnitt der letzten 3 vollen Monate, Jahr:
 * Summe der letzten 12) – nur als Vorschlag, frei änderbar.
 */
import { useFormatter, useLocale, useTranslations } from 'next-intl';
import { startTransition, useActionState, useEffect, useState, type FormEvent, type ReactNode } from 'react';

import type { CategoryBudgetFormState } from '@/lib/actions/category-budgets';
import {
  CATEGORY_BUDGET_PERIODS,
  DEFAULT_THRESHOLD_PCT,
  isCategoryBudgetPeriod,
  type BudgetSuggestions,
  type CategoryBudgetField,
  type CategoryBudgetFormValues,
  type CategoryBudgetPeriod,
} from '@/lib/category-budgets';
import { SUPPORTED_CURRENCIES } from '@/lib/currency';

import { useShowResult } from '../action-form';
import type { CategoryBudgetOption } from './form-data';

type CategoryBudgetFormProps = {
  mode: 'create' | 'edit';
  action: (prevState: CategoryBudgetFormState, formData: FormData) => Promise<CategoryBudgetFormState>;
  categories: CategoryBudgetOption[];
  suggestions: BudgetSuggestions;
  windows: Record<CategoryBudgetPeriod, string>;
  initialValues?: CategoryBudgetFormValues;
};

const initialState: CategoryBudgetFormState = { status: 'idle' };

/** Einrückung der Unterkategorien in der Auswahlliste. */
const INDENT = ' ';

export function CategoryBudgetForm({ mode, action, categories, suggestions, windows, initialValues }: CategoryBudgetFormProps) {
  const t = useTranslations('CategoryBudgets.form');
  const format = useFormatter();
  const locale = useLocale();
  const showResult = useShowResult();
  const [state, formAction, isPending] = useActionState(action, initialState);
  const values = state.values ?? initialValues;

  useEffect(() => {
    const { status, redirectTo } = state;
    if (status === 'success' && redirectTo) {
      startTransition(() => showResult(redirectTo));
    }
  }, [state, showResult]);
  const fieldErrors = state.fieldErrors ?? {};

  // Kontrolliert, weil der Vorschlag von Kategorie, Zeitraum und Währung abhängt.
  const [categoryId, setCategoryId] = useState(values?.categoryId ?? '');
  const [period, setPeriod] = useState<CategoryBudgetPeriod>(
    values && isCategoryBudgetPeriod(values.period) ? values.period : 'monthly',
  );
  const [currency, setCurrency] = useState(values?.currency || 'EUR');
  const [amount, setAmount] = useState(values?.amount ?? '');

  const selected = categories.find((category) => category.id === categoryId);
  const suggestion = categoryId ? (suggestions[categoryId]?.[currency]?.[period] ?? null) : null;
  const suggestionText =
    categoryId === ''
      ? t('suggestion.pickCategory')
      : suggestion === null
        ? t(`suggestion.none.${period}`, { window: windows[period] })
        : t(`suggestion.${period}`, {
            window: windows[period],
            amount: format.number(suggestion / 100, { style: 'currency', currency }),
          });
  const applySuggestion = () => {
    if (suggestion !== null) {
      setAmount(
        new Intl.NumberFormat(locale, { minimumFractionDigits: 2, maximumFractionDigits: 2, useGrouping: false }).format(
          suggestion / 100,
        ),
      );
    }
  };

  const errorProps = (field: CategoryBudgetField, id: string, hintId?: string) => {
    const describedBy = [fieldErrors[field] ? `${id}-error` : null, hintId].filter(Boolean).join(' ');
    return {
      'aria-invalid': fieldErrors[field] ? true : undefined,
      'aria-describedby': describedBy || undefined,
    };
  };
  const fieldError = (field: CategoryBudgetField, id: string): ReactNode =>
    fieldErrors[field] ? (
      <p id={`${id}-error`} className="field-error">
        {fieldErrors[field]}
      </p>
    ) : null;

  // Ohne automatisches Zurücksetzen absenden; ohne JS greift action={formAction}.
  const handleSubmit = (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    const formData = new FormData(event.currentTarget);
    startTransition(() => formAction(formData));
  };

  return (
    <form action={formAction} onSubmit={handleSubmit} className="form category-budget-form">
      {state.status === 'error' && state.message ? (
        <p role="alert" className="form-error">
          {state.message}
        </p>
      ) : null}

      <label htmlFor="budget-category">{t('category')}</label>
      <select
        id="budget-category"
        name="category"
        required
        value={categoryId}
        onChange={(event) => setCategoryId(event.target.value)}
        {...errorProps('category', 'budget-category', 'budget-category-hint')}
      >
        <option value="">{t('categoryPlaceholder')}</option>
        {categories.map((category) => (
          <option key={category.id} value={category.id} disabled={category.taken}>
            {INDENT.repeat(category.depth)}
            {category.taken ? t('categoryTaken', { category: category.label }) : category.label}
          </option>
        ))}
      </select>
      <p id="budget-category-hint" className="hint">
        {t('categoryHint')}
      </p>
      {fieldError('category', 'budget-category')}
      {selected && selected.contracts.length > 0 ? (
        <p className="hint category-budget-contracts" role="note">
          {t('contractsHint', {
            names: selected.contracts.slice(0, 3).join(', '),
            more: Math.max(selected.contracts.length - 3, 0),
          })}
        </p>
      ) : null}

      <fieldset className="choice-group" {...errorProps('period', 'budget-period')}>
        <legend>{t('period')}</legend>
        {CATEGORY_BUDGET_PERIODS.map((option) => (
          <label key={option} className="choice">
            <input
              type="radio"
              name="period"
              value={option}
              checked={period === option}
              onChange={() => setPeriod(option)}
            />
            {t(`periods.${option}`)}
          </label>
        ))}
      </fieldset>
      {fieldError('period', 'budget-period')}

      <div className="category-budget-amount">
        <div className="budget-target-field">
          <label htmlFor="budget-amount">{t(`amount.${period}`)}</label>
          <input
            id="budget-amount"
            name="amount"
            type="text"
            inputMode="decimal"
            autoComplete="off"
            required
            maxLength={20}
            value={amount}
            onChange={(event) => setAmount(event.target.value)}
            {...errorProps('amount', 'budget-amount', 'budget-amount-hint')}
          />
        </div>
        <div className="budget-target-field">
          <label htmlFor="budget-currency">{t('currency')}</label>
          <select
            id="budget-currency"
            name="currency"
            value={currency}
            onChange={(event) => setCurrency(event.target.value)}
            {...errorProps('currency', 'budget-currency')}
          >
            {SUPPORTED_CURRENCIES.map((code) => (
              <option key={code} value={code}>
                {code}
              </option>
            ))}
          </select>
        </div>
      </div>
      {fieldError('amount', 'budget-amount')}
      {fieldError('currency', 'budget-currency')}
      <div className="category-budget-suggest">
        <button
          type="button"
          className="button button-secondary button-small"
          onClick={applySuggestion}
          disabled={suggestion === null}
          aria-describedby="budget-suggestion"
        >
          {t('suggest')}
        </button>
        <p id="budget-suggestion" className="hint" aria-live="polite">
          {suggestionText}
        </p>
      </div>
      <p id="budget-amount-hint" className="hint">
        {t('amountHint')}
      </p>

      <label htmlFor="budget-threshold">{t('threshold')}</label>
      <input
        id="budget-threshold"
        name="threshold"
        type="number"
        min={1}
        max={100}
        step={1}
        required
        defaultValue={values?.threshold || String(DEFAULT_THRESHOLD_PCT)}
        {...errorProps('threshold', 'budget-threshold', 'budget-threshold-hint')}
      />
      <p id="budget-threshold-hint" className="hint">
        {t('thresholdHint')}
      </p>
      {fieldError('threshold', 'budget-threshold')}

      <button type="submit" disabled={isPending || state.status === 'success'}>
        {isPending || state.status === 'success' ? t('saving') : mode === 'create' ? t('create') : t('save')}
      </button>
    </form>
  );
}
