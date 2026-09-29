'use client';

/**
 * Einladung eines Mandanten per E-Mail (Server Action inviteClient). Nach
 * Erfolg wird das Feld geleert; die Liste der offenen Einladungen lädt die
 * Action per revalidatePath neu.
 */
import { useTranslations } from 'next-intl';
import { startTransition, useActionState, type FormEvent } from 'react';

import { inviteClient, type InviteClientState } from '@/lib/actions/invite-client';

const initialState: InviteClientState = { status: 'idle' };

export function InviteForm({ validDays }: { validDays: number }) {
  const t = useTranslations('Advisor.invite');
  const [state, formAction, isPending] = useActionState(inviteClient, initialState);

  // Selbst absenden: React würde das Formular sonst auch nach einem Fehler
  // zurücksetzen. Nach Erfolg leeren wir es bewusst.
  const handleSubmit = (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    const formData = new FormData(event.currentTarget);
    startTransition(() => formAction(formData));
  };

  return (
    <form
      action={formAction}
      onSubmit={handleSubmit}
      className="form invite-form"
      // Nach Erfolg neu aufbauen → Feld leer für die nächste Einladung.
      key={state.status === 'success' ? state.message : 'form'}
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

      <label htmlFor="invite-email">{t('email')}</label>
      <div className="inline-field">
        <input
          id="invite-email"
          name="email"
          type="email"
          autoComplete="off"
          required
          maxLength={320}
          defaultValue={state.status === 'error' ? (state.values?.email ?? '') : ''}
          aria-describedby="invite-hint"
        />
        <button type="submit" disabled={isPending}>
          {isPending ? t('submitting') : t('submit')}
        </button>
      </div>
      <p id="invite-hint" className="hint">
        {t('hint', { days: validDays })}
      </p>
    </form>
  );
}
