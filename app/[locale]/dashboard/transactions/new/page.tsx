/**
 * app/[locale]/dashboard/transactions/new/page.tsx
 *
 * Manuelle Erfassung einer Buchung. Lädt Konten, Kategorien und Tags des
 * angemeldeten Nutzers; gespeichert wird in lib/actions/create-transaction.ts.
 *
 * Alle Abfragen filtern ausdrücklich auf user_id = eigener Nutzer: RLS lässt
 * Berater zusätzlich die Daten ihrer Mandanten LESEN – ohne Filter stünden
 * deren Konten und Kategorien in der Auswahl.
 */
import type { Metadata } from 'next';
import { getTranslations } from 'next-intl/server';

import { Link } from '@/i18n/navigation';
import { toAppLocale } from '@/i18n/routing';
import { createClient, requireOnboardedUser } from '@/lib/supabase/server';
import { todayInGermany } from '@/lib/transactions';

import { TransactionForm, type CategoryOption } from './transaction-form';

type NewTransactionPageProps = { params: Promise<{ locale: string }> };

export async function generateMetadata({ params }: NewTransactionPageProps): Promise<Metadata> {
  const locale = toAppLocale((await params).locale);
  const t = await getTranslations({ locale, namespace: 'Transactions.form' });
  return { title: t('metaTitle') };
}

export default async function NewTransactionPage() {
  const user = await requireOnboardedUser('/dashboard/transactions/new');
  const t = await getTranslations('Transactions');
  const supabase = await createClient();

  const [accounts, categories, tags] = await Promise.all([
    supabase
      .from('accounts')
      .select('id, name, currency')
      .eq('user_id', user.id)
      .is('archived_at', null)
      .order('name'),
    supabase
      .from('categories')
      .select('id, name, kind, parent_category_id, sort_order')
      .eq('user_id', user.id)
      .order('sort_order')
      .order('name'),
    supabase.from('tags').select('id, name').eq('user_id', user.id).order('name'),
  ]);

  const loadError = accounts.error ?? categories.error ?? tags.error;
  if (loadError) {
    console.error('[transactions/new] Laden fehlgeschlagen', { code: loadError.code });
  }

  // Unterkategorien als "Oberkategorie › Unterkategorie" anzeigen.
  const categoryNames = new Map((categories.data ?? []).map((c) => [c.id, c.name]));
  const categoryOptions: CategoryOption[] = (categories.data ?? []).map((c) => {
    const parent = c.parent_category_id ? categoryNames.get(c.parent_category_id) : undefined;
    return { id: c.id, kind: c.kind, label: parent ? `${parent} › ${c.name}` : c.name };
  });

  return (
    <section className="page-narrow" aria-labelledby="page-title">
      <p className="back-link">
        <Link href="/dashboard/transactions">← {t('form.back')}</Link>
      </p>
      <h1 id="page-title">{t('form.heading')}</h1>

      {loadError ? (
        <p role="alert" className="form-error">
          {t('list.loadError')}
        </p>
      ) : (
        <TransactionForm
          accounts={accounts.data ?? []}
          categories={categoryOptions}
          tags={tags.data ?? []}
          today={todayInGermany()}
        />
      )}
    </section>
  );
}
