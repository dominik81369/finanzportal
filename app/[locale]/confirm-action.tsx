'use client';

/**
 * Knopf mit Bestätigungsschritt für folgenreiche Aktionen (z. B. Zugriff
 * beenden): Der erste Klick blendet nur die Rückfrage ein, erst die
 * Bestätigung ruft die Server Action auf. Fokus in der Rückfrage auf
 * „Abbrechen“ – der sichere Standard.
 */
import { useActionState, useEffect, useId, useRef, useState } from 'react';

type ConfirmState = { status: 'idle' | 'error'; message?: string };

type ConfirmActionProps = {
  action: (state: ConfirmState, formData: FormData) => Promise<ConfirmState>;
  labels: {
    button: string;
    question: string;
    confirm: string;
    cancel: string;
    pending: string;
  };
  /** Zugänglicher Name des ersten Knopfs, z. B. mit dem Namen des Mandanten. */
  buttonLabel?: string;
};

const initialState: ConfirmState = { status: 'idle' };

export function ConfirmAction({ action, labels, buttonLabel }: ConfirmActionProps) {
  const [state, formAction, isPending] = useActionState(action, initialState);
  const [confirming, setConfirming] = useState(false);
  const cancelRef = useRef<HTMLButtonElement>(null);
  const questionId = useId();

  useEffect(() => {
    if (confirming) {
      cancelRef.current?.focus();
    }
  }, [confirming]);

  return (
    <div className="confirm-action">
      {state.status === 'error' && state.message ? (
        <p role="alert" className="form-error">
          {state.message}
        </p>
      ) : null}

      {confirming ? (
        <form action={formAction} className="confirm-box">
          <p id={questionId}>{labels.question}</p>
          <div className="actions">
            <button
              type="submit"
              className="button button-danger"
              disabled={isPending}
              aria-describedby={questionId}
            >
              {isPending ? labels.pending : labels.confirm}
            </button>
            <button
              ref={cancelRef}
              type="button"
              className="button button-secondary"
              disabled={isPending}
              onClick={() => setConfirming(false)}
            >
              {labels.cancel}
            </button>
          </div>
        </form>
      ) : (
        <button
          type="button"
          className="button button-danger-outline button-small"
          aria-label={buttonLabel}
          onClick={() => setConfirming(true)}
        >
          {labels.button}
        </button>
      )}
    </div>
  );
}
