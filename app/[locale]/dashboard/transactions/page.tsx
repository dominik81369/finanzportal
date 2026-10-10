/**
 * app/[locale]/dashboard/transactions/page.tsx
 *
 * Buchungen des angemeldeten Nutzers mit Kategorie, Tags und Konto, mit
 * Suche, Filtern und Seiten (lib/transaction-filters.ts, Werte als
 * Query-Parameter). Erfassung unter ./new. Laden und Reihenfolge:
 * ./transaction-list.ts (gemeinsam mit der Leseansicht des Beraters).
 */
import type { Metadata } from 'next';
import { getTranslations } from 'next-intl/server';

import { Link } from '@/i18n/navigation';
import { toAppLocale } from '@/i18n/routing';
import { applyRuleToSimilar } from '@/lib/actions/categorization-rules';
import { createClient, requireOnboardedUser } from '@/lib/supabase/server';
import { hasActiveFilters, parsePage, parseTransactionFilters } from '@/lib/transaction-filters';
import { isUuid } from '@/lib/transactions';

import { loadTransactionFormOptions } from './form-options';
import { Pagination } from './pagination';
import { TransactionFiltersForm } from './transaction-filters-form';
import { loadTransactionList } from './transaction-list';
import { QualityStats } from './quality-stats';
import { TransactionTable } from './transaction-table';

const LIST_PATH = '/dashboard/transactions';

type TransactionsPageProps = {
  params: Promise<{ locale: string }>;
  searchParams: Promise<Record<string, string | string[] | undefined>>;
};

export async function generateMetadata({
  params,
}: Pick<TransactionsPageProps, 'params'>): Promise<Metadata> {
  const locale = toAppLocale((await params).locale);
  const t = await getTranslations({ locale, namespace: 'Dashboard' });
  return { title: t('transactions.title') };
}

export default async function TransactionsPage({ searchParams }: TransactionsPageProps) {
  const user = await requireOnboardedUser(LIST_PATH);
  const query = await searchParams;
  // Bestätigung nach Anlegen, Bearbeiten bzw. Löschen (Weiterleitung der Actions).
  const notice =
    query.saved === '1'
      ? 'saved'
      : query.updated === '1'
        ? 'updated'
        : query.deleted === '1'
          ? 'deleted'
          : query.categorized === '1'
            ? 'categorized'
            : null;
  // Nach einer Kategorie-Korrektur: gelernter Händlername (siehe
  // lib/actions/categorization-rules.ts).
  const learned = typeof query.learned === 'string' ? query.learned.slice(0, 60) : null;
  // „N ähnliche Buchungen gefunden, auch zuordnen?“ (Regel-ID und Anzahl aus
  // set_transaction_category) bzw. Ergebnis danach.
  const count = (value: string | string[] | undefined) =>
    typeof value === 'string' && /^\d{1,6}$/.test(value) ? Number(value) : 0;
  const similar = count(query.similar);
  // Automatisch (per Regel) anders zugeordnete – nur auf Wunsch überschreiben.
  const similarAuto = count(query.similarAuto);
  const similarRule = typeof query.rule === 'string' && isUuid(query.rule) ? query.rule : null;
  const applied = typeof query.applied === 'string' && /^\d{1,6}$/.test(query.applied) ? Number(query.applied) : null;
  const t = await getTranslations('Transactions.list');
  const tDashboard = await getTranslations('Dashboard');

  const filters = parseTransactionFilters(query);
  const filtered = hasActiveFilters(filters);
  const page = parsePage(query);

  const supabase = await createClient();
  const [{ transactions, total, pages, firstRow }, options, review] = await Promise.all([
    loadTransactionList({ userId: user.id, filters, page, listPath: LIST_PATH }),
    loadTransactionFormOptions(user.id),
    // Vorschläge in der Prüfliste (Stand des letzten Imports/Anwendens).
    supabase
      .from('transactions')
      .select('id', { count: 'exact', head: true })
      .eq('user_id', user.id)
      .is('category_id', null)
      .not('suggested_category_id', 'is', null),
  ]);
  const reviewCount = review.count ?? 0;

  return (
    <section aria-labelledby="page-title">
      <div className="page-header">
        <h1 id="page-title">{tDashboard('transactions.title')}</h1>
        <div className="page-header-actions">
          <Link className="button button-secondary" href="/dashboard/transactions/review">
            {t('review', { count: reviewCount })}
          </Link>
          <Link className="button button-secondary" href="/dashboard/transactions/groups">
            {t('groups')}
          </Link>
          <Link className="button button-secondary" href="/dashboard/transactions/rules">
            {t('rules')}
          </Link>
          <Link className="button button-secondary" href="/dashboard/transactions/import">
            {t('import')}
          </Link>
          <Link className="button" href="/dashboard/transactions/new">
            {t('add')}
          </Link>
        </div>
      </div>
      <p>{tDashboard('transactions.description')}</p>
      <QualityStats />

      {notice ? (
        <p role="status" className="form-success">
          {t(notice)}
          {notice === 'categorized' && learned ? (
            <>
              {' '}
              {t('learned', { pattern: learned })}{' '}
              <Link href="/dashboard/transactions/rules">{t('toRules')}</Link>
            </>
          ) : null}
        </p>
      ) : null}

      {notice === 'categorized' && (similar > 0 || similarAuto > 0) && similarRule ? (
        <div className="notice similar-notice" role="status">
          <p>
            {similarAuto === 0
              ? t('similarFound', { count: similar })
              : similar === 0
                ? t('similarFoundAuto', { count: similarAuto })
                : t('similarFoundBoth', { open: similar, auto: similarAuto })}
          </p>
          <div className="button-row">
            {similar > 0 ? (
              <form action={applyRuleToSimilar.bind(null, similarRule, false)}>
                <button type="submit" className="button button-small">
                  {t('similarApply', { count: similar })}
                </button>
              </form>
            ) : null}
            {similarAuto > 0 ? (
              <form action={applyRuleToSimilar.bind(null, similarRule, true)}>
                <button type="submit" className={`button button-small${similar > 0 ? ' button-secondary' : ''}`}>
                  {t('similarApplyAll', { count: similar + similarAuto })}
                </button>
              </form>
            ) : null}
          </div>
        </div>
      ) : null}
      {applied !== null ? (
        <p role="status" className="form-success">
          {t('similarApplied', { count: applied })}
        </p>
      ) : null}

      {/* Ohne Buchungen und ohne Filter gibt es nichts zu filtern. */}
      {options && (filtered || (transactions && transactions.length > 0)) ? (
        <TransactionFiltersForm
            filters={filters}
            active={filtered}
            basePath={LIST_PATH}
            counterpartyLabel={filters.counterparty ? (transactions?.[0]?.counterparty_name ?? null) : null}
            {...options}
          />
      ) : null}

      {filtered && transactions ? (
        <p role="status" className="result-count">
          {t('resultCount', { count: total })}
        </p>
      ) : null}

      {!transactions ? (
        <p role="alert" className="form-error">
          {t('loadError')}
        </p>
      ) : transactions.length === 0 ? (
        <p className="empty-state">{filtered ? t('noMatches') : t('empty')}</p>
      ) : (
        <>
          <TransactionTable transactions={transactions} caption={t('caption')} editable />
          <Pagination
            basePath={LIST_PATH}
            filters={filters}
            page={page}
            pages={pages}
            total={total}
            firstRow={firstRow}
            lastRow={firstRow + transactions.length - 1}
          />
        </>
      )}
    </section>
  );
}
