'use client';

/**
 * Eigenes Konto erkennen: eigener Name (Vor- und Nachname, alle Wörter im
 * Empfänger) oder eigene IBAN → Umbuchung. Nach Erfolg wird das Formular
 * geleert; die Liste lädt die Action neu.
 */
import { useTranslations } from 'next-intl';
import { startTransition, useActionState, type FormEvent } from 'react';

import { addOwnAccount, type OwnAccountFormState } from '@/lib/actions/categorization-rules';

const initialState: OwnAccountFormState = { status: 'idle' };

export function OwnAccountForm({ suggestedName }: { suggestedName: string }) {
  const t = useTranslations('Rules.ownAccounts');
  const [state, formAction, isPending] = useActionState(addOwnAccount, initialState);

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
          <select id="own-kind" name="kind" defaultValue={state.values?.kind ?? 'name'}>
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
      </div>
      <p id="own-value-hint" className="hint">
        {t('hint')}
      </p>
      <button type="submit" disabled={isPending}>
        {isPending ? t('saving') : t('save')}
      </button>
    </form>
  );
}
