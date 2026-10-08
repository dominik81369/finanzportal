/**
 * app/[locale]/dashboard/contracts/new/page.tsx
 *
 * Vertrag manuell anlegen. Mit Gegenpartei werden passende Abbuchungen
 * (gleiche Gegenpartei, Betrag innerhalb der Toleranz, alle Konten)
 * automatisch verknüpft.
 */
import type { Metadata } from 'next';
import { getTranslations } from 'next-intl/server';
import { Suspense } from 'react';

import { Link } from '@/i18n/navigation';
import { toAppLocale } from '@/i18n/routing';
import { saveContract } from '@/lib/actions/contracts';
import { requireOnboardedUser } from '@/lib/supabase/server';

import { ContractForm } from '../contract-form';
import { ContractsSkeleton } from '../contracts-skeleton';
import { loadContractFormData } from '../form-data';

type NewContractPageProps = { params: Promise<{ locale: string }> };

export async function generateMetadata({ params }: NewContractPageProps): Promise<Metadata> {
  const locale = toAppLocale((await params).locale);
  const t = await getTranslations({ locale, namespace: 'Contracts.form' });
  return { title: t('newTitle') };
}

export default async function NewContractPage() {
  const user = await requireOnboardedUser('/dashboard/contracts/new');
  const t = await getTranslations('Contracts');

  return (
    <section aria-labelledby="page-title" className="contracts-page">
      <p className="back-link">
        <Link href="/dashboard/contracts">← {t('back')}</Link>
      </p>
      <h1 id="page-title">{t('form.newTitle')}</h1>
      <p className="contracts-intro">{t('form.newIntro')}</p>
      <Suspense fallback={<ContractsSkeleton variant="form" />}>
        <NewContractForm userId={user.id} />
      </Suspense>
    </section>
  );
}

/** Formular mit Auswahllisten (gestreamt). */
async function NewContractForm({ userId }: { userId: string }) {
  const t = await getTranslations('Contracts');
  const data = await loadContractFormData(userId);
  if (!data) {
    return (
      <p role="alert" className="form-error">
        {t('errors.loadError')}
      </p>
    );
  }
  return (
    <ContractForm
      mode="create"
      action={saveContract.bind(null, null)}
      counterparties={data.counterparties}
      accounts={data.accounts}
      categories={data.categories}
    />
  );
}
