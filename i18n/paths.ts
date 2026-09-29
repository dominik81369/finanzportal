/**
 * i18n/paths.ts
 *
 * Sprachbewusste Pfade für Server-Code (Guards, Server Actions, Route
 * Handler). Deutsch bleibt ohne Präfix, Englisch erhält /en.
 *
 * Konvention für `next`-Parameter: Sie enthalten immer den vollständigen,
 * bereits lokalisierten Pfad (z. B. /en/dashboard). Weiterleitungen dorthin
 * dürfen ihn daher NICHT erneut lokalisieren.
 */
import 'server-only';

import { getLocale } from 'next-intl/server';
import { redirect } from 'next/navigation';

import { getPathname } from './navigation';
import type { AppLocale } from './routing';

/** Pfad (ohne Query) mit Sprachpräfix; locale fehlt → Sprache der Anfrage. */
export async function localizedPath(pathname: string, locale?: AppLocale): Promise<string> {
  return getPathname({ href: pathname, locale: locale ?? (await getLocale()) });
}

/** Lokalisierter Pfad mit optionalem ?next=… (next bereits lokalisiert). */
export async function localizedPathWithNext(pathname: string, next?: string | null): Promise<string> {
  const path = await localizedPath(pathname);
  return next ? `${path}?next=${encodeURIComponent(next)}` : path;
}

/** redirect() auf einen Pfad in der Sprache der aktuellen Anfrage. */
export async function redirectLocalized(pathname: string, next?: string | null): Promise<never> {
  redirect(await localizedPathWithNext(pathname, next));
}
