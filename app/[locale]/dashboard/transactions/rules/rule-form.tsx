'use client';

/**
 * Neue Regel: Muster (Teil von Empfänger oder Verwendungszweck) → Kategorie.
 * Nach Erfolg wird das Formular geleert; die Liste lädt die Action neu.
 */
import { useTranslations } from 'next-intl';
import { startTransition, useActionState, type FormEvent } from 'react';

import { createRule, type RuleFormState } from '@/lib/actions/categorization-rules';

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
      <p id="rule-pattern-hint" className="hint">
        {t('patternHint')}
      </p>
      <button type="submit" disabled={isPending}>
        {isPending ? t('saving') : t('save')}
      </button>
    </form>
  );
}
