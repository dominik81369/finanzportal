/**
 * Ladezustand des Ausgaben-Dashboards (Suspense-Fallback): Platzhalter in
 * Palettenfarben, Text nur für Screenreader, aria-busy.
 */
import { getTranslations } from 'next-intl/server';

export async function SpendingSkeleton() {
  const t = await getTranslations('Spending');
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
