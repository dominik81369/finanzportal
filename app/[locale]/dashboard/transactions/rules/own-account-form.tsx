'use client';

/**
 * Eigenes Konto erkennen: eigene IBAN (Zielkategorie wählbar, Standard
 * Umbuchung; automatisch zugeordnet) oder eigener Name (Vor- und Nachname;
 * nur Vorschlag in der Gruppenansicht). Nach Erfolg wird das Formular
 * geleert; die Liste lädt die Action neu.
 */
import { useTranslations } from 'next-intl';
import { startTransition, useActionState, useState, type FormEvent } from 'react';

import { addOwnAccount, type OwnAccountFormState } from '@/lib/actions/categorization-rules';

import { CategorySelect } from '../category-select';
import type { CategoryOption } from '../transaction-form';

const initialState: OwnAccountFormState = { status: 'idle' };

type OwnAccountFormProps = { suggestedName: string; categories: CategoryOption[] };

export function OwnAccountForm({ suggestedName, categories }: OwnAccountFormProps) {
  const t = useTranslations('Rules.ownAccounts');
  const [state, formAction, isPending] = useActionState(addOwnAccount, initialState);
  // Zielkategorie nur für IBANs; Namen sind Vorschläge für „Umbuchung“.
  const [kind, setKind] = useState(state.values?.kind ?? 'name');

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
      className="form own-account-form"
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
          <label htmlFor="own-kind">{t('kind')}</label>
          <select id="own-kind" name="kind" value={kind} onChange={(event) => setKind(event.target.value)}>
            <option value="name">{t('kinds.name')}</option>
            <option value="iban">{t('kinds.iban')}</option>
          </select>
        </div>
        <div className="filter-field">
          <label htmlFor="own-value">{t('value')}</label>
          <input
            id="own-value"
            name="value"
            required
            maxLength={200}
            placeholder={t('valuePlaceholder')}
            defaultValue={state.values?.value ?? suggestedName}
            aria-describedby="own-value-hint"
          />
        </div>
        {kind === 'iban' ? (
          <div className="filter-field">
            <label htmlFor="own-category">{t('category')}</label>
            <CategorySelect
              id="own-category"
              name="category"
              categories={categories}
              defaultValue={state.values?.categoryId ?? ''}
              emptyLabel={t('categoryDefault')}
            />
          </div>
        ) : null}
      </div>
      <p id="own-value-hint" className="hint">
        {kind === 'iban' ? t('hintIban') : t('hint')}
      </p>
      <button type="submit" disabled={isPending}>
        {isPending ? t('saving') : t('save')}
      </button>
    </form>
  );
}
