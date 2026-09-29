'use client';

/**
 * „Erneut senden“ für eine offene Einladung: ruft inviteClient mit derselben
 * Adresse auf. Die Action zieht die alte Einladung zurück (alter Link wird
 * ungültig) und verschickt einen neuen Link mit neuer Laufzeit.
 */
import { useTranslations } from 'next-intl';
import { useActionState } from 'react';

import { inviteClient, type InviteClientState } from '@/lib/actions/invite-client';

const initialState: InviteClientState = { status: 'idle' };

export function ResendInvitation({ email }: { email: string }) {
  const t = useTranslations('Advisor.pending');
  const [state, formAction, isPending] = useActionState(inviteClient, initialState);

  return (
    <form action={formAction} className="resend-form">
      <input type="hidden" name="email" value={email} />
      <button
        type="submit"
        className="button button-secondary button-small"
        disabled={isPending}
        aria-label={t('resendLabel', { email })}
      >
        {isPending ? t('resending') : t('resend')}
      </button>
      {state.message ? (
        <p role={state.status === 'error' ? 'alert' : 'status'} className="hint">
          {state.message}
        </p>
      ) : null}
    </form>
  );
}
