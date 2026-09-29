'use client';

import { useTranslations } from 'next-intl';
import { useActionState } from 'react';

import { Link } from '@/i18n/navigation';
import { signIn, type AuthFormState } from '@/lib/actions/auth';

const initialState: AuthFormState = { status: 'idle' };

export function LoginForm({ next }: { next: string | null }) {
  const t = useTranslations('Login');
  const [state, formAction, isPending] = useActionState(signIn, initialState);
  const signupHref = next ? { pathname: '/signup', query: { next } } : '/signup';

  return (
    <form action={formAction} className="form">
      {next ? <input type="hidden" name="next" value={next} /> : null}

      {state.status === 'error' && state.message ? (
        <p role="alert" className="form-error">
          {state.message}
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
      />

      <label htmlFor="password">{t('password')}</label>
      <input
        id="password"
        name="password"
        type="password"
        autoComplete="current-password"
        required
      />

      <button type="submit" disabled={isPending}>
        {isPending ? t('submitting') : t('submit')}
      </button>

      <p className="hint">
        {t.rich('noAccount', { link: (chunks) => <Link href={signupHref}>{chunks}</Link> })}
      </p>
    </form>
  );
}
