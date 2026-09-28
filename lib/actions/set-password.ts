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

import { createClient, currentUserHasPassword, requireUser } from '@/lib/supabase/server';
import { safeRedirectPath } from '@/lib/url';
import { readString, validateNewPassword } from '@/lib/validation';

export type SetPasswordState = {
  status: 'idle' | 'error';
  message?: string;
  fieldErrors?: { password?: string; passwordConfirm?: string };
};

const GENERIC_ERROR = 'Das Passwort konnte nicht gespeichert werden. Bitte versuchen Sie es erneut.';

function updateErrorMessage(error: AuthError): string {
  switch (error.code) {
    case 'weak_password':
      return 'Das Passwort ist zu schwach. Bitte wählen Sie ein längeres Passwort ohne gängige Wörter.';
    case 'reauthentication_needed':
      return 'Aus Sicherheitsgründen ist eine erneute Anmeldung nötig. Bitte öffnen Sie den Einladungslink erneut.';
  }
  console.error('[set-password] updateUser fehlgeschlagen', { code: error.code, status: error.status });
  return GENERIC_ERROR;
}

export async function setPassword(
  _prevState: SetPasswordState,
  formData: FormData,
): Promise<SetPasswordState> {
  await requireUser();
  const next = safeRedirectPath(formData.get('next'));

  const hasPassword = await currentUserHasPassword();
  if (hasPassword === null) {
    return { status: 'error', message: GENERIC_ERROR };
  }
  if (hasPassword) {
    redirect(next);
  }

  const password = readString(formData, 'password');
  const passwordConfirm = readString(formData, 'password_confirm');

  const passwordError = validateNewPassword(password);
  if (passwordError) {
    return { status: 'error', fieldErrors: { password: passwordError } };
  }
  if (password !== passwordConfirm) {
    return { status: 'error', fieldErrors: { passwordConfirm: 'Die Passwörter stimmen nicht überein.' } };
  }

  const supabase = await createClient();
  const { error } = await supabase.auth.updateUser({ password });
  if (error) {
    return { status: 'error', message: updateErrorMessage(error) };
  }

  revalidatePath('/', 'layout');
  redirect(next);
}
