/**
 * app/[locale]/dashboard/transactions/new/page.tsx
 *
 * Manuelle Erfassung einer Buchung. Auswahllisten aus ../form-options.ts;
 * gespeichert wird in lib/actions/create-transaction.ts.
 */
import type { Metadata } from 'next';
import { getTranslations } from 'next-intl/server';

import { Link } from '@/i18n/navigation';
import { toAppLocale } from '@/i18n/routing';
import { createTransaction } from '@/lib/actions/create-transaction';
import { requireOnboardedUser } from '@/lib/supabase/server';
import { todayInGermany } from '@/lib/transactions';

import { loadTransactionFormOptions } from '../form-options';
import { TransactionForm } from '../transaction-form';

type NewTransactionPageProps = { params: Promise<{ locale: string }> };

export async function generateMetadata({ params }: NewTransactionPageProps): Promise<Metadata> {
  const locale = toAppLocale((await params).locale);
  const t = await getTranslations({ locale, namespace: 'Transactions.form' });
  return { title: t('metaTitle') };
}

export default async function NewTransactionPage() {
  const user = await requireOnboardedUser('/dashboard/transactions/new');
  const t = await getTranslations('Transactions');
  const options = await loadTransactionFormOptions(user.id);

  return (
    <section className="page-narrow" aria-labelledby="page-title">
      <p className="back-link">
        <Link href="/dashboard/transactions">← {t('form.back')}</Link>
      </p>
      <h1 id="page-title">{t('form.heading')}</h1>

      {options ? (
        <TransactionForm
          mode="create"
          action={createTransaction}
          {...options}
          today={todayInGermany()}
        />
      ) : (
        <p role="alert" className="form-error">
          {t('list.loadError')}
        </p>
      )}
    </section>
  );
}
