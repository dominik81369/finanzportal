'use server';

/**
 * lib/actions/auth.ts
 *
 * Server Actions für Anmeldung, Registrierung und Abmeldung (E-Mail/Passwort).
 *
 * Der Server-Client aus lib/supabase/server.ts nutzt den PKCE-Flow
 * (Standard von @supabase/ssr): Bei signUp() wird der code_verifier als Cookie
 * im Browser abgelegt; der Bestätigungslink liefert ?code=… an
 * app/[locale]/auth/callback, wo exchangeCodeForSession() ihn gegen eine Session tauscht.
 *
 * Fehlertexte verraten bewusst nicht, ob eine E-Mail-Adresse registriert ist.
 */
import type { AuthError } from '@supabase/supabase-js';
import { revalidatePath } from 'next/cache';
import { headers } from 'next/headers';
import { redirect } from 'next/navigation';
import { getTranslations } from 'next-intl/server';

import { localizedPath, localizedPathWithNext } from '@/i18n/paths';
import { createClient } from '@/lib/supabase/server';
import { DEFAULT_REDIRECT_PATH, getAppOrigin, parseRedirectPath, safeRedirectPath } from '@/lib/url';
import {
  NAME_MAX_LENGTH,
  PASSWORD_MIN_LENGTH,
  parseEmail,
  readString,
  readTrimmed,
  validateNewPassword,
} from '@/lib/validation';

const ADVISOR_HOME_PATH = '/advisor';

export type AuthField = 'email' | 'password' | 'firstName' | 'lastName';

export type AuthFormState = {
  status: 'idle' | 'error' | 'success';
  message?: string;
  fieldErrors?: Partial<Record<AuthField, string>>;
  /** Zum Vorbelegen des Formulars nach einem Fehler – niemals das Passwort. */
  values?: { email?: string; firstName?: string; lastName?: string };
};

async function authErrorMessage(error: AuthError): Promise<string> {
  const t = await getTranslations('AuthErrors');
  const tValidation = await getTranslations('Validation');

  switch (error.code) {
    case 'invalid_credentials':
      return t('invalidCredentials');
    case 'email_not_confirmed':
      return t('emailNotConfirmed');
    case 'user_already_exists':
    case 'email_exists':
      return t('emailExists');
    case 'weak_password':
      return tValidation('passwordWeak');
    case 'email_address_invalid':
      return tValidation('emailInvalid');
    case 'signup_disabled':
      return t('signupDisabled');
    case 'user_banned':
      return t('userBanned');
    case 'over_request_rate_limit':
    case 'over_email_send_rate_limit':
      return t('rateLimited');
  }

  if (error.status === 429) {
    return t('rateLimited');
  }

  // Nur Code/Status loggen – keine personenbezogenen Daten.
  console.error('[auth] Unerwarteter Fehler', { code: error.code, status: error.status });
  return t('generic');
}

export async function signIn(_prevState: AuthFormState, formData: FormData): Promise<AuthFormState> {
  const rawEmail = readTrimmed(formData, 'email');
  const password = readString(formData, 'password');
  const email = parseEmail(rawEmail);
  const values = { email: rawEmail };

  if (!email || password.length === 0) {
    const t = await getTranslations('AuthErrors');
    return { status: 'error', message: t('missingCredentials'), values };
  }

  const supabase = await createClient();
  const { data, error } = await supabase.auth.signInWithPassword({ email, password });

  if (error) {
    return { status: 'error', message: await authErrorMessage(error), values };
  }

  // Ohne explizites Ziel ins passende Cockpit – wie middleware.ts bei /login.
  const { data: profile } = await supabase
    .from('profiles')
    .select('role')
    .eq('user_id', data.user.id)
    .maybeSingle();
  const home = await localizedPath(
    profile?.role === 'advisor' ? ADVISOR_HOME_PATH : DEFAULT_REDIRECT_PATH,
  );

  revalidatePath('/', 'layout');
  // `next` ist bereits lokalisiert (siehe i18n/paths.ts).
  redirect(safeRedirectPath(formData.get('next'), home));
}

export async function signUp(_prevState: AuthFormState, formData: FormData): Promise<AuthFormState> {
  const firstName = readTrimmed(formData, 'first_name');
  const lastName = readTrimmed(formData, 'last_name');
  const rawEmail = readTrimmed(formData, 'email');
  const password = readString(formData, 'password');
  const values = { email: rawEmail, firstName, lastName };

  const tValidation = await getTranslations('Validation');
  const fieldErrors: NonNullable<AuthFormState['fieldErrors']> = {};
  if (firstName.length > NAME_MAX_LENGTH) {
    fieldErrors.firstName = tValidation('maxLength', { max: NAME_MAX_LENGTH });
  }
  if (lastName.length > NAME_MAX_LENGTH) {
    fieldErrors.lastName = tValidation('maxLength', { max: NAME_MAX_LENGTH });
  }
  const email = parseEmail(rawEmail);
  if (!email) {
    fieldErrors.email = tValidation('emailInvalid');
  }
  const passwordIssue = validateNewPassword(password);
  if (passwordIssue) {
    fieldErrors.password = tValidation(passwordIssue, { min: PASSWORD_MIN_LENGTH });
  }

  if (!email || Object.keys(fieldErrors).length > 0) {
    return { status: 'error', message: tValidation('checkInput'), fieldErrors, values };
  }

  const next = safeRedirectPath(formData.get('next'), await localizedPath(DEFAULT_REDIRECT_PATH));
  const origin = getAppOrigin(await headers());
  // Der Bestätigungslink führt über den Callback der aktuellen Sprache.
  const callbackPath = await localizedPath('/auth/callback');

  const supabase = await createClient();
  const { data, error } = await supabase.auth.signUp({
    email,
    password,
    options: {
      emailRedirectTo: `${origin}${callbackPath}?next=${encodeURIComponent(next)}`,
      // private.handle_new_user() übernimmt Vor- und Nachname nach profiles.
      // Die Rolle wird dort bewusst NICHT aus den Metadaten gelesen.
      data: { first_name: firstName, last_name: lastName },
    },
  });

  if (error) {
    return { status: 'error', message: await authErrorMessage(error), values };
  }

  // E-Mail-Bestätigung deaktiviert (lokale Entwicklung): Session besteht bereits.
  if (data.session) {
    revalidatePath('/', 'layout');
    redirect(next);
  }

  // Identische Antwort auch für bereits registrierte Adressen (Supabase liefert
  // dann einen verschleierten Nutzer ohne Session) – keine Konto-Enumeration.
  const t = await getTranslations('Signup');
  return { status: 'success', message: t('success', { email }), values: { email } };
}

export async function signOut(formData: FormData): Promise<void> {
  const supabase = await createClient();
  // Nur diese Sitzung beenden; andere Geräte bleiben angemeldet.
  await supabase.auth.signOut({ scope: 'local' });

  revalidatePath('/', 'layout');
  redirect(await localizedPathWithNext('/login', parseRedirectPath(formData.get('next'))));
}
