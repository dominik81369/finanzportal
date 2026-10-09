/**
 * Leseansicht des Beraters: Budget (50/30/20) eines verbundenen Mandanten
 * für den aktuellen Monat – mit Bezugsgröße und Prozentzielen, wie der
 * Mandant sie eingestellt hat. Keine Formulare; RLS erlaubt Beratern nur
 * SELECT. Abfragen filtern ausdrücklich auf user_id = clientId.
 */
import { getFormatter, getTranslations } from 'next-intl/server';
import { Suspense } from 'react';

import { toBudgetSettings } from '@/lib/budget-settings';
import { createClient } from '@/lib/supabase/server';
import { todayInGermany } from '@/lib/transactions';

import { basisExplanation } from '../../../dashboard/budgets/basis-explanation';
import { BudgetOverview } from '../../../dashboard/budgets/budget-overview';
import { BudgetSkeleton } from '../../../dashboard/budgets/budget-skeleton';

export async function AdvisorBudgetSection({ clientId }: { clientId: string }) {
  const t = await getTranslations('Budgets');
  const format = await getFormatter();
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('budget_settings')
    .select('basis, needs_pct, wants_pct, savings_pct, fixed_amount, fixed_currency')
    .eq('user_id', clientId)
    .maybeSingle();
  if (error) {
    console.error('[advisor] Budget-Einstellungen nicht ladbar', { code: error.code });
  }
  const settings = toBudgetSettings(data);
  const month = todayInGermany().slice(0, 7);
  const monthLabel = format.dateTime(new Date(`${month}-01T00:00:00Z`), {
    month: 'long',
    year: 'numeric',
    timeZone: 'UTC',
  });

  return (
    <section className="advisor-section" aria-labelledby="budget-heading">
      <h2 id="budget-heading">{t('advisor.heading')}</h2>
      <p className="hint">
        {t('advisor.intro', { month: monthLabel })} {await basisExplanation(settings.basis, 1, settings)}
      </p>
      {error ? (
        <p role="alert" className="form-error">
          {t('loadError')}
        </p>
      ) : (
        <Suspense fallback={<BudgetSkeleton />}>
          <BudgetOverview
            userId={clientId}
            range={{ from: month, to: month }}
            basis={settings.basis}
            settings={settings}
            readOnly
          />
        </Suspense>
      )}
    </section>
  );
}
