/**
 * app/[locale]/dashboard/transactions/[id]/category/page.tsx
 *
 * Kategorie einer Buchung ändern – vor allem für importierte und
 * synchronisierte Buchungen, die sonst nicht bearbeitbar sind. Die
 * Datenbank lernt daraus eine Regel für den Händler
 * (public.set_transaction_category).
 */
import type { Metadata } from 'next';
import { notFound } from 'next/navigation';
import { getFormatter, getTranslations } from 'next-intl/server';

import { Link } from '@/i18n/navigation';
import { toAppLocale } from '@/i18n/routing';
import { createClient, requireOnboardedUser } from '@/lib/supabase/server';
import { isUuid } from '@/lib/transactions';

import { loadTransactionFormOptions } from '../../form-options';
import { CategoryForm } from './category-form';

type CategoryPageProps = { params: Promise<{ locale: string; id: string }> };

export async function generateMetadata({ params }: CategoryPageProps): Promise<Metadata> {
  const locale = toAppLocale((await params).locale);
  const t = await getTranslations({ locale, namespace: 'TransactionCategory' });
  return { title: t('metaTitle') };
}

export default async function TransactionCategoryPage({ params }: CategoryPageProps) {
  const { id } = await params;
  const user = await requireOnboardedUser('/dashboard/transactions');
  if (!isUuid(id)) {
    notFound();
  }
  const t = await getTranslations('TransactionCategory');
  const format = await getFormatter();

  const supabase = await createClient();
  const [{ data: tx, error }, options] = await Promise.all([
    supabase
      .from('transactions')
      .select('id, source, booking_date, amount, currency, counterparty_name, purpose, category_id')
      .eq('id', id)
      .eq('user_id', user.id)
      .maybeSingle(),
    loadTransactionFormOptions(user.id),
  ]);
  if (error) {
    console.error('[transactions] Buchung nicht ladbar', { code: error.code });
  }
  if (!tx && !error) {
    notFound();
  }

  return (
    <section className="page-narrow" aria-labelledby="page-title">
      <p className="back-link">
        <Link href="/dashboard/transactions">← {t('back')}</Link>
      </p>
      <h1 id="page-title">{t('heading')}</h1>
      {!tx || !options ? (
        <p role="alert" className="form-error">
          {t('errors.generic')}
        </p>
      ) : (
        <>
          <dl className="transaction-summary">
            <dt>{t('date')}</dt>
            <dd>
              {format.dateTime(new Date(`${tx.booking_date}T00:00:00Z`), { dateStyle: 'medium', timeZone: 'UTC' })}
            </dd>
            <dt>{t('amount')}</dt>
            <dd>{format.number(tx.amount, { style: 'currency', currency: tx.currency })}</dd>
            {tx.counterparty_name ? (
              <>
                <dt>{t('counterparty')}</dt>
                <dd>{tx.counterparty_name}</dd>
              </>
            ) : null}
            {tx.purpose ? (
              <>
                <dt>{t('purpose')}</dt>
                <dd>{tx.purpose}</dd>
              </>
            ) : null}
          </dl>
          {tx.source !== 'manual' ? <p className="hint">{t('learnHint')}</p> : null}
          <CategoryForm transactionId={tx.id} categories={options.categories} current={tx.category_id} />
        </>
      )}
    </section>
  );
}
