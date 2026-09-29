'use client';

import { useTranslations } from 'next-intl';
import { useActionState } from 'react';

import { setPassword, type SetPasswordState } from '@/lib/actions/set-password';
import { PASSWORD_MIN_LENGTH } from '@/lib/validation';

const initialState: SetPasswordState = { status: 'idle' };

export function SetPasswordForm({ next }: { next: string }) {
  const t = useTranslations('SetPassword');
  const tValidation = useTranslations('Validation');
  const [state, formAction, isPending] = useActionState(setPassword, initialState);
  const fieldErrors = state.fieldErrors ?? {};

  return (
    <form action={formAction} className="form">
      <input type="hidden" name="next" value={next} />

      {state.status === 'error' && state.message ? (
        <p role="alert" className="form-error">
          {state.message}
        </p>
      ) : null}

      <label htmlFor="password">{t('newPassword')}</label>
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

      <label htmlFor="password_confirm">{t('confirmPassword')}</label>
      <input
        id="password_confirm"
        name="password_confirm"
        type="password"
        autoComplete="new-password"
        required
        minLength={PASSWORD_MIN_LENGTH}
        aria-invalid={fieldErrors.passwordConfirm ? true : undefined}
        aria-describedby={fieldErrors.passwordConfirm ? 'password_confirm-error' : undefined}
      />
      {fieldErrors.passwordConfirm ? (
        <p id="password_confirm-error" className="field-error">
          {fieldErrors.passwordConfirm}
        </p>
      ) : null}

      <button type="submit" disabled={isPending}>
        {isPending ? t('submitting') : t('submit')}
      </button>
    </form>
  );
}
