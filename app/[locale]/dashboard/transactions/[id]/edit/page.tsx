/**
 * app/[locale]/dashboard/transactions/[id]/edit/page.tsx
 *
 * Eigene, manuell erfasste Buchung bearbeiten oder löschen. Importierte bzw.
 * synchronisierte Buchungen werden nur angezeigt (Hinweis statt Formular).
 *
 * Die Abfrage filtert ausdrücklich auf user_id = eigener Nutzer: Berater
 * dürfen Buchungen ihrer Mandanten lesen, hier aber nicht bearbeiten –
 * für sie ist die Seite ein 404. update_/delete_manual_transaction()
 * prüfen Eigentum und Herkunft zusätzlich selbst.
 */
import type { Metadata } from 'next';
import { notFound } from 'next/navigation';
import { getLocale, getTranslations } from 'next-intl/server';

import { Link } from '@/i18n/navigation';
import { toAppLocale } from '@/i18n/routing';
import { deleteTransaction, updateTransaction } from '@/lib/actions/update-transaction';
import { createClient, requireOnboardedUser } from '@/lib/supabase/server';
import type { TransactionFormValues } from '@/lib/transaction-form-types';
import { formatAmountInput, isUuid, todayInGermany } from '@/lib/transactions';

import { loadTransactionFormOptions } from '../../form-options';
import { TransactionForm } from '../../transaction-form';
import { DeleteTransaction } from './delete-transaction';

type EditTransactionPageProps = { params: Promise<{ locale: string; id: string }> };

export async function generateMetadata({ params }: EditTransactionPageProps): Promise<Metadata> {
  const locale = toAppLocale((await params).locale);
  const t = await getTranslations({ locale, namespace: 'Transactions.edit' });
  return { title: t('metaTitle') };
}

export default async function EditTransactionPage({ params }: EditTransactionPageProps) {
  const { id } = await params;
  if (!isUuid(id)) {
    notFound();
  }

  const user = await requireOnboardedUser(`/dashboard/transactions/${id}/edit`);
  const t = await getTranslations('Transactions');
  const locale = toAppLocale(await getLocale());

  const supabase = await createClient();
  const [{ data: transaction, error }, options] = await Promise.all([
    supabase
      .from('transactions')
      .select(
        `id, source, booking_date, amount, currency, counterparty_name, purpose,
         account_id, category_id, transaction_tags ( tag_id )`,
      )
      .eq('id', id)
      .eq('user_id', user.id)
      .maybeSingle(),
    loadTransactionFormOptions(user.id),
  ]);

  if (error) {
    console.error('[transactions/edit] Laden fehlgeschlagen', { code: error.code });
  } else if (!transaction) {
    notFound();
  }

  const header = (
    <>
      <p className="back-link">
        <Link href="/dashboard/transactions">← {t('form.back')}</Link>
      </p>
      <h1 id="page-title">{t('edit.heading')}</h1>
    </>
  );

  if (!transaction || !options) {
    return (
      <section className="page-narrow" aria-labelledby="page-title">
        {header}
        <p role="alert" className="form-error">
          {t('list.loadError')}
        </p>
      </section>
    );
  }

  if (transaction.source !== 'manual') {
    return (
      <section className="page-narrow" aria-labelledby="page-title">
        {header}
        <p role="status" className="form-success">
          {t('edit.notEditable')}
        </p>
      </section>
    );
  }

  const initialValues: TransactionFormValues = {
    type: transaction.amount < 0 ? 'expense' : 'income',
    amount: formatAmountInput(transaction.amount, locale),
    currency: transaction.currency,
    bookingDate: transaction.booking_date,
    counterparty: transaction.counterparty_name ?? '',
    purpose: transaction.purpose ?? '',
    accountId: transaction.account_id,
    categoryId: transaction.category_id ?? '',
    tagIds: transaction.transaction_tags.map((tt) => tt.tag_id),
    newTags: '',
  };

  return (
    <section className="page-narrow" aria-labelledby="page-title">
      {header}
      <TransactionForm
        mode="edit"
        action={updateTransaction.bind(null, transaction.id)}
        {...options}
        today={todayInGermany()}
        initialValues={initialValues}
      />
      <DeleteTransaction action={deleteTransaction.bind(null, transaction.id)} />
    </section>
  );
}
