/**
 * i18n/request.ts
 *
 * Lädt pro Request die Übersetzungen der aktiven Sprache (Server Components,
 * Server Actions, Route Handler). Die Sprache setzt middleware.ts.
 */
import { hasLocale } from 'next-intl';
import { getRequestConfig } from 'next-intl/server';

import { routing } from './routing';

export default getRequestConfig(async ({ requestLocale }) => {
  const requested = await requestLocale;
  const locale = hasLocale(routing.locales, requested) ? requested : routing.defaultLocale;

  return {
    locale,
    messages: (await import(`../messages/${locale}.json`)).default,
    timeZone: 'Europe/Berlin',
  };
});
