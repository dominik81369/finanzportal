/**
 * Tabelle einer Seite der Transaktionsliste (siehe ./transaction-list.ts).
 * editable: Bearbeiten-Links (manuell erfasste Buchungen) bzw. „Kategorie“
 * (importierte/synchronisierte) – nur in der eigenen Liste, nie in der
 * Leseansicht des Beraters. Per Regel vergebene Kategorien tragen die
 * Markierung „automatisch“ (Tooltip: welche Regel).
 */
import { getFormatter, getLocale, getTranslations } from 'next-intl/server';

import { Link } from '@/i18n/navigation';
import { categoryDisplayName } from '@/lib/categories';

import type { TransactionListRow } from './transaction-list';

type TransactionTableProps = {
  transactions: TransactionListRow[];
  caption: string;
  editable: boolean;
};

export async function TransactionTable({ transactions, caption, editable }: TransactionTableProps) {
  const t = await getTranslations('Transactions.list');
  const tCategories = await getTranslations('DefaultCategories');
  const format = await getFormatter();
  const collator = new Intl.Collator(await getLocale());

  return (
    <div className="table-scroll">
      <table className="transactions-table">
        <caption>{caption}</caption>
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
            {editable ? (
              <th scope="col">
                <span className="sr-only">{t('actions')}</span>
              </th>
            ) : null}
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
                      {categoryDisplayName(tx.category, tCategories)}
                      {/* Schicht 2/3: per Regel vergeben – unterscheidbar von manuell. */}
                      {tx.categorization_source === 'rule' ? (
                        <span
                          className="badge badge-auto"
                          title={
                            tx.rule
                              ? t(
                                  tx.rule.origin === 'standard'
                                    ? 'autoStandardRule'
                                    : tx.rule.origin === 'own_account'
                                      ? 'autoOwnAccount'
                                      : 'autoOwnRule',
                                  { pattern: tx.rule.pattern },
                                )
                              : t('autoTitle')
                          }
                        >
                          {t('auto')}
                        </span>
                      ) : null}
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
                {editable ? (
                  <td className="row-actions">
                    {/* Manuell erfasste Buchungen sind voll bearbeitbar, importierte
                        und synchronisierte nur in der Kategorie (mit Lernen). */}
                    {tx.source === 'manual' ? (
                      <Link
                        href={`/dashboard/transactions/${tx.id}/edit`}
                        aria-label={t('editLabel', { counterparty: tx.counterparty_name ?? '', date })}
                      >
                        {t('edit')}
                      </Link>
                    ) : (
                      <Link
                        href={`/dashboard/transactions/${tx.id}/category`}
                        aria-label={t('categorizeLabel', { counterparty: tx.counterparty_name ?? tx.purpose ?? '', date })}
                      >
                        {t('categorize')}
                      </Link>
                    )}
                  </td>
                ) : null}
              </tr>
            );
          })}
        </tbody>
      </table>
    </div>
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
