/**
 * Auswertung 50/30/20 (gestreamt; Fallback: BudgetSkeleton) – für die
 * eigene Seite und die Leseansicht des Beraters (readOnly).
 *
 * Feste Regel: Zielbeträge = 50/30/20 % der Gesamtausgaben des Zeitraums
 * (lib/budget-rule.ts). Daten aus public.budget_category_totals(); die
 * Abfrage filtert ausdrücklich auf user_id = userId (RLS gibt Beratern
 * zusätzlich die Daten ihrer Mandanten frei).
 */
import { getFormatter, getTranslations } from 'next-intl/server';
import type { CSSProperties } from 'react';

import { Link } from '@/i18n/navigation';
import {
  BUDGET_GROUPS,
  BUDGET_TARGETS,
  monthCount,
  summarizeBudget,
  type BudgetGroupKey,
  type CurrencyBudget,
  type MonthKey,
  type MonthRange,
} from '@/lib/budget-rule';
import { createClient } from '@/lib/supabase/server';

import { loadCategoryTotals } from './budget-data';

type BudgetOverviewProps = {
  userId: string;
  range: MonthRange;
  /** Leseansicht (Berater): keine Links auf eigene Seiten des Mandanten. */
  readOnly?: boolean;
};

export async function BudgetOverview({ userId, range, readOnly = false }: BudgetOverviewProps) {
  const t = await getTranslations('Budgets');
  const format = await getFormatter();
  const supabase = await createClient();

  const [totals, transactionCount] = await Promise.all([
    loadCategoryTotals(userId, range),
    supabase.from('transactions').select('id', { count: 'exact', head: true }).eq('user_id', userId),
  ]);
  if (!totals) {
    return (
      <p role="alert" className="form-error">
        {t('loadError')}
      </p>
    );
  }

  if ((transactionCount.count ?? 0) === 0) {
    return readOnly ? (
      <p className="empty-state">{t('advisor.noTransactions')}</p>
    ) : (
      <div className="budget-empty">
        <strong>{t('noTransactions.title')}</strong>
        <p>{t('noTransactions.text')}</p>
        <Link href="/dashboard/transactions/import" className="button button-small">
          {t('noTransactions.import')}
        </Link>
      </div>
    );
  }

  const currencies = summarizeBudget(totals, range);
  const monthLabel = (month: MonthKey) =>
    format.dateTime(new Date(`${month}-01T00:00:00Z`), { month: 'long', year: 'numeric', timeZone: 'UTC' });

  return (
    <>
      {currencies.length === 0 ? <p className="empty-state">{t('empty')}</p> : null}
      {currencies.map((currency) => (
        <CurrencyBlock
          key={currency.currency}
          budget={currency}
          multiMonth={monthCount(range) > 1}
          monthLabel={monthLabel}
          readOnly={readOnly}
        />
      ))}
    </>
  );
}

