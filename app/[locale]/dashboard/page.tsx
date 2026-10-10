/**
 * app/[locale]/dashboard/page.tsx
 *
 * Übersicht. Weitere Bereiche folgen (Platzhalter).
 */
import { getTranslations } from 'next-intl/server';

import { requireOnboardedUser } from '@/lib/supabase/server';

import { PlannedBox, placeholderMetadata } from './placeholder-section';

export const generateMetadata = placeholderMetadata('overview');

export default async function OverviewPage() {
  await requireOnboardedUser('/dashboard');
  const t = await getTranslations('Dashboard');

  return (
    <section className="placeholder overview-page" aria-labelledby="page-title">
      <h1 id="page-title">{t('overview.title')}</h1>
      <p>{t('overview.description')}</p>
      <PlannedBox section="overview" />
    </section>
  );
}
