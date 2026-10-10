/**
 * app/[locale]/dashboard/transactions/[id]/category/page.tsx
 *
 * Kategorie einer Buchung ändern – vor allem für importierte und
 * synchronisierte Buchungen, die sonst nicht bearbeitbar sind. Die
 * Datenbank lernt daraus eine Regel für den Händler
 * (public.set_transaction_category). „Warum diese Kategorie?“ nennt die
 * Regel bzw. die manuelle Zuordnung (transactions.categorization_rule_id).
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

/** Textschlüssel für „Warum diese Kategorie?“ je Herkunft der Regel. */
function whyKey(origin: string): 'standard' | 'learned' | 'ownAccount' | 'bankCategory' | 'rule' {
  return origin === 'standard'
    ? 'standard'
    : origin === 'learned'
      ? 'learned'
      : origin === 'own_account'
        ? 'ownAccount'
        : origin === 'bank_category'
          ? 'bankCategory'
          : 'rule';
}

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
  const tRules = await getTranslations('Rules');
  const tRecurrence = await getTranslations('Recurrence');
  const format = await getFormatter();

  const supabase = await createClient();
  const [{ data: tx, error }, options] = await Promise.all([
    supabase
      .from('transactions')
      .select(
        `id, source, booking_date, amount, currency, counterparty_name, purpose, category_id,
         transaction_type, counterparty_iban, description, categorization_source, counterparty_key, recurrence,
         categorization_confidence,
         rule:categorization_rules!transactions_categorization_rule_fkey ( pattern, origin, match_field )`,
      )
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

  // Gegenpartei-Gedächtnis: wie oft wurde diese Gegenpartei manuell so
  // zugeordnet (Grundlage der gelernten Zuordnung)?
  let memoryCount = 0;
  if (tx?.categorization_source === 'learned' && tx.categorization_confidence === null && tx.counterparty_key && tx.category_id) {
    const { count } = await supabase
      .from('transactions')
      .select('id', { count: 'exact', head: true })
      .eq('user_id', user.id)
      .eq('counterparty_key', tx.counterparty_key)
      .eq('category_id', tx.category_id)
      .eq('categorization_source', 'manual');
    memoryCount = count ?? 0;
  }
  const automatic = tx?.categorization_source === 'rule' || tx?.categorization_source === 'learned';

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
            {tx.description ? (
              <>
                <dt>{t('description')}</dt>
                <dd>{tx.description}</dd>
              </>
            ) : null}
            {tx.transaction_type ? (
              <>
                <dt>{t('transactionType')}</dt>
                <dd>{tx.transaction_type}</dd>
              </>
            ) : null}
            {tx.recurrence ? (
              <>
                <dt>{t('recurrence')}</dt>
                <dd>{tRecurrence(tx.recurrence)}</dd>
              </>
            ) : null}
            {tx.counterparty_iban ? (
              <>
                <dt>{t('counterpartyIban')}</dt>
                <dd className="nowrap">{tx.counterparty_iban}</dd>
              </>
            ) : null}
          </dl>

          <section className="why-category" aria-labelledby="why-heading">
            <h2 id="why-heading">{t('why.heading')}</h2>
            <p>
              {tx.category_id === null
                ? t('why.none')
                : tx.categorization_source === 'learned' && tx.categorization_confidence !== null
                  ? t('why.bayes', {
                      confidence: format.number(tx.categorization_confidence, { style: 'percent' }),
                    })
                  : tx.categorization_source === 'learned'
                  ? t('why.memory', { count: memoryCount })
                  : tx.categorization_source !== 'rule'
                    ? t('why.manual')
                    : tx.rule
                    ? t(`why.${whyKey(tx.rule.origin)}`, {
                        pattern: tx.rule.pattern,
                        field: tRules(`fields.${tx.rule.match_field}`),
                      })
                    : t('why.ruleDeleted')}{' '}
              {tx.categorization_source === 'rule' ? (
                <Link href="/dashboard/transactions/rules">{t('why.toRules')}</Link>
              ) : null}
            </p>
            {automatic ? <p className="hint">{t('why.confirmHint')}</p> : null}
          </section>

          {tx.source !== 'manual' ? <p className="hint">{t('learnHint')}</p> : null}
          <CategoryForm transactionId={tx.id} categories={options.categories} current={tx.category_id} />
        </>
      )}
    </section>
  );
}
