/**
 * Leseansicht des Beraters: Ausgaben-Dashboard eines verbundenen Mandanten
 * für den laufenden Monat bis heute (Vergleich: gleiche Tage des
 * Vormonats), alle Währungen untereinander. Keine Links auf Seiten des
 * Mandanten; RLS erlaubt Beratern nur SELECT, die Abfragen filtern
 * ausdrücklich auf user_id = clientId.
 */
import { getFormatter, getTranslations } from 'next-intl/server';
import { Suspense } from 'react';

import { parseSpendingPeriod } from '@/lib/spending-period';
import { todayInGermany } from '@/lib/transactions';

import { SpendingOverview } from '../../../dashboard/budgets/spending/spending-overview';
import { SpendingSkeleton } from '../../../dashboard/budgets/spending/spending-skeleton';

export async function AdvisorSpendingSection({ clientId }: { clientId: string }) {
  const t = await getTranslations('Spending.advisor');
  const format = await getFormatter();
  const period = parseSpendingPeriod({}, todayInGermany());
  const month = format.dateTime(new Date(`${period.range.from}T00:00:00Z`), {
    month: 'long',
    year: 'numeric',
    timeZone: 'UTC',
  });

  return (
    <section className="advisor-section" aria-labelledby="spending-heading">
      <h2 id="spending-heading">{t('heading')}</h2>
      <p className="hint">{t('intro', { month })}</p>
      <Suspense fallback={<SpendingSkeleton />}>
        <SpendingOverview userId={clientId} period={period} currency={null} readOnly />
      </Suspense>
    </section>
  );
}
