'use client';

import { useActionState } from 'react';

import { acceptInvitation, type AcceptInvitationState } from '@/lib/actions/accept-invitation';

const initialState: AcceptInvitationState = { status: 'idle' };

export function AcceptInvitationForm({ token }: { token: string }) {
  const [state, formAction, isPending] = useActionState(acceptInvitation, initialState);

  return (
    <form action={formAction} className="form">
      <input type="hidden" name="token" value={token} />

      {state.status === 'error' && state.message ? (
        <p role="alert" className="form-error">
          {state.message}
        </p>
      ) : null}

      <button type="submit" disabled={isPending}>
        {isPending ? 'Einladung wird angenommen …' : 'Einladung annehmen'}
      </button>
    </form>
  );
}
