'use client';

/**
 * Einstellungen des Lernverfahrens: Schwelle für automatische Zuordnung (in
 * Prozent) und Prüfgrenze (ab diesem Betrag immer in die Prüfliste; gilt
 * nicht für Regeln und Gedächtnis).
 */
import { useTranslations } from 'next-intl';
import { startTransition, useActionState, type FormEvent } from 'react';

import { saveCategorizationSettings, type SettingsFormState } from '@/lib/actions/categorization-rules';

const initialState: SettingsFormState = { status: 'idle' };

export function LearningForm({ threshold, limit }: { threshold: number; limit: number }) {
  const t = useTranslations('Rules.learning');
  const [state, formAction, isPending] = useActionState(saveCategorizationSettings, initialState);

  const handleSubmit = (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    const formData = new FormData(event.currentTarget);
    startTransition(() => formAction(formData));
  };

  return (
    <form action={formAction} onSubmit={handleSubmit} className="form learning-form">
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
          <label htmlFor="learning-threshold">{t('threshold')}</label>
          <input
            id="learning-threshold"
            name="threshold"
            type="number"
            min={50}
            max={99.9}
            step={0.1}
            required
            defaultValue={Math.round(threshold * 1000) / 10}
            aria-describedby="learning-hint"
          />
        </div>
        <div className="filter-field">
          <label htmlFor="learning-limit">{t('limit')}</label>
          <input
            id="learning-limit"
            name="limit"
            type="number"
            min={1}
            step={1}
            required
            defaultValue={limit}
            aria-describedby="learning-hint"
          />
        </div>
      </div>
      <p id="learning-hint" className="hint">
        {t('hint')}
      </p>
      <button type="submit" disabled={isPending}>
        {isPending ? t('saving') : t('save')}
      </button>
    </form>
  );
}
