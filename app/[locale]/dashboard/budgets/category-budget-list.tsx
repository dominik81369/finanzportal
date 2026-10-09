/**
 * Liste der Einzelbudgets (Budget-2) mit Ist-Stand, Fortschrittsbalken,
 * Warnschwelle und Hinweisen zu Ober- und Unterkategorien. Teil der
 * gestreamten Auswertung (budget-overview.tsx); in der Leseansicht des
 * Beraters ohne Links zum Anlegen und Bearbeiten.
 */
import { getFormatter, getTranslations } from 'next-intl/server';
import type { CSSProperties } from 'react';

import { Link } from '@/i18n/navigation';
import type { MonthKey } from '@/lib/budget-rule';
import type { CategoryBudgetResult } from '@/lib/category-budgets';

import type { BudgetCategoryInfo } from './budget-data';

type CategoryBudgetListProps = {
  results: CategoryBudgetResult[] | null;
  categories: BudgetCategoryInfo[];
  /** Anzahl der Monate im angezeigten Zeitraum (Monatsbudgets × Monate). */
  months: number;
  readOnly: boolean;
};

export async function CategoryBudgetList({ results, categories, months, readOnly }: CategoryBudgetListProps) {
  const t = await getTranslations('CategoryBudgets');
  const tBudgets = await getTranslations('Budgets');
  const format = await getFormatter();
  const names = new Map(categories.map((category) => [category.id, category]));
  const label = (id: string) => names.get(id)?.label ?? '–';
  const shortName = (id: string) => names.get(id)?.name ?? '–';
  const monthName = (month: MonthKey) =>
    format.dateTime(new Date(`${month}-01T00:00:00Z`), { month: 'long', timeZone: 'UTC' });
  const percent = (value: number) => format.number(value / 100, { style: 'percent', maximumFractionDigits: 0 });

  return (
    <section className="budget-section category-budgets" id="category-budgets" aria-labelledby="category-budgets-heading">
      <div className="category-budgets-header">
        <h2 id="category-budgets-heading">{t('heading')}</h2>
        {!readOnly ? (
          <Link href="/dashboard/budgets/new" className="button button-small">
            {t('add')}
          </Link>
        ) : null}
      </div>
      <p className="hint">{t('intro')}</p>

      {results === null ? (
        <p role="alert" className="form-error">
          {t('loadError')}
        </p>
      ) : results.length === 0 ? (
        readOnly ? (
          <p className="empty-state">{t('empty.readOnly')}</p>
        ) : (
          <div className="budget-empty category-budgets-empty">
            <strong>{t('empty.title')}</strong>
            <p>{t('empty.text')}</p>
            <p className="hint">{t('variableHint')}</p>
            <Link href="/dashboard/budgets/new" className="button button-small">
              {t('add')}
            </Link>
          </div>
        )
      ) : (
        <ul className="category-budget-list">
          {results.map((result) => {
            const money = (cents: number) =>
              format.number(cents / 100, { style: 'currency', currency: result.currency });
            const name = label(result.categoryId);
            const amountLabel = t(`perPeriod.${result.period}`, { amount: money(result.amountCents) });
            const parent = result.parentBudget;
            return (
              <li
                key={result.id}
                className={`category-budget category-budget-${result.status}`}
                data-budget-id={result.id}
                aria-labelledby={`category-budget-${result.id}`}
              >
                <div className="category-budget-head">
                  <h3 id={`category-budget-${result.id}`}>{name}</h3>
                  <span className={`badge budget-status budget-status-${result.status}`}>
                    {t(`status.${result.status}`)}
                  </span>
                </div>
                <p className="category-budget-meta">
                  {t(`periods.${result.period}`)} · {amountLabel}
                  {result.period === 'monthly' && months > 1 ? ` ${t('timesMonths', { count: months })}` : ''} ·{' '}
                  {result.currency} · {t('threshold', { pct: result.thresholdPct })} ·{' '}
                  {result.group ? tBudgets(`groups.${result.group}`) : t('noGroup')}
                </p>
                {/* Breiten als CSS-Variablen; Farben und Maße aus den Tokens. */}
                <span className="budget-progress" aria-hidden="true" style={{ '--budget-used': `${Math.min(Math.max(result.usedPct, 0), 100).toFixed(1)}%`, '--budget-threshold': `${result.thresholdPct}%` } as CSSProperties}>
                  <span className="budget-progress-fill" />
                  <span className="budget-progress-threshold" />
                </span>
                <p className="category-budget-amounts">
                  {t('used', {
                    actual: money(result.actualCents),
                    limit: money(result.limitCents),
                    pct: percent(result.usedPct),
                  })}{' '}
                  ·{' '}
                  <span className={result.remainingCents < 0 ? 'budget-over' : undefined}>
                    {result.remainingCents < 0
                      ? t('overBy', { amount: money(-result.remainingCents) })
                      : t('remaining', { amount: money(result.remainingCents) })}
                  </span>
                </p>
                {result.period === 'yearly' && result.elapsedMonths !== null ? (
                  <p className="cell-note">
                    {t(result.crossesYear ? 'yearWindowCross' : 'yearWindow', {
                      year: result.window.to.slice(0, 4),
                      months:
                        result.window.from === result.window.to
                          ? monthName(result.window.to)
                          : t('monthSpan', { from: monthName(result.window.from), to: monthName(result.window.to) }),
                      elapsed: result.elapsedMonths,
                    })}
                  </p>
                ) : null}

                <BudgetHints
                  items={[
                    ...result.divergentChildren.map((child) =>
                      child.group
                        ? t('hints.divergent', { category: shortName(child.categoryId), group: tBudgets(`groups.${child.group}`) })
                        : t('hints.divergentNone', { category: shortName(child.categoryId) }),
                    ),
                    parent && result.exceedsParent
                      ? t('hints.exceedsParent', {
                          category: shortName(parent.categoryId),
                          amount: t(`perPeriod.${parent.period}`, { amount: money(parent.amountCents) }),
                        })
                      : null,
                    result.childrenExceedCents !== null
                      ? t('hints.childrenExceed', {
                          amount: t(`perPeriod.${result.period}`, { amount: money(result.childrenExceedCents) }),
                        })
                      : null,
                    parent ? t('hints.notInGroupSum', { category: shortName(parent.categoryId) }) : null,
                  ]}
                />

                {!readOnly ? (
                  <Link
                    href={`/dashboard/budgets/${result.id}`}
                    className="category-budget-edit"
                    aria-label={t('editLabel', { category: name })}
                  >
                    {t('edit')}
                  </Link>
                ) : null}
              </li>
            );
          })}
        </ul>
      )}
    </section>
  );
}

function BudgetHints({ items }: { items: (string | null)[] }) {
  const hints = items.filter((item): item is string => item !== null);
  if (hints.length === 0) {
    return null;
  }
  return (
    <ul className="category-budget-hints">
      {hints.map((hint) => (
        <li key={hint}>{hint}</li>
      ))}
    </ul>
  );
}
