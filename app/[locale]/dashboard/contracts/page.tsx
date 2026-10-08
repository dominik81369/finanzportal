/**
 * app/[locale]/dashboard/contracts/page.tsx
 *
 * Verträge: „Erkannte Verträge“ (Vorschläge mit Bestätigen/Verwerfen),
 * „Meine Verträge“ (bestätigt oder manuell angelegt) und eingeklappt die
 * verworfenen Vorschläge (Wiederherstellen). Kopf und Meldungen sofort,
 * die Daten gestreamt (contracts-overview.tsx, Ladezustand
 * contracts-skeleton.tsx).
 */
import type { Metadata } from 'next';
import { getTranslations } from 'next-intl/server';
import { Suspense } from 'react';

import { Link } from '@/i18n/navigation';
import { toAppLocale } from '@/i18n/routing';
import { refreshContracts } from '@/lib/actions/contracts';
import { requireOnboardedUser } from '@/lib/supabase/server';

import { ActionForm } from '../action-form';
import { ContractsOverview } from './contracts-overview';
import { ContractsSkeleton } from './contracts-skeleton';

type ContractsPageProps = {
  params: Promise<{ locale: string }>;
  searchParams: Promise<Record<string, string | string[] | undefined>>;
};

export async function generateMetadata({ params }: Pick<ContractsPageProps, 'params'>): Promise<Metadata> {
  const locale = toAppLocale((await params).locale);
  const t = await getTranslations({ locale, namespace: 'Contracts' });
  return { title: t('metaTitle') };
}

export default async function ContractsPage({ searchParams }: ContractsPageProps) {
  const user = await requireOnboardedUser('/dashboard/contracts');
  const query = await searchParams;
  const t = await getTranslations('Contracts');

  const param = (name: string) => (typeof query[name] === 'string' ? (query[name] as string) : null);
  const refreshedCount = param('refreshed');
  const notice = param('error')
    ? null
    : refreshedCount !== null && /^\d{1,4}$/.test(refreshedCount)
      ? t('messages.refreshed', { count: Number(refreshedCount) })
      : param('confirmed')
        ? t('messages.confirmed')
        : param('dismissed')
          ? t('messages.dismissed')
          : param('restored')
            ? t('messages.restored')
            : param('deleted')
              ? t('messages.deleted')
              : null;

  return (
    <section aria-labelledby="page-title" className="contracts-page">
      <div className="page-header">
        <h1 id="page-title">{t('heading')}</h1>
        <div className="contracts-toolbar">
          <ActionForm action={refreshContracts}>
            <button type="submit" className="button button-secondary button-small">
              {t('refresh')}
            </button>
          </ActionForm>
          <Link href="/dashboard/contracts/new" className="button button-small">
            {t('new')}
          </Link>
        </div>
      </div>
      <p className="contracts-intro">{t('intro')}</p>

      {param('error') ? (
        <p role="alert" className="form-error">
          {t('errors.generic')}
        </p>
      ) : notice ? (
        <p role="status" className="form-success">
          {notice}
        </p>
      ) : null}

      {/* Neuer Schlüssel je Server-Render: Nach einer Aktion wird die Grenze
          neu eingehängt (kurz Platzhalter), statt in der Transition auf den
          gestreamten Inhalt zu warten – das blieb sonst gelegentlich hängen. */}
      <Suspense key={crypto.randomUUID()} fallback={<ContractsSkeleton variant="list" />}>
        <ContractsOverview userId={user.id} />
      </Suspense>
    </section>
  );
}
