/**
 * lib/transactions.ts
 *
 * Eingabeprüfung für Buchungen. Reine Funktionen ohne Server-Abhängigkeiten.
 * Die Grenzen spiegeln transactions (numeric(14,2), counterparty_name ≤ 200,
 * purpose ≤ 1000), tags (name 1–50) und create_manual_transaction().
 *
 * Anzeigeformate (Beträge, Datum) kommen aus next-intl (useFormatter /
 * getFormatter), damit sie der Sprache der Seite folgen.
 */
import type { AppLocale } from '@/i18n/routing';

export const COUNTERPARTY_MAX_LENGTH = 200;
export const PURPOSE_MAX_LENGTH = 1000;
export const TAG_NAME_MAX_LENGTH = 50;
export const NEW_TAGS_MAX = 10;
export const TAGS_PER_TRANSACTION_MAX = 20;

/** numeric(14,2): höchstens 12 Vorkommastellen. */
const AMOUNT_MAX = 999_999_999_999.99;

/**
 * Zulässige Schreibweisen je Sprache. Tausendertrennzeichen sind optional,
 * höchstens zwei Nachkommastellen. Deutsch akzeptiert zusätzlich den
 * Dezimalpunkt ohne Tausendertrennung ("12.50"), weil viele ihn gewohnt sind.
 */
const AMOUNT_FORMATS: Record<AppLocale, { pattern: RegExp; group: string; decimal: string }[]> = {
  de: [
    { pattern: /^\d{1,3}(\.\d{3})+(,\d{1,2})?$/, group: '.', decimal: ',' },
    { pattern: /^\d+(,\d{1,2})?$/, group: '', decimal: ',' },
    { pattern: /^\d+\.\d{1,2}$/, group: '', decimal: '.' },
  ],
  en: [
    { pattern: /^\d{1,3}(,\d{3})+(\.\d{1,2})?$/, group: ',', decimal: '.' },
    { pattern: /^\d+(\.\d{1,2})?$/, group: '', decimal: '.' },
  ],
};

/**
 * Positiver Betrag aus einer Benutzereingabe oder null.
 * Das Vorzeichen ergibt sich aus der Buchungsart, nicht aus der Eingabe.
 */
export function parseAmountInput(input: string, locale: AppLocale): number | null {
  const value = input.replace(/[\s €]/g, '');
  const format = AMOUNT_FORMATS[locale].find(({ pattern }) => pattern.test(value));
  if (!format) {
    return null;
  }

  const normalized = (format.group ? value.split(format.group).join('') : value).replace(
    format.decimal,
    '.',
  );
  const amount = Number(normalized);
  if (!Number.isFinite(amount) || amount <= 0 || amount > AMOUNT_MAX) {
    return null;
  }
  return amount;
}

/**
 * Betrag als Eingabetext in der Schreibweise der Sprache, ohne
 * Tausendertrennzeichen (de: "1500,00", en: "1500.00") – zum Vorbelegen beim
 * Bearbeiten; parseAmountInput() liest ihn wieder ein.
 */
export function formatAmountInput(amount: number, locale: AppLocale): string {
  return new Intl.NumberFormat(locale, {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
    useGrouping: false,
  }).format(Math.abs(amount));
}

/** ISO-Datum (YYYY-MM-DD), das es im Kalender gibt, sonst null. */
export function parseIsoDate(input: string): string | null {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(input);
  if (!match) {
    return null;
  }
  const [year, month, day] = [Number(match[1]), Number(match[2]), Number(match[3])];
  const date = new Date(Date.UTC(year, month - 1, day));
  if (
    year < 1900 ||
    date.getUTCFullYear() !== year ||
    date.getUTCMonth() !== month - 1 ||
    date.getUTCDate() !== day
  ) {
    return null;
  }
  return input;
}

/** Heutiges Datum in Deutschland als YYYY-MM-DD (Server laufen in UTC). */
export function todayInGermany(now: Date = new Date()): string {
  return new Intl.DateTimeFormat('en-CA', { timeZone: 'Europe/Berlin' }).format(now);
}

/**
 * Neue Tag-Namen aus kommagetrennter Eingabe: getrimmt, Leerraum
 * zusammengefasst, ohne Duplikate (Groß-/Kleinschreibung egal – wie der
 * Unique-Index tags_user_name_key).
 */
export function parseTagNames(input: string): string[] {
  const seen = new Set<string>();
  const names: string[] = [];
  for (const raw of input.split(',')) {
    const name = raw.trim().replace(/\s+/g, ' ');
    const key = name.toLowerCase();
    if (name.length > 0 && !seen.has(key)) {
      seen.add(key);
      names.push(name);
    }
  }
  return names;
}

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function isUuid(value: string): boolean {
  return UUID_PATTERN.test(value);
}
