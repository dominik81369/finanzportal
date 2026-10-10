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
import {
  ASSIGNMENTS,
  SEARCH_MAX_LENGTH,
  UNCATEGORIZED,
  listQueryString,
  type TransactionFilters,
} from '@/lib/transaction-filters';
import type { Account, Tag } from '@/types/domain';

import type { CategoryOption } from './transaction-form';

type TransactionFiltersFormProps = {
  filters: TransactionFilters;
  active: boolean;
  /** Pfad der Liste ohne Sprachpräfix (Ziel von „Filter zurücksetzen“). */
  basePath: string;
  accounts: Pick<Account, 'id' | 'name'>[];
  categories: CategoryOption[];
  tags: Pick<Tag, 'id' | 'name'>[];
  /** Anzeigename der gefilterten Gegenpartei (z. B. aus der ersten Buchung). */
  counterpartyLabel?: string | null;
};

export async function TransactionFiltersForm({
  filters,
  active,
  basePath,
  accounts,
  categories,
  tags,
  counterpartyLabel = null,
}: TransactionFiltersFormProps) {
  const t = await getTranslations('Transactions.filters');
  const tForm = await getTranslations('Transactions.form');

  const categoryGroups = (['expense', 'income', 'transfer'] as const)
    .map((kind) => ({ kind, options: categories.filter((c) => c.kind === kind) }))
    .filter((group) => group.options.length > 0);

  // Gegenpartei kommt nur per Link (Ausgaben-Dashboard): als Hinweis mit
  // „entfernen“, im Formular als verstecktes Feld, damit sie beim Filtern bleibt.
  const withoutCounterparty = listQueryString({ ...filters, counterparty: null }, 1);
  const counterpartyText =
    counterpartyLabel ??
    (filters.counterparty?.startsWith('i:') ? t('counterpartyAccount') : (filters.counterparty?.slice(2) ?? ''));

  return (
    <form method="get" className="filters" role="search" aria-label={t('heading')}>
      {filters.counterparty ? (
        <p className="filter-chip">
          <input type="hidden" name="counterparty" value={filters.counterparty} />
          <span>{t('counterparty', { name: counterpartyText })}</span>{' '}
          <Link href={`${basePath}${withoutCounterparty}`} aria-label={t('counterpartyRemove', { name: counterpartyText })}>
            {t('remove')}
          </Link>
        </p>
      ) : null}
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
        <label htmlFor="filter-assigned">{t('assigned')}</label>
        <select id="filter-assigned" name="assigned" defaultValue={filters.assigned ?? ''}>
          <option value="">{t('allAssignments')}</option>
          {ASSIGNMENTS.map((assignment) => (
            <option key={assignment} value={assignment}>
              {t(`assignments.${assignment}`)}
            </option>
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
          <Link className="button button-secondary" href={basePath}>
            {t('reset')}
          </Link>
        ) : null}
      </div>
    </form>
  );
}
