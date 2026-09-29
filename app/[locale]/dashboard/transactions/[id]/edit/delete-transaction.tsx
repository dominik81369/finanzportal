'use client';

/**
 * Löschen mit Bestätigungsschritt: Der erste Klick blendet nur die
 * Rückfrage ein, erst „Ja, endgültig löschen“ ruft die Server Action auf.
 */
import { useTranslations } from 'next-intl';
import { useActionState, useEffect, useRef, useState } from 'react';

import type { DeleteTransactionState } from '@/lib/actions/update-transaction';

type DeleteTransactionProps = {
  action: (state: DeleteTransactionState, formData: FormData) => Promise<DeleteTransactionState>;
};

const initialState: DeleteTransactionState = { status: 'idle' };

export function DeleteTransaction({ action }: DeleteTransactionProps) {
  const t = useTranslations('Transactions.edit.delete');
  const [state, formAction, isPending] = useActionState(action, initialState);
  const [confirming, setConfirming] = useState(false);
  const cancelRef = useRef<HTMLButtonElement>(null);

  // Fokus in die Rückfrage – sicherer Standard ist „Abbrechen“.
  useEffect(() => {
    if (confirming) {
      cancelRef.current?.focus();
    }
  }, [confirming]);

  return (
    <section className="danger-zone" aria-labelledby="delete-heading">
      <h2 id="delete-heading">{t('heading')}</h2>
      <p className="hint">{t('hint')}</p>

      {state.status === 'error' && state.message ? (
        <p role="alert" className="form-error">
          {state.message}
        </p>
      ) : null}

      {confirming ? (
        <form action={formAction} className="confirm-box">
          <p id="delete-confirm-question">{t('confirm')}</p>
          <div className="actions">
            <button
              type="submit"
              className="button button-danger"
              disabled={isPending}
              aria-describedby="delete-confirm-question"
            >
              {isPending ? t('deleting') : t('confirmButton')}
            </button>
            <button
              ref={cancelRef}
              type="button"
              className="button button-secondary"
              disabled={isPending}
              onClick={() => setConfirming(false)}
            >
              {t('cancel')}
            </button>
          </div>
        </form>
      ) : (
        <button
          type="button"
          className="button button-danger-outline"
          onClick={() => setConfirming(true)}
        >
          {t('button')}
        </button>
      )}
    </section>
  );
}
