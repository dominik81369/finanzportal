/**
 * Leseansicht des Beraters: Budget (feste 50/30/20-Regel) eines verbundenen
 * Mandanten für den aktuellen Monat. Keine Formulare; RLS erlaubt Beratern
 * nur SELECT. Die Abfragen filtern ausdrücklich auf user_id = clientId.
 */
import { getFormatter, getTranslations } from 'next-intl/server';
import { Suspense } from 'react';

import { todayInGermany } from '@/lib/transactions';

import { BudgetOverview } from '../../../dashboard/budgets/budget-overview';
import { BudgetSkeleton } from '../../../dashboard/budgets/budget-skeleton';

export async function AdvisorBudgetSection({ clientId }: { clientId: string }) {
  const t = await getTranslations('Budgets');
  const format = await getFormatter();
  const month = todayInGermany().slice(0, 7);
  const monthLabel = format.dateTime(new Date(`${month}-01T00:00:00Z`), {
    month: 'long',
    year: 'numeric',
    timeZone: 'UTC',
  });

  return (
    <section className="advisor-section" aria-labelledby="budget-heading">
      <h2 id="budget-heading">{t('advisor.heading')}</h2>
      <p className="hint">{t('advisor.intro', { month: monthLabel })}</p>
      <Suspense fallback={<BudgetSkeleton />}>
        <BudgetOverview userId={clientId} range={{ from: month, to: month }} readOnly />
      </Suspense>
    </section>
  );
}
