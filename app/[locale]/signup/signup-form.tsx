'use client';

import { useTranslations } from 'next-intl';
import { useActionState } from 'react';

import { Link } from '@/i18n/navigation';
import { signUp, type AuthFormState } from '@/lib/actions/auth';
import { PASSWORD_MIN_LENGTH } from '@/lib/validation';

const initialState: AuthFormState = { status: 'idle' };

export function SignupForm({ next }: { next: string | null }) {
  const t = useTranslations('Signup');
  const tValidation = useTranslations('Validation');
  const [state, formAction, isPending] = useActionState(signUp, initialState);
  const loginHref = next ? { pathname: '/login', query: { next } } : '/login';

  if (state.status === 'success') {
    return (
      <div role="status" className="form-success">
        <p>{state.message}</p>
        <p className="hint">
          {t.rich('noEmailReceived', { link: (chunks) => <Link href={loginHref}>{chunks}</Link> })}
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

      <label htmlFor="first_name">{t('firstName')}</label>
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

      <label htmlFor="last_name">{t('lastName')}</label>
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

      <label htmlFor="email">{t('email')}</label>
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

      <label htmlFor="password">{t('password')}</label>
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
        {tValidation('passwordHint', { min: PASSWORD_MIN_LENGTH })}
      </p>
      {fieldErrors.password ? (
        <p id="password-error" className="field-error">
          {fieldErrors.password}
        </p>
      ) : null}

      <p className="hint">
        {t.rich('privacyNotice', { link: (chunks) => <Link href="/datenschutz">{chunks}</Link> })}
      </p>

      <button type="submit" disabled={isPending}>
        {isPending ? t('submitting') : t('submit')}
      </button>

      <p className="hint">
        {t.rich('alreadyRegistered', { link: (chunks) => <Link href={loginHref}>{chunks}</Link> })}
      </p>
    </form>
  );
}
