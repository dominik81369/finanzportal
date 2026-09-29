/**
 * Seitennavigation der Transaktionsliste. Die Links behalten alle aktiven
 * Filter (listQueryString); die Anzeige „Einträge x–y von z“ steht immer da,
 * die Links nur, wenn es mehr als eine Seite gibt.
 */
import { getTranslations } from 'next-intl/server';

import { Link } from '@/i18n/navigation';
import { listQueryString, type TransactionFilters } from '@/lib/transaction-filters';

type PaginationProps = {
  filters: TransactionFilters;
  page: number;
  pages: number;
  total: number;
  firstRow: number;
  lastRow: number;
};

export async function Pagination({ filters, page, pages, total, firstRow, lastRow }: PaginationProps) {
  const t = await getTranslations('Transactions.pagination');
  const href = (target: number) => `/dashboard/transactions${listQueryString(filters, target)}`;

  return (
    <nav className="pagination" aria-label={t('label')}>
      <p className="pagination-range">{t('range', { from: firstRow, to: lastRow, total })}</p>
      {pages > 1 ? (
        <div className="pagination-links">
          {page > 1 ? (
            <Link className="button button-secondary" href={href(page - 1)} rel="prev">
              {t('previous')}
            </Link>
          ) : (
            <span className="button button-secondary" aria-disabled="true">
              {t('previous')}
            </span>
          )}
          <span className="pagination-current" aria-current="page">
            {t('pageOf', { page, pages })}
          </span>
          {page < pages ? (
            <Link className="button button-secondary" href={href(page + 1)} rel="next">
              {t('next')}
            </Link>
          ) : (
            <span className="button button-secondary" aria-disabled="true">
              {t('next')}
            </span>
          )}
        </div>
      ) : null}
    </nav>
  );
}
