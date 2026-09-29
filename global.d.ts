/**
 * global.d.ts
 *
 * Typisierung für next-intl: Übersetzungsschlüssel und Sprachen werden zur
 * Compile-Zeit geprüft. Referenz ist messages/de.json.
 */
import type messages from './messages/de.json';
import type { routing } from './i18n/routing';

declare module 'next-intl' {
  interface AppConfig {
    Locale: (typeof routing.locales)[number];
    Messages: typeof messages;
  }
}
