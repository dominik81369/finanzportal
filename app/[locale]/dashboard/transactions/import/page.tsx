/**
 * app/[locale]/dashboard/transactions/import/page.tsx
 *
 * Kontoauszug (CSV/Excel) importieren. Die Datei wird im Browser gelesen
 * (./import-wizard.tsx, lib/import/); importiert wird über
 * lib/actions/import-transactions.ts. Zielkonto: eigenes manuelles oder
 * CSV-Konto – synchronisierte Konten liefert die Bank.
 */
import type { Metadata } from 'next';
import { getTranslations } from 'next-intl/server';

import { Link } from '@/i18n/navigation';
import { toAppLocale } from '@/i18n/routing';
import { SUPPORTED_CURRENCIES } from '@/lib/currency';
import { createClient, requireOnboardedUser } from '@/lib/supabase/server';

import { ImportWizard } from './import-wizard';

type ImportPageProps = { params: Promise<{ locale: string }> };

export async function generateMetadata({ params }: ImportPageProps): Promise<Metadata> {
  const locale = toAppLocale((await params).locale);
  const t = await getTranslations({ locale, namespace: 'Import' });
  return { title: t('metaTitle') };
}

export default async function ImportPage() {
  const user = await requireOnboardedUser('/dashboard/transactions/import');
  const t = await getTranslations('Import');

  const supabase = await createClient();
  // Ausdrücklich eigene Konten: RLS gibt Beratern auch die ihrer Mandanten frei.
  const { data: accounts, error } = await supabase
    .from('accounts')
    .select('id, name, currency')
    .eq('user_id', user.id)
    .in('provider', ['manual', 'csv'])
    .is('archived_at', null)
    .order('name');
  if (error) {
    console.error('[import] Konten nicht ladbar', { code: error.code });
  }

  return (
    <section aria-labelledby="page-title" className="import-page">
      <p className="back-link">
        <Link href="/dashboard/transactions">← {t('back')}</Link>
      </p>
      <h1 id="page-title">{t('heading')}</h1>
      <p>{t('intro')}</p>
      {error ? (
        <p role="alert" className="form-error">
          {t('errors.generic')}
        </p>
      ) : (
        <ImportWizard accounts={accounts ?? []} currencies={SUPPORTED_CURRENCIES} />
      )}
    </section>
  );
}
