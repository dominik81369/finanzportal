/**
 * app/[locale]/dashboard/budgets/spending/page.tsx
 *
 * Ausgaben (Budget › Ausgaben): reine Ist-Darstellung für Woche, Monat,
 * Quartal, Jahr oder einen frei gewählten Zeitraum, mit Vergleich zur
 * Vorperiode (laufende Periode bis heute). Zeitraum und Währung stehen in
 * der URL (lib/spending-period.ts, ?currency=). Kopf und Zeitraum sofort,
 * die Auswertung gestreamt (spending-overview.tsx); die Suspense-Grenze
 * trägt je Render einen neuen Schlüssel (siehe ../../action-form.tsx).
 */
import type { Metadata } from 'next';
import { getTranslations } from 'next-intl/server';
import { Suspense } from 'react';

import { toAppLocale } from '@/i18n/routing';
import { parseSpendingPeriod } from '@/lib/spending-period';
import { requireOnboardedUser } from '@/lib/supabase/server';
import { todayInGermany } from '@/lib/transactions';

import { BudgetTabs } from '../budget-tabs';
import { SpendingControls } from './spending-controls';
import { SpendingOverview } from './spending-overview';
import { SpendingSkeleton } from './spending-skeleton';

type SpendingPageProps = {
  params: Promise<{ locale: string }>;
  searchParams: Promise<Record<string, string | string[] | undefined>>;
};

export async function generateMetadata({ params }: Pick<SpendingPageProps, 'params'>): Promise<Metadata> {
  const t = await getTranslations({ locale: toAppLocale((await params).locale), namespace: 'Dashboard' });
  return { title: t('spending.title') };
}

export default async function SpendingPage({ searchParams }: SpendingPageProps) {
  const user = await requireOnboardedUser('/dashboard/budgets/spending');
  const t = await getTranslations('Dashboard');
  const query = await searchParams;
  const today = todayInGermany();
  const period = parseSpendingPeriod(query, today);
  const currency = typeof query.currency === 'string' && /^[A-Z]{3}$/.test(query.currency) ? query.currency : null;

  return (
    <section className="budgets-page spending-page" aria-labelledby="page-title">
      <div className="page-header">
        <h1 id="page-title">{t('spending.title')}</h1>
        <BudgetTabs active="spending" />
      </div>
      <p className="budgets-intro">{t('spending.description')}</p>
      <SpendingControls period={period} today={today} currency={currency} />
      <Suspense key={crypto.randomUUID()} fallback={<SpendingSkeleton />}>
        <SpendingOverview userId={user.id} period={period} currency={currency} />
      </Suspense>
    </section>
  );
}
