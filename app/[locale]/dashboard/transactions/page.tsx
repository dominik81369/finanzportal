/**
 * app/[locale]/dashboard/transactions/page.tsx
 *
 * Liste der letzten Buchungen des angemeldeten Nutzers mit Kategorie, Tags
 * und Konto. Erfassung unter ./new.
 *
 * Die Abfrage filtert ausdrücklich auf user_id = eigener Nutzer: RLS lässt
 * Berater zusätzlich die Buchungen ihrer Mandanten lesen.
 */
import type { Metadata } from 'next';
import { getFormatter, getLocale, getTranslations } from 'next-intl/server';

import { Link } from '@/i18n/navigation';
import { toAppLocale } from '@/i18n/routing';
import { createClient, requireOnboardedUser } from '@/lib/supabase/server';

const LIST_LIMIT = 100;

type TransactionsPageProps = {
  params: Promise<{ locale: string }>;
  searchParams: Promise<{
    saved?: string | string[];
    updated?: string | string[];
    deleted?: string | string[];
  }>;
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

  const supabase = await createClient();
  const { data: transactions, error } = await supabase
    .from('transactions')
    .select(
      `id, source, booking_date, amount, currency, counterparty_name, purpose,
       account:accounts!transactions_account_fkey ( name ),
       category:categories!transactions_category_fkey ( name, color ),
       transaction_tags ( tag:tags!transaction_tags_tag_fkey ( id, name ) )`,
    )
    .eq('user_id', user.id)
    .order('booking_date', { ascending: false })
    .order('created_at', { ascending: false })
    .limit(LIST_LIMIT);

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

      {error ? (
        <p role="alert" className="form-error">
          {t('loadError')}
        </p>
      ) : !transactions || transactions.length === 0 ? (
        <p className="empty-state">{t('empty')}</p>
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
