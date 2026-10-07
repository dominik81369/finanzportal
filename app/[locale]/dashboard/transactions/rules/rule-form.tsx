'use client';

/**
 * Neue Regel: Muster in einem Feld (Empfänger, Verwendungszweck, Transaktions-
 * typ, IBAN …) mit Vergleichsart und optionaler Richtung → Kategorie.
 * Nach Erfolg wird das Formular geleert; die Liste lädt die Action neu.
 */
import { useTranslations } from 'next-intl';
import { startTransition, useActionState, type FormEvent } from 'react';

import { createRule, type RuleFormState } from '@/lib/actions/categorization-rules';
import { RULE_DIRECTIONS, RULE_FIELDS, RULE_MATCH_TYPES } from '@/lib/import/rules';

import { CategorySelect } from '../category-select';
import type { CategoryOption } from '../transaction-form';

const initialState: RuleFormState = { status: 'idle' };

export function RuleForm({ categories }: { categories: CategoryOption[] }) {
  const t = useTranslations('Rules');
  const [state, formAction, isPending] = useActionState(createRule, initialState);

  // Selbst absenden: sonst setzt React das Formular auch nach Fehlern zurück.
  const handleSubmit = (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    const formData = new FormData(event.currentTarget);
    startTransition(() => formAction(formData));
  };

  return (
    <form
      action={formAction}
      onSubmit={handleSubmit}
      className="form rule-form"
      key={state.status === 'success' ? `ok-${state.nonce}` : 'form'}
    >
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
      <div className="field-row">
        <div className="filter-field">
          <label htmlFor="rule-pattern">{t('pattern')}</label>
          <input
            id="rule-pattern"
            name="pattern"
            required
            minLength={2}
            maxLength={200}
            placeholder={t('patternPlaceholder')}
            defaultValue={state.values?.pattern ?? ''}
            aria-describedby="rule-pattern-hint"
          />
        </div>
        <div className="filter-field">
          <label htmlFor="rule-category">{t('category')}</label>
          <CategorySelect
            id="rule-category"
            name="category"
            categories={categories}
            defaultValue={state.values?.categoryId ?? ''}
            emptyLabel={t('choose')}
            required
          />
        </div>
      </div>
      <div className="field-row">
        <div className="filter-field">
          <label htmlFor="rule-field">{t('field')}</label>
          <select id="rule-field" name="field" defaultValue={state.values?.field ?? 'counterparty_or_purpose'}>
            {RULE_FIELDS.map((field) => (
              <option key={field} value={field}>
                {t(`fields.${field}`)}
              </option>
            ))}
          </select>
        </div>
        <div className="filter-field">
          <label htmlFor="rule-match-type">{t('matchType')}</label>
          <select id="rule-match-type" name="matchType" defaultValue={state.values?.matchType ?? 'contains'}>
            {RULE_MATCH_TYPES.map((type) => (
              <option key={type} value={type}>
                {t(`matchTypes.${type}`)}
              </option>
            ))}
          </select>
        </div>
        <div className="filter-field">
          <label htmlFor="rule-direction">{t('direction')}</label>
          <select id="rule-direction" name="direction" defaultValue={state.values?.direction ?? ''}>
            {RULE_DIRECTIONS.map((direction) => (
              <option key={direction || 'both'} value={direction}>
                {t(`directions.${direction || 'both'}`)}
              </option>
            ))}
          </select>
        </div>
      </div>
      <p id="rule-pattern-hint" className="hint">
        {t('patternHint')}
      </p>
      <button type="submit" disabled={isPending}>
        {isPending ? t('saving') : t('save')}
      </button>
    </form>
  );
}