async function CurrencyBlock({
  budget,
  multiMonth,
  monthLabel,
  readOnly,
}: {
  budget: CurrencyBudget;
  multiMonth: boolean;
  monthLabel: (month: MonthKey) => string;
  readOnly: boolean;
}) {
  const t = await getTranslations('Budgets');
  const format = await getFormatter();
  const { currency, figures, groups } = budget;
  const money = (value: number) => format.number(value, { style: 'currency', currency });
  const signed = (value: number) => format.number(value, { style: 'currency', currency, signDisplay: 'exceptZero' });
  const percent = (value: number | null) =>
    value === null ? '–' : format.number(value / 100, { style: 'percent', maximumFractionDigits: 1 });
  const headingId = `budget-${currency}`;
  const targetsLabel = BUDGET_GROUPS.map((group) => format.number(BUDGET_TARGETS[group])).join('/');

  const subRow = (key: string, label: string, value: number) =>
    value !== 0 ? (
      <tr key={key} className="budget-subrow">
        <th scope="row">{label}</th>
        <td className="amount">{money(value)}</td>
        <td colSpan={4} />
      </tr>
    ) : null;

  return (
    <section className="budget-currency" aria-labelledby={headingId}>
      <h2 id={headingId}>{t('currencyHeading', { currency })}</h2>

      <div className="table-scroll">
        <table className="budget-table">
          <caption>{t('caption', { targets: targetsLabel, currency })}</caption>
          <thead>
            <tr>
              <th scope="col">{t('columns.group')}</th>
              <th scope="col" className="amount">
                {t('columns.actual')}
              </th>
              <th scope="col" className="amount">
                {t('columns.share')}
              </th>
              <th scope="col" className="amount">
                {t('columns.target')}
              </th>
              <th scope="col" className="amount">
                {t('columns.targetAmount')}
              </th>
              <th scope="col" className="amount">
                {t('columns.deviation')}
              </th>
            </tr>
          </thead>
          <tbody>
            {BUDGET_GROUPS.map((group: BudgetGroupKey) => {
              const row = groups[group];
              return [
                <tr key={group} data-group={group}>
                  <th scope="row">
                    {t(`groups.${group}`)}
                    {row.share !== null ? (
                      // Breiten als CSS-Variablen; Farben und Maße aus den Tokens.
                      <span className="budget-bar" aria-hidden="true" style={{ '--budget-share': `${Math.min(Math.max(row.share, 0), 100).toFixed(1)}%`, '--budget-target': `${row.targetPct}%` } as CSSProperties}>
                        <span className={`budget-bar-fill budget-bar-${group}`} />
                        <span className="budget-bar-target" />
                      </span>
                    ) : null}
                  </th>
                  <td className="amount">{money(row.actual)}</td>
                  <td className="amount">{percent(row.share)}</td>
                  <td className="amount">{percent(row.targetPct)}</td>
                  <td className="amount">{row.targetAmount === null ? '–' : money(row.targetAmount)}</td>
                  <td className={`amount ${row.deviation !== null && row.deviation > 0 ? 'budget-over' : ''}`}>
                    {row.deviation === null ? '–' : signed(row.deviation)}
                  </td>
                </tr>,
                subRow(`${group}-taxes`, t('sub.taxes'), row.taxes),
                subRow(`${group}-loan`, t('sub.loan'), row.loan),
                group === 'savings' ? subRow(`${group}-own`, t('sub.ownSavings'), row.ownSavings) : null,
              ];
            })}
            <tr data-group="unassigned">
              <th scope="row">
                {t('unassigned')}
                {figures.unassigned > 0 && !readOnly ? (
                  <span className="cell-note">
                    <Link href="/dashboard/transactions/groups">{t('toGroups')}</Link>
                  </span>
                ) : null}
              </th>
              <td className="amount">{money(figures.unassigned)}</td>
              <td className="amount">{percent(budget.unassignedShare)}</td>
              <td className="amount">–</td>
              <td className="amount">–</td>
              <td className="amount">–</td>
            </tr>
          </tbody>
          <tfoot>
            <tr data-group="expenses">
              <th scope="row">{t('totalExpenses')}</th>
              <td className="amount">{money(figures.expenses)}</td>
              <td className="amount">{percent(figures.expenses > 0 ? 100 : null)}</td>
              <td className="amount">{percent(100)}</td>
              <td className="amount">{figures.expenses > 0 ? money(figures.expenses) : '–'}</td>
              <td className="amount">–</td>
            </tr>
          </tfoot>
        </table>
      </div>

      {multiMonth ? (
        <div className="table-scroll budget-months">
          <table className="budget-table">
            <caption>{t('monthsCaption', { currency })}</caption>
            <thead>
              <tr>
                <th scope="col">{t('columns.month')}</th>
                <th scope="col" className="amount">
                  {t('totalExpenses')}
                </th>
                {BUDGET_GROUPS.map((group) => (
                  <th key={group} scope="col" className="amount">
                    {t(`groups.${group}`)}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {budget.months.map((month) => (
                <tr key={month.month}>
                  <th scope="row">{monthLabel(month.month)}</th>
                  <td className="amount">{money(month.figures.expenses)}</td>
                  {BUDGET_GROUPS.map((group) => (
                    <td key={group} className="amount">
                      {money(month.figures.groups[group].actual)}
                      <span className="cell-note">{percent(month.shares[group])}</span>
                    </td>
                  ))}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      ) : null}
    </section>
  );
}
