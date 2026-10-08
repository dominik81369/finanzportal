/**
 * Ladezustand der Budgetauswertung (Suspense-Fallback): Platzhalter in
 * Palettenfarben (.skeleton, ohne Bewegung bei „weniger Bewegung“), Text
 * nur für Screenreader, aria-busy für den laufenden Ladevorgang.
 */
import { getTranslations } from 'next-intl/server';

export async function BudgetSkeleton() {
  const t = await getTranslations('Budgets');
  return (
    <div className="skeleton-stack" aria-busy="true" aria-live="polite">
      <p className="sr-only" role="status">
        {t('loading')}
      </p>
      <span className="skeleton skeleton-row" aria-hidden="true" />
      <span className="skeleton skeleton-card" aria-hidden="true" />
      <span className="skeleton skeleton-card" aria-hidden="true" />
    </div>
  );
}
