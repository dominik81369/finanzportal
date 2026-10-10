/**
 * app/[locale]/dashboard/page.tsx
 *
 * Übersicht: Kachel „Ausgaben diesen Monat“ (gestreamt, spending-tile.tsx);
 * weitere Bereiche folgen (Platzhalter).
 */
import { getTranslations } from 'next-intl/server';
import { Suspense } from 'react';

import { requireOnboardedUser } from '@/lib/supabase/server';

import { PlannedBox, placeholderMetadata } from './placeholder-section';
import { SpendingTile } from './spending-tile';

export const generateMetadata = placeholderMetadata('overview');

export default async function OverviewPage() {
  const user = await requireOnboardedUser('/dashboard');
  const t = await getTranslations('Dashboard');
  const tSpending = await getTranslations('Spending');

  return (
    <section className="placeholder overview-page" aria-labelledby="page-title">
      <h1 id="page-title">{t('overview.title')}</h1>
      <p>{t('overview.description')}</p>
      {/* Neuer Schlüssel je Server-Render, siehe action-form.tsx. */}
      <Suspense
        key={crypto.randomUUID()}
        fallback={
          <p className="hint" role="status">
            {tSpending('tile.loading')}
          </p>
        }
      >
        <SpendingTile userId={user.id} />
      </Suspense>
      <PlannedBox section="overview" />
    </section>
  );
}
