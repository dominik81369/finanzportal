/**
 * i18n/routing.ts
 *
 * Sprach-Routing (next-intl). Deutsch ist Standard und hat kein Präfix:
 * /login, /dashboard … bleiben unverändert, englische Seiten liegen unter
 * /en/login, /en/dashboard … (localePrefix 'as-needed'). Bestehende Links aus
 * E-Mails und Lesezeichen funktionieren damit weiter.
 *
 * Keine automatische Spracherkennung und kein Sprach-Cookie: Solange
 * messages/en.json nur ein grobes Gerüst ist, soll niemand allein wegen seiner
 * Browsersprache auf die englische Fassung umgeleitet werden. Die Sprache
 * ergibt sich ausschließlich aus der URL.
 */
import { defineRouting } from 'next-intl/routing';

export const routing = defineRouting({
  locales: ['de', 'en'],
  defaultLocale: 'de',
  localePrefix: 'as-needed',
  localeDetection: false,
  localeCookie: false,
});

export type AppLocale = (typeof routing.locales)[number];

/** Route-Parameter [locale] → unterstützte Sprache (sonst Standardsprache). */
export function toAppLocale(value: string): AppLocale {
  return (routing.locales as readonly string[]).includes(value)
    ? (value as AppLocale)
    : routing.defaultLocale;
}
