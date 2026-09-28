'use server';

/**
 * lib/actions/auth.ts
 *
 * Server Actions für Anmeldung, Registrierung und Abmeldung (E-Mail/Passwort).
 *
 * Der Server-Client aus lib/supabase/server.ts nutzt den PKCE-Flow
 * (Standard von @supabase/ssr): Bei signUp() wird der code_verifier als Cookie
 * im Browser abgelegt; der Bestätigungslink liefert ?code=… an
 * app/auth/callback, wo exchangeCodeForSession() ihn gegen eine Session tauscht.
 *
 * Fehlertexte verraten bewusst nicht, ob eine E-Mail-Adresse registriert ist.
 */
import type { AuthError } from '@supabase/supabase-js';
import { revalidatePath } from 'next/cache';
import { headers } from 'next/headers';
import { redirect } from 'next/navigation';

import { createClient } from '@/lib/supabase/server';
import { DEFAULT_REDIRECT_PATH, getAppOrigin, parseRedirectPath, safeRedirectPath } from '@/lib/url';
import {
  NAME_MAX_LENGTH,
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

function authErrorMessage(error: AuthError): string {
  switch (error.code) {
    case 'invalid_credentials':
      return 'E-Mail-Adresse oder Passwort ist falsch.';
    case 'email_not_confirmed':
      return 'Bitte bestätigen Sie zuerst Ihre E-Mail-Adresse über den Link in unserer E-Mail.';
    case 'user_already_exists':
    case 'email_exists':
      return 'Mit dieser E-Mail-Adresse ist keine Registrierung möglich. Falls Sie bereits ein Konto haben, melden Sie sich bitte an.';
    case 'weak_password':
      return 'Das Passwort ist zu schwach. Bitte wählen Sie ein längeres Passwort ohne gängige Wörter.';
    case 'email_address_invalid':
      return 'Bitte geben Sie eine gültige E-Mail-Adresse ein.';
    case 'signup_disabled':
      return 'Registrierungen sind derzeit nicht möglich.';
    case 'user_banned':
      return 'Dieses Konto ist gesperrt. Bitte wenden Sie sich an den Support.';
    case 'over_request_rate_limit':
    case 'over_email_send_rate_limit':
      return 'Zu viele Versuche. Bitte warten Sie einige Minuten und versuchen Sie es erneut.';
  }

  if (error.status === 429) {
    return 'Zu viele Versuche. Bitte warten Sie einige Minuten und versuchen Sie es erneut.';
  }

  // Nur Code/Status loggen – keine personenbezogenen Daten.
  console.error('[auth] Unerwarteter Fehler', { code: error.code, status: error.status });
  return 'Das hat leider nicht geklappt. Bitte versuchen Sie es später erneut.';
}

export async function signIn(_prevState: AuthFormState, formData: FormData): Promise<AuthFormState> {
  const rawEmail = readTrimmed(formData, 'email');
  const password = readString(formData, 'password');
  const email = parseEmail(rawEmail);
  const values = { email: rawEmail };

  if (!email || password.length === 0) {
    return {
      status: 'error',
      message: 'Bitte geben Sie Ihre E-Mail-Adresse und Ihr Passwort ein.',
      values,
    };
  }

  const supabase = await createClient();
  const { data, error } = await supabase.auth.signInWithPassword({ email, password });

  if (error) {
    return { status: 'error', message: authErrorMessage(error), values };
  }

  // Ohne explizites Ziel ins passende Cockpit – wie middleware.ts bei /login.
  const { data: profile } = await supabase
    .from('profiles')
    .select('role')
    .eq('user_id', data.user.id)
    .maybeSingle();
  const home = profile?.role === 'advisor' ? ADVISOR_HOME_PATH : DEFAULT_REDIRECT_PATH;

  revalidatePath('/', 'layout');
  redirect(safeRedirectPath(formData.get('next'), home));
}

export async function signUp(_prevState: AuthFormState, formData: FormData): Promise<AuthFormState> {
  const firstName = readTrimmed(formData, 'first_name');
  const lastName = readTrimmed(formData, 'last_name');
  const rawEmail = readTrimmed(formData, 'email');
  const password = readString(formData, 'password');
  const values = { email: rawEmail, firstName, lastName };

  const fieldErrors: NonNullable<AuthFormState['fieldErrors']> = {};
  if (firstName.length > NAME_MAX_LENGTH) {
    fieldErrors.firstName = `Maximal ${NAME_MAX_LENGTH} Zeichen.`;
  }
  if (lastName.length > NAME_MAX_LENGTH) {
    fieldErrors.lastName = `Maximal ${NAME_MAX_LENGTH} Zeichen.`;
  }
  const email = parseEmail(rawEmail);
  if (!email) {
    fieldErrors.email = 'Bitte geben Sie eine gültige E-Mail-Adresse ein.';
  }
  const passwordError = validateNewPassword(password);
  if (passwordError) {
    fieldErrors.password = passwordError;
  }

  if (!email || Object.keys(fieldErrors).length > 0) {
    return { status: 'error', message: 'Bitte prüfen Sie Ihre Eingaben.', fieldErrors, values };
  }

  const next = safeRedirectPath(formData.get('next'));
  const origin = getAppOrigin(await headers());

  const supabase = await createClient();
  const { data, error } = await supabase.auth.signUp({
    email,
    password,
    options: {
      emailRedirectTo: `${origin}/auth/callback?next=${encodeURIComponent(next)}`,
      // private.handle_new_user() übernimmt Vor- und Nachname nach profiles.
      // Die Rolle wird dort bewusst NICHT aus den Metadaten gelesen.
      data: { first_name: firstName, last_name: lastName },
    },
  });

  if (error) {
    return { status: 'error', message: authErrorMessage(error), values };
  }

  // E-Mail-Bestätigung deaktiviert (lokale Entwicklung): Session besteht bereits.
  if (data.session) {
    revalidatePath('/', 'layout');
    redirect(next);
  }

  // Identische Antwort auch für bereits registrierte Adressen (Supabase liefert
  // dann einen verschleierten Nutzer ohne Session) – keine Konto-Enumeration.
  return {
    status: 'success',
    message: `Fast geschafft! Wir haben Ihnen eine E-Mail an ${email} gesendet. Bitte öffnen Sie den Bestätigungslink in diesem Browser, um die Registrierung abzuschließen.`,
    values: { email },
  };
}

export async function signOut(formData: FormData): Promise<void> {
  const supabase = await createClient();
  // Nur diese Sitzung beenden; andere Geräte bleiben angemeldet.
  await supabase.auth.signOut({ scope: 'local' });

  revalidatePath('/', 'layout');
  const next = parseRedirectPath(formData.get('next'));
  redirect(next ? `/login?next=${encodeURIComponent(next)}` : '/login');
}
