'use server';

/**
 * lib/actions/set-password.ts
 *
 * Erstes Passwort für Konten, die per Berater-Einladung angelegt wurden
 * (auth.admin.inviteUserByEmail legt Konten ohne Passwort an).
 *
 * Bewusst KEINE allgemeine Passwortänderung: Hat das Konto bereits ein
 * Passwort, wird nur weitergeleitet. Sonst könnte eine übernommene Session
 * das Passwort ohne Kenntnis des alten ändern und das Konto kapern.
 */
import type { AuthError } from '@supabase/supabase-js';
import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import { getTranslations } from 'next-intl/server';

import { localizedPath } from '@/i18n/paths';
import { createClient, currentUserHasPassword, requireUser } from '@/lib/supabase/server';
import { DEFAULT_REDIRECT_PATH, safeRedirectPath } from '@/lib/url';
import { PASSWORD_MIN_LENGTH, readString, validateNewPassword } from '@/lib/validation';

export type SetPasswordState = {
  status: 'idle' | 'error';
  message?: string;
  fieldErrors?: { password?: string; passwordConfirm?: string };
};

async function updateErrorMessage(error: AuthError): Promise<string> {
  const t = await getTranslations('SetPassword.errors');
  switch (error.code) {
    case 'weak_password':
      return (await getTranslations('Validation'))('passwordWeak');
    case 'reauthentication_needed':
      return t('reauthenticationNeeded');
  }
  console.error('[set-password] updateUser fehlgeschlagen', { code: error.code, status: error.status });
  return t('generic');
}

export async function setPassword(
  _prevState: SetPasswordState,
  formData: FormData,
): Promise<SetPasswordState> {
  await requireUser();
  const t = await getTranslations('SetPassword.errors');
  const next = safeRedirectPath(formData.get('next'), await localizedPath(DEFAULT_REDIRECT_PATH));

  const hasPassword = await currentUserHasPassword();
  if (hasPassword === null) {
    return { status: 'error', message: t('generic') };
  }
  if (hasPassword) {
    redirect(next);
  }

  const password = readString(formData, 'password');
  const passwordConfirm = readString(formData, 'password_confirm');

  const passwordIssue = validateNewPassword(password);
  if (passwordIssue) {
    const tValidation = await getTranslations('Validation');
    return {
      status: 'error',
      fieldErrors: { password: tValidation(passwordIssue, { min: PASSWORD_MIN_LENGTH }) },
    };
  }
  if (password !== passwordConfirm) {
    return { status: 'error', fieldErrors: { passwordConfirm: t('mismatch') } };
  }

  const supabase = await createClient();
  const { error } = await supabase.auth.updateUser({ password });
  if (error) {
    return { status: 'error', message: await updateErrorMessage(error) };
  }

  revalidatePath('/', 'layout');
  redirect(next);
}
