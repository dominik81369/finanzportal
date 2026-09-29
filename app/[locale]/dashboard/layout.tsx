/**
 * app/[locale]/dashboard/layout.tsx
 *
 * Rahmen des Mandanten-Dashboards: Kopfzeile, Bereichsnavigation, Inhalt.
 *
 * Zugriff: middleware.ts leitet ohne Session nach /login und ohne eigenes
 * Passwort nach /set-password. requireOnboardedUser() prüft beides hier ein
 * zweites Mal. Layouts werden bei Navigation zwischen Unterseiten nicht neu
 * gerendert – Seiten, die Daten laden, verlassen sich deshalb zusätzlich auf
 * RLS (Server-Client aus lib/supabase/server.ts), nie auf dieses Layout allein.
 */
import type { Metadata } from 'next';
import { getTranslations } from 'next-intl/server';
import type { ReactNode } from 'react';

import { toAppLocale } from '@/i18n/routing';
import { signOut } from '@/lib/actions/auth';
import { requireOnboardedUser } from '@/lib/supabase/server';

import { DashboardNav } from './dashboard-nav';

type DashboardLayoutProps = {
  children: ReactNode;
  params: Promise<{ locale: string }>;
};

export async function generateMetadata({
  params,
}: Omit<DashboardLayoutProps, 'children'>): Promise<Metadata> {
  const locale = toAppLocale((await params).locale);
  const t = await getTranslations({ locale, namespace: 'Dashboard' });
  const tMeta = await getTranslations({ locale, namespace: 'Metadata' });
  return {
    title: {
      default: t('overview.title'),
      template: tMeta('titleTemplate'),
    },
    robots: { index: false, follow: false },
  };
}

export default async function DashboardLayout({ children }: DashboardLayoutProps) {
  const user = await requireOnboardedUser('/dashboard');
  const t = await getTranslations('Dashboard');
  const tMeta = await getTranslations('Metadata');

  return (
    <div className="dashboard">
      <a className="skip-link" href="#dashboard-content">
        {t('skipLink')}
      </a>

      <header className="dashboard-header">
        <span className="dashboard-brand">{tMeta('appName')}</span>
        <div className="dashboard-account">
          <span className="dashboard-user">{user.email}</span>
          <form action={signOut}>
            <button type="submit" className="link-button">
              {t('signOut')}
            </button>
          </form>
        </div>
      </header>

      <div className="dashboard-body">
        <DashboardNav />
        <main id="dashboard-content" className="dashboard-content" tabIndex={-1}>
          {children}
        </main>
      </div>
    </div>
  );
}
