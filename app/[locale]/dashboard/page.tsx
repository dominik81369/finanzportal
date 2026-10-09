/**
 * app/[locale]/dashboard/page.tsx
 *
 * Übersicht. Hinweise (gestreamt): Einzelbudgets über der Warnschwelle –
 * Monatsbudgets im laufenden Monat, Jahresbudgets im laufenden Jahr bis
 * heute (lib/category-budgets.ts). Weitere Bereiche folgen (Platzhalter).
 */
import { getFormatter, getTranslations } from 'next-intl/server';
import { Suspense } from 'react';

import { Link } from '@/i18n/navigation';
import { budgetAlerts } from '@/lib/category-budgets';
import { requireOnboardedUser } from '@/lib/supabase/server';
import { todayInGermany } from '@/lib/transactions';

import { evaluateBudgetsFor } from './budgets/budget-data';
import { PlannedBox, placeholderMetadata } from './placeholder-section';

export const generateMetadata = placeholderMetadata('overview');

export default async function OverviewPage() {
  const user = await requireOnboardedUser('/dashboard');
  const t = await getTranslations('Dashboard');

  return (
    <section className="placeholder overview-page" aria-labelledby="page-title">
      <h1 id="page-title">{t('overview.title')}</h1>
      <p>{t('overview.description')}</p>
      <section className="overview-alerts" aria-labelledby="alerts-heading">
        <h2 id="alerts-heading">{t('overview.alerts.heading')}</h2>
        {/* Neuer Schlüssel je Server-Render, siehe action-form.tsx. */}
        <Suspense
          key={crypto.randomUUID()}
          fallback={
            <p className="hint" role="status">
              {t('overview.alerts.loading')}
            </p>
          }
        >
          <BudgetAlertLine userId={user.id} />
        </Suspense>
      </section>
      <PlannedBox section="overview" />
    </section>
  );
}

/** „X Budgets über der Schwelle“ mit Link zur Budgetliste. */
async function BudgetAlertLine({ userId }: { userId: string }) {
  const t = await getTranslations('Dashboard.overview.alerts');
  const format = await getFormatter();
  const month = todayInGermany().slice(0, 7);
  const evaluated = await evaluateBudgetsFor(userId, { from: month, to: month });
  if (!evaluated) {
    return (
      <p role="alert" className="form-error">
        {t('loadError')}
      </p>
    );
  }
  const alerts = budgetAlerts(evaluated.results);
  if (alerts.total === 0) {
    return (
      <p className="overview-alert" id="budget-alerts">
        {t('noBudgets')} <Link href="/dashboard/budgets/new">{t('create')}</Link>
      </p>
    );
  }
  const monthLabel = format.dateTime(new Date(`${month}-01T00:00:00Z`), { month: 'long', timeZone: 'UTC' });

  return (
    <>
      <p
        className={`overview-alert ${alerts.atThreshold > 0 ? 'overview-alert-warning' : ''}`}
        id="budget-alerts"
        data-count={alerts.atThreshold}
      >
        {alerts.atThreshold > 0 ? (
          <strong>
            {t('atThreshold', { count: alerts.atThreshold })}
            {alerts.over > 0 ? ` ${t('over', { count: alerts.over })}` : ''}
          </strong>
        ) : (
          t('allOk', { count: alerts.total })
        )}{' '}
        <Link href="/dashboard/budgets#category-budgets">{t('toBudgets')}</Link>
      </p>
      <p className="hint">{t('scope', { month: monthLabel, year: month.slice(0, 4) })}</p>
    </>
  );
}
