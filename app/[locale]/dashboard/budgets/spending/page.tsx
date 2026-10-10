/**
 * app/[locale]/dashboard/budgets/spending/page.tsx
 *
 * Ausgaben (Budget › Ausgaben): vorerst Platzhalter mit den geplanten
 * Inhalten; das Dashboard folgt in einem eigenen Schritt.
 */
import type { Metadata } from 'next';
import { getTranslations } from 'next-intl/server';

import { toAppLocale } from '@/i18n/routing';
import { requireOnboardedUser } from '@/lib/supabase/server';

import { PlannedBox } from '../../placeholder-section';
import { BudgetTabs } from '../budget-tabs';

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }): Promise<Metadata> {
  const t = await getTranslations({ locale: toAppLocale((await params).locale), namespace: 'Dashboard' });
  return { title: t('spending.title') };
}

export default async function SpendingPage() {
  await requireOnboardedUser('/dashboard/budgets/spending');
  const t = await getTranslations('Dashboard');

  return (
    <section className="placeholder budgets-page" aria-labelledby="page-title">
      <div className="page-header">
        <h1 id="page-title">{t('spending.title')}</h1>
        <BudgetTabs active="spending" />
      </div>
      <p>{t('spending.description')}</p>
      <PlannedBox section="spending" />
    </section>
  );
}
