/**
 * i18n/navigation.ts
 *
 * Sprachbewusste Varianten von Link, redirect, usePathname und useRouter.
 * In Komponenten immer diese statt der Varianten aus next/link bzw.
 * next/navigation verwenden – sonst fehlt auf englischen Seiten das /en-Präfix.
 */
import { createNavigation } from 'next-intl/navigation';

import { routing } from './routing';

export const { Link, redirect, usePathname, useRouter, getPathname } = createNavigation(routing);
