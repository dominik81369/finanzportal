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
import { requireOnboardedUser } from '@/lib/supabase/server';
import { hasActiveFilters, parsePage, parseTransactionFilters } from '@/lib/transaction-filters';

import { loadTransactionFormOptions } from './form-options';
import { Pagination } from './pagination';
import { TransactionFiltersForm } from './transaction-filters-form';
import { loadTransactionList } from './transaction-list';
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
          : null;
  const t = await getTranslations('Transactions.list');
  const tDashboard = await getTranslations('Dashboard');

  const filters = parseTransactionFilters(query);
  const filtered = hasActiveFilters(filters);
  const page = parsePage(query);

  const [{ transactions, total, pages, firstRow }, options] = await Promise.all([
    loadTransactionList({ userId: user.id, filters, page, listPath: LIST_PATH }),
    loadTransactionFormOptions(user.id),
  ]);

  return (
    <section aria-labelledby="page-title">
      <div className="page-header">
        <h1 id="page-title">{tDashboard('transactions.title')}</h1>
        <Link className="button" href="/dashboard/transactions/new">
          {t('add')}
        </Link>
      </div>
      <p>{tDashboard('transactions.description')}</p>

      {notice ? (
        <p role="status" className="form-success">
          {t(notice)}
        </p>
      ) : null}

      {/* Ohne Buchungen und ohne Filter gibt es nichts zu filtern. */}
      {options && (filtered || (transactions && transactions.length > 0)) ? (
        <TransactionFiltersForm filters={filters} active={filtered} basePath={LIST_PATH} {...options} />
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
