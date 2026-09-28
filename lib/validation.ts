/**
 * lib/validation.ts
 *
 * Eingabeprüfung für Server Actions. FormData ist unvertrauenswürdig: Werte
 * können fehlen, Dateien statt Strings sein oder beliebig lang werden.
 * Die Regeln spiegeln die CHECK-Constraints aus supabase/migrations/.
 */

/** Wie advisor_clients.invited_email: max. 320 Zeichen, Form x@y.z */
const EMAIL_PATTERN = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;
const EMAIL_MAX_LENGTH = 320;

/** Wie profiles.first_name / last_name */
export const NAME_MAX_LENGTH = 100;

export const PASSWORD_MIN_LENGTH = 12;
/** bcrypt (Supabase Auth) verarbeitet maximal 72 Byte. */
export const PASSWORD_MAX_BYTES = 72;

/** String-Feld aus FormData, ohne Trimmen (Passwörter). */
export function readString(formData: FormData, name: string): string {
  const value = formData.get(name);
  return typeof value === 'string' ? value : '';
}

/** String-Feld aus FormData, getrimmt. */
export function readTrimmed(formData: FormData, name: string): string {
  return readString(formData, name).trim();
}

/** Normalisierte E-Mail-Adresse (getrimmt, kleingeschrieben) oder null. */
export function parseEmail(value: unknown): string | null {
  if (typeof value !== 'string') {
    return null;
  }
  const email = value.trim().toLowerCase();
  if (email.length === 0 || email.length > EMAIL_MAX_LENGTH || !EMAIL_PATTERN.test(email)) {
    return null;
  }
  return email;
}

/** Fehlermeldung für ein neues Passwort oder null, wenn es zulässig ist. */
export function validateNewPassword(password: string): string | null {
  if (password.length < PASSWORD_MIN_LENGTH) {
    return `Das Passwort muss mindestens ${PASSWORD_MIN_LENGTH} Zeichen lang sein.`;
  }
  if (new TextEncoder().encode(password).length > PASSWORD_MAX_BYTES) {
    return 'Das Passwort ist zu lang (maximal 72 Byte).';
  }
  return null;
}
