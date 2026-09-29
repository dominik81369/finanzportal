/**
 * app/[locale]/advisor/layout.tsx
 *
 * Rahmen des Beraterbereichs. Zugriff: middleware.ts lässt /advisor nur für
 * profiles.role = 'advisor' zu; requireAdvisor() prüft das hier ein zweites
 * Mal (inkl. eigenem Passwort). Datenzugriffe laufen zusätzlich über RLS.
 */
import type { Metadata } from 'next';
import { getTranslations } from 'next-intl/server';
import type { ReactNode } from 'react';

import { toAppLocale } from '@/i18n/routing';
import { requireAdvisor } from '@/lib/supabase/server';

import { AppHeader } from '../app-header';

type AdvisorLayoutProps = {
  children: ReactNode;
  params: Promise<{ locale: string }>;
};

export async function generateMetadata({
  params,
}: Omit<AdvisorLayoutProps, 'children'>): Promise<Metadata> {
  const locale = toAppLocale((await params).locale);
  const t = await getTranslations({ locale, namespace: 'Advisor' });
  const tMeta = await getTranslations({ locale, namespace: 'Metadata' });
  return {
    title: { default: t('metaTitle'), template: tMeta('titleTemplate') },
    robots: { index: false, follow: false },
  };
}

export default async function AdvisorLayout({ children }: AdvisorLayoutProps) {
  const advisor = await requireAdvisor();
  const t = await getTranslations('Advisor');
  const tDashboard = await getTranslations('Dashboard');

  return (
    <div className="dashboard">
      <a className="skip-link" href="#advisor-content">
        {tDashboard('skipLink')}
      </a>
      <AppHeader email={advisor.email} switchLink={{ href: '/dashboard', label: t('toOwnFinances') }} />
      <main id="advisor-content" className="dashboard-content advisor-content" tabIndex={-1}>
        {children}
      </main>
    </div>
  );
}
