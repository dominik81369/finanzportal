/**
 * app/[locale]/dashboard/transactions/page.tsx
 *
 * Liste der letzten Buchungen des angemeldeten Nutzers mit Kategorie, Tags
 * und Konto, mit Suche und Filtern (lib/transaction-filters.ts, Werte als
 * Query-Parameter). Erfassung unter ./new.
 *
 * Die Abfrage filtert ausdrücklich auf user_id = eigener Nutzer: RLS lässt
 * Berater zusätzlich die Buchungen ihrer Mandanten lesen.
 */
import type { Metadata } from 'next';
import { getFormatter, getLocale, getTranslations } from 'next-intl/server';

import { Link } from '@/i18n/navigation';
import { toAppLocale } from '@/i18n/routing';
import { createClient, requireOnboardedUser } from '@/lib/supabase/server';
import {
  UNCATEGORIZED,
  hasActiveFilters,
  ilikeContainsPattern,
  parseTransactionFilters,
} from '@/lib/transaction-filters';

import { loadTransactionFormOptions } from './form-options';
import { TransactionFiltersForm } from './transaction-filters-form';

const LIST_LIMIT = 100;


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
  const user = await requireOnboardedUser('/dashboard/transactions');
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
  const format = await getFormatter();
  const collator = new Intl.Collator(await getLocale());

  const filters = parseTransactionFilters(query);
  const filtered = hasActiveFilters(filters);

  const supabase = await createClient();
  let request = supabase
    .from('transactions')
    // tag_filter: eigener Alias nur für den Tag-Filter, damit transaction_tags
    // weiterhin ALLE Tags der Buchung liefert.
    .select(
      `id, source, booking_date, amount, currency, counterparty_name, purpose,
       account:accounts!transactions_account_fkey ( name ),
       category:categories!transactions_category_fkey ( name, color ),
       transaction_tags ( tag:tags!transaction_tags_tag_fkey ( id, name ) ),
       tag_filter:transaction_tags ( tag_id )`,
    )
    .eq('user_id', user.id);

  if (filters.q) {
    const pattern = ilikeContainsPattern(filters.q);
    request = request.or(`counterparty_name.ilike.${pattern},purpose.ilike.${pattern}`);
  }
  if (filters.type === 'expense') {
    request = request.lt('amount', 0);
  } else if (filters.type === 'income') {
    request = request.gt('amount', 0);
  }
  if (filters.accountId) {
    request = request.eq('account_id', filters.accountId);
  }
  if (filters.categoryId === UNCATEGORIZED) {
    request = request.is('category_id', null);
  } else if (filters.categoryId) {
    request = request.eq('category_id', filters.categoryId);
  }
  if (filters.tagId) {
    // Eingebettete Zeilen filtern und Buchungen ohne Treffer ausschließen
    // (PostgREST: Null-Filter auf der Einbettung wirkt wie ein Inner Join).
    request = request.eq('tag_filter.tag_id', filters.tagId).not('tag_filter', 'is', null);
  }
  if (filters.from) {
    request = request.gte('booking_date', filters.from);
  }
  if (filters.to) {
    request = request.lte('booking_date', filters.to);
  }

  const [{ data: transactions, error }, options] = await Promise.all([
    request
      .order('booking_date', { ascending: false })
      .order('created_at', { ascending: false })
      .limit(LIST_LIMIT),
    loadTransactionFormOptions(user.id),
  ]);

  if (error) {
    console.error('[transactions] Laden fehlgeschlagen', { code: error.code });
  }

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
        <TransactionFiltersForm filters={filters} active={filtered} {...options} />
      ) : null}

      {filtered && transactions ? (
        <p role="status" className="result-count">
          {transactions.length >= LIST_LIMIT
            ? t('resultCountLimited', { limit: LIST_LIMIT })
            : t('resultCount', { count: transactions.length })}
        </p>
      ) : null}

      {error ? (
        <p role="alert" className="form-error">
          {t('loadError')}
        </p>
      ) : !transactions || transactions.length === 0 ? (
        <p className="empty-state">{filtered ? t('noMatches') : t('empty')}</p>
      ) : (
        <div className="table-scroll">
          <table className="transactions-table">
            <caption>{t('caption', { limit: LIST_LIMIT })}</caption>
            <thead>
              <tr>
                <th scope="col">{t('columns.date')}</th>
                <th scope="col">{t('columns.counterparty')}</th>
                <th scope="col">{t('columns.category')}</th>
                <th scope="col">{t('columns.tags')}</th>
                <th scope="col">{t('columns.account')}</th>
                <th scope="col" className="amount">
                  {t('columns.amount')}
                </th>
                <th scope="col">
                  <span className="sr-only">{t('actions')}</span>
                </th>
              </tr>
            </thead>
            <tbody>
              {transactions.map((tx) => {
                // booking_date ist ein reines Datum: als UTC lesen und anzeigen.
                const date = format.dateTime(new Date(`${tx.booking_date}T00:00:00Z`), {
                  dateStyle: 'medium',
                  timeZone: 'UTC',
                });
                return (
                  <tr key={tx.id}>
                    <td className="nowrap">{date}</td>
                    <td>
                      {tx.counterparty_name}
                      {tx.purpose ? <span className="cell-note">{tx.purpose}</span> : null}
                    </td>
                    <td>
                      {tx.category ? (
                        <span className="category">
                          <span
                            className="category-dot"
                            aria-hidden="true"
                            style={{ background: tx.category.color ?? 'var(--muted-foreground)' }}
                          />
                          {tx.category.name}
                        </span>
                      ) : (
                        <span className="muted">{t('uncategorized')}</span>
                      )}
                    </td>
                    <td>
                      <TagList
                        tags={tx.transaction_tags
                          .flatMap(({ tag }) => (tag ? [tag] : []))
                          .sort((a, b) => collator.compare(a.name, b.name))}
                      />
                    </td>
                    <td>{tx.account?.name}</td>
                    <td className={`amount ${tx.amount < 0 ? 'amount-negative' : 'amount-positive'}`}>
                      {format.number(tx.amount, { style: 'currency', currency: tx.currency })}
                    </td>
                    <td className="row-actions">
                      {/* Nur manuell erfasste Buchungen sind bearbeitbar. */}
                      {tx.source === 'manual' ? (
                        <Link
                          href={`/dashboard/transactions/${tx.id}/edit`}
                          aria-label={t('editLabel', { counterparty: tx.counterparty_name ?? '', date })}
                        >
                          {t('edit')}
                        </Link>
                      ) : null}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}
    </section>
  );
}

function TagList({ tags }: { tags: { id: string; name: string }[] }) {
  if (tags.length === 0) {
    return null;
  }
  return (
    <ul className="tag-list">
      {tags.map((tag) => (
        <li key={tag.id}>{tag.name}</li>
      ))}
    </ul>
  );
}
