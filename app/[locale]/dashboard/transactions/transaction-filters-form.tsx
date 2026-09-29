/**
 * Such- und Filterformular der Transaktionsliste.
 *
 * Bewusst ein einfaches GET-Formular ohne eigenes JavaScript: Die Filter
 * landen als Query-Parameter in der URL der aktuellen Seite (inkl.
 * Sprachpräfix) und werden serverseitig ausgewertet
 * (lib/transaction-filters.ts).
 */
import { getTranslations } from 'next-intl/server';

import { Link } from '@/i18n/navigation';
import { SEARCH_MAX_LENGTH, UNCATEGORIZED, type TransactionFilters } from '@/lib/transaction-filters';
import type { Account, Tag } from '@/types/domain';

import type { CategoryOption } from './transaction-form';

type TransactionFiltersFormProps = {
  filters: TransactionFilters;
  active: boolean;
  accounts: Pick<Account, 'id' | 'name'>[];
  categories: CategoryOption[];
  tags: Pick<Tag, 'id' | 'name'>[];
};

export async function TransactionFiltersForm({
  filters,
  active,
  accounts,
  categories,
  tags,
}: TransactionFiltersFormProps) {
  const t = await getTranslations('Transactions.filters');
  const tForm = await getTranslations('Transactions.form');

  const categoryGroups = (['expense', 'income', 'transfer'] as const)
    .map((kind) => ({ kind, options: categories.filter((c) => c.kind === kind) }))
    .filter((group) => group.options.length > 0);

  return (
    <form method="get" className="filters" role="search" aria-label={t('heading')}>
      <div className="filter-field filter-search">
        <label htmlFor="filter-q">{t('search')}</label>
        <input
          id="filter-q"
          name="q"
          type="search"
          maxLength={SEARCH_MAX_LENGTH}
          placeholder={t('searchPlaceholder')}
          defaultValue={filters.q}
        />
      </div>

      <div className="filter-field">
        <label htmlFor="filter-type">{t('type')}</label>
        <select id="filter-type" name="type" defaultValue={filters.type ?? ''}>
          <option value="">{t('allTypes')}</option>
          <option value="expense">{t('expense')}</option>
          <option value="income">{t('income')}</option>
        </select>
      </div>

      <div className="filter-field">
        <label htmlFor="filter-account">{t('account')}</label>
        <select id="filter-account" name="account" defaultValue={filters.accountId ?? ''}>
          <option value="">{t('allAccounts')}</option>
          {accounts.map((account) => (
            <option key={account.id} value={account.id}>
              {account.name}
            </option>
          ))}
        </select>
      </div>

      <div className="filter-field">
        <label htmlFor="filter-category">{t('category')}</label>
        <select id="filter-category" name="category" defaultValue={filters.categoryId ?? ''}>
          <option value="">{t('allCategories')}</option>
          <option value={UNCATEGORIZED}>{t('uncategorized')}</option>
          {categoryGroups.map((group) => (
            <optgroup key={group.kind} label={tForm(`categoryGroups.${group.kind}`)}>
              {group.options.map((category) => (
                <option key={category.id} value={category.id}>
                  {category.label}
                </option>
              ))}
            </optgroup>
          ))}
        </select>
      </div>

      <div className="filter-field">
        <label htmlFor="filter-tag">{t('tag')}</label>
        <select id="filter-tag" name="tag" defaultValue={filters.tagId ?? ''}>
          <option value="">{t('allTags')}</option>
          {tags.map((tag) => (
            <option key={tag.id} value={tag.id}>
              {tag.name}
            </option>
          ))}
        </select>
      </div>

      <div className="filter-field">
        <label htmlFor="filter-from">{t('from')}</label>
        <input id="filter-from" name="from" type="date" defaultValue={filters.from ?? ''} />
      </div>

      <div className="filter-field">
        <label htmlFor="filter-to">{t('to')}</label>
        <input id="filter-to" name="to" type="date" defaultValue={filters.to ?? ''} />
      </div>

      <div className="filter-actions">
        <button type="submit" className="button">
          {t('apply')}
        </button>
        {active ? (
          <Link className="button button-secondary" href="/dashboard/transactions">
            {t('reset')}
          </Link>
        ) : null}
      </div>
    </form>
  );
}
