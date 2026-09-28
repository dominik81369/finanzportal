'use client';

import Link from 'next/link';
import { useActionState } from 'react';

import { signUp, type AuthFormState } from '@/lib/actions/auth';
import { PASSWORD_MIN_LENGTH } from '@/lib/validation';

const initialState: AuthFormState = { status: 'idle' };

export function SignupForm({ next }: { next: string | null }) {
  const [state, formAction, isPending] = useActionState(signUp, initialState);
  const loginHref = next ? `/login?next=${encodeURIComponent(next)}` : '/login';

  if (state.status === 'success') {
    return (
      <div role="status" className="form-success">
        <p>{state.message}</p>
        <p className="hint">
          Keine E-Mail erhalten? Prüfen Sie Ihren Spam-Ordner oder{' '}
          <Link href={loginHref}>melden Sie sich an</Link>, falls Sie bereits ein Konto haben.
        </p>
      </div>
    );
  }

  const fieldErrors = state.fieldErrors ?? {};

  return (
    <form action={formAction} className="form">
      {next ? <input type="hidden" name="next" value={next} /> : null}

      {state.status === 'error' && state.message ? (
        <p role="alert" className="form-error">
          {state.message}
        </p>
      ) : null}

      <label htmlFor="first_name">Vorname</label>
      <input
        id="first_name"
        name="first_name"
        type="text"
        autoComplete="given-name"
        maxLength={100}
        defaultValue={state.values?.firstName ?? ''}
        aria-invalid={fieldErrors.firstName ? true : undefined}
        aria-describedby={fieldErrors.firstName ? 'first_name-error' : undefined}
      />
      {fieldErrors.firstName ? (
        <p id="first_name-error" className="field-error">
          {fieldErrors.firstName}
        </p>
      ) : null}

      <label htmlFor="last_name">Nachname</label>
      <input
        id="last_name"
        name="last_name"
        type="text"
        autoComplete="family-name"
        maxLength={100}
        defaultValue={state.values?.lastName ?? ''}
        aria-invalid={fieldErrors.lastName ? true : undefined}
        aria-describedby={fieldErrors.lastName ? 'last_name-error' : undefined}
      />
      {fieldErrors.lastName ? (
        <p id="last_name-error" className="field-error">
          {fieldErrors.lastName}
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
        aria-invalid={fieldErrors.email ? true : undefined}
        aria-describedby={fieldErrors.email ? 'email-error' : undefined}
      />
      {fieldErrors.email ? (
        <p id="email-error" className="field-error">
          {fieldErrors.email}
        </p>
      ) : null}

      <label htmlFor="password">Passwort</label>
      <input
        id="password"
        name="password"
        type="password"
        autoComplete="new-password"
        required
        minLength={PASSWORD_MIN_LENGTH}
        aria-invalid={fieldErrors.password ? true : undefined}
        aria-describedby={fieldErrors.password ? 'password-error password-hint' : 'password-hint'}
      />
      <p id="password-hint" className="hint">
        Mindestens {PASSWORD_MIN_LENGTH} Zeichen.
      </p>
      {fieldErrors.password ? (
        <p id="password-error" className="field-error">
          {fieldErrors.password}
        </p>
      ) : null}

      <p className="hint">
        Informationen zur Verarbeitung Ihrer Daten finden Sie in unserer{' '}
        <Link href="/datenschutz">Datenschutzerklärung</Link>.
      </p>

      <button type="submit" disabled={isPending}>
        {isPending ? 'Konto wird erstellt …' : 'Konto erstellen'}
      </button>

      <p className="hint">
        Bereits registriert? <Link href={loginHref}>Anmelden</Link>
      </p>
    </form>
  );
}
