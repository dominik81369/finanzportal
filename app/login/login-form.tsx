'use client';

import Link from 'next/link';
import { useActionState } from 'react';

import { signIn, type AuthFormState } from '@/lib/actions/auth';

const initialState: AuthFormState = { status: 'idle' };

export function LoginForm({ next }: { next: string | null }) {
  const [state, formAction, isPending] = useActionState(signIn, initialState);
  const signupHref = next ? `/signup?next=${encodeURIComponent(next)}` : '/signup';

  return (
    <form action={formAction} className="form">
      {next ? <input type="hidden" name="next" value={next} /> : null}

      {state.status === 'error' && state.message ? (
        <p role="alert" className="form-error">
          {state.message}
        </p>
      ) : null}

      <label htmlFor="email">E-Mail-Adresse</label>
      <input
        id="email"
        name="email"
        type="email"
        autoComplete="email"
        required
        maxLength={320}
        defaultValue={state.values?.email ?? ''}
      />

      <label htmlFor="password">Passwort</label>
      <input
        id="password"
        name="password"
        type="password"
        autoComplete="current-password"
        required
      />

      <button type="submit" disabled={isPending}>
        {isPending ? 'Anmeldung läuft …' : 'Anmelden'}
      </button>

      <p className="hint">
        Noch kein Konto? <Link href={signupHref}>Jetzt registrieren</Link>
      </p>
    </form>
  );
}
