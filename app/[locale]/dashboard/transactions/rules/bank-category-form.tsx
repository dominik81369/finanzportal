'use client';

/**
 * Kartenkategorie der Bank hinzufügen: Bezeichnung wie in der Buchungsart
 * (z. B. „Lebensmittel“ aus „Mastercard • Lebensmittel“) → eigene
 * Kategorie. Nach Erfolg wird das Formular geleert; die Liste lädt die
 * Action neu.
 */
import { useTranslations } from 'next-intl';
import { startTransition, useActionState, type FormEvent } from 'react';

import { addBankCategory, type BankCategoryFormState } from '@/lib/actions/categorization-rules';

import { CategorySelect } from '../category-select';
import type { CategoryOption } from '../transaction-form';

const initialState: BankCategoryFormState = { status: 'idle' };

export function BankCategoryForm({ categories }: { categories: CategoryOption[] }) {
  const t = useTranslations('Rules.bankCategories');
  const [state, formAction, isPending] = useActionState(addBankCategory, initialState);

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
      className="form bank-category-form"
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
          <label htmlFor="bank-label">{t('label')}</label>
          <input
            id="bank-label"
            name="label"
            required
            minLength={2}
            maxLength={100}
            placeholder={t('labelPlaceholder')}
            defaultValue={state.values?.label ?? ''}
          />
        </div>
        <div className="filter-field">
          <label htmlFor="bank-category">{t('category')}</label>
          <CategorySelect
            id="bank-category"
            name="category"
            categories={categories}
            defaultValue={state.values?.categoryId ?? ''}
            emptyLabel={t('choose')}
            required
          />
        </div>
      </div>
      <button type="submit" disabled={isPending}>
        {isPending ? t('saving') : t('save')}
      </button>
    </form>
  );
}
