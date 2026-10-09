/**
 * Auswertung 50/30/20 und Einzelbudgets (gestreamt; Fallback:
 * BudgetSkeleton) – für die eigene Budgetseite und die Leseansicht des
 * Beraters (readOnly).
 *
 * Daten: public.budget_category_totals() ab drei Monaten vor dem Zeitraum
 * (Durchschnitt der Vormonate) bzw. ab Januar im Jahr des Zeitraumendes
 * (Jahresbudgets); Auswertung in lib/budget-rule.ts und
 * lib/category-budgets.ts. Die Spalte „Budget (Summe)“ zeigt die
 * Einzelbudgets je Gruppe, umgerechnet auf den Zeitraum. Alle Abfragen
 * filtern ausdrücklich auf user_id = userId (RLS gibt Beratern zusätzlich
 * die Daten ihrer Mandanten frei).
 */
import { getFormatter, getTranslations } from 'next-intl/server';
import type { CSSProperties } from 'react';

import { Link } from '@/i18n/navigation';
import {
  BUDGET_GROUPS,
  addMonths,
  monthCount,
  summarizeBudget,
  type BudgetBasis,
  type BudgetGroupKey,
  type BudgetSettings,
  type CurrencyBudget,
  type MonthKey,
  type MonthRange,
} from '@/lib/budget-rule';
import {
  evaluateCategoryBudgets,
  evaluationStart,
  groupBudgetSums,
  type GroupBudgetSum,
} from '@/lib/category-budgets';
import { createClient } from '@/lib/supabase/server';

import { loadBudgetCategories, loadCategoryBudgets, loadCategoryTotals } from './budget-data';
import { CategoryBudgetList } from './category-budget-list';

type BudgetOverviewProps = {
  userId: string;
  range: MonthRange;
  basis: BudgetBasis;
  settings: BudgetSettings;
  /** Leseansicht (Berater): keine Links auf eigene Seiten des Mandanten. */
  readOnly?: boolean;
};

export async function BudgetOverview({ userId, range, basis, settings, readOnly = false }: BudgetOverviewProps) {
  const t = await getTranslations('Budgets');
  const format = await getFormatter();
  const supabase = await createClient();

  // Vormonate (Bezugsgröße Durchschnitt) und Januar (Jahresbudgets) – der frühere Monat zählt.
  const fetchFrom = [addMonths(range.from, -3), evaluationStart(range)].sort()[0]!;
  const [totals, transactionCount, categories, budgets] = await Promise.all([
    loadCategoryTotals(userId, { from: fetchFrom, to: range.to }),
    supabase.from('transactions').select('id', { count: 'exact', head: true }).eq('user_id', userId),
    loadBudgetCategories(userId),
    loadCategoryBudgets(userId),
  ]);
  if (!totals) {
    return (
      <p role="alert" className="form-error">
        {t('loadError')}
      </p>
    );
  }

  const results = categories && budgets ? evaluateCategoryBudgets(budgets, categories, totals, range) : null;
  const budgetList = (
    <CategoryBudgetList results={results} categories={categories ?? []} months={monthCount(range)} readOnly={readOnly} />
  );

  if ((transactionCount.count ?? 0) === 0) {
    return (
      <>
        {readOnly ? (
          <p className="empty-state">{t('advisor.noTransactions')}</p>
        ) : (
          <div className="budget-empty">
            <strong>{t('noTransactions.title')}</strong>
            <p>{t('noTransactions.text')}</p>
            <Link href="/dashboard/transactions/import" className="button button-small">
              {t('noTransactions.import')}
            </Link>
          </div>
        )}
        {budgetList}
      </>
    );
  }

  const currencies = summarizeBudget(totals, { range, basis, settings });
  const sums = results ? groupBudgetSums(results) : new Map<string, Partial<Record<BudgetGroupKey, GroupBudgetSum>>>();
  const monthLabel = (month: MonthKey) =>
    format.dateTime(new Date(`${month}-01T00:00:00Z`), { month: 'long', year: 'numeric', timeZone: 'UTC' });

  return (
    <>
      {currencies.length === 0 ? <p className="empty-state">{t('empty')}</p> : null}
      {currencies.map((currency) => (
        <CurrencyBlock
          key={currency.currency}
          budget={currency}
          budgetSums={sums.get(currency.currency) ?? {}}
          settings={settings}
          multiMonth={monthCount(range) > 1}
          monthLabel={monthLabel}
          readOnly={readOnly}
        />
      ))}
      {budgetList}
    </>
  );
}

async function CurrencyBlock({
  budget,
  budgetSums,
  settings,
  multiMonth,
  monthLabel,
  readOnly,
}: {
  budget: CurrencyBudget;
  /** Einzelbudgets je Gruppe in dieser Währung (Cent, auf den Zeitraum umgerechnet). */
  budgetSums: Partial<Record<BudgetGroupKey, GroupBudgetSum>>;
  settings: BudgetSettings;
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
  const basisAmount = budget.basis.amount;
  const totalDeviation = basisAmount === null ? null : Math.round((figures.expenses - basisAmount) * 100) / 100;
  const targetsLabel = BUDGET_GROUPS.map((group) => format.number(settings.targets[group])).join('/');
  const fallback = budget.basis.fallback;
  // Spalte „Budget (Summe)“ nur, wenn es in dieser Währung Einzelbudgets gibt.
  const sumList = BUDGET_GROUPS.map((group) => budgetSums[group]).filter((sum) => sum !== undefined);
  const showBudgets = sumList.length > 0;
  const budgetTotal = sumList.reduce((total, sum) => total + sum.cents, 0);
  const extraColumns = showBudgets ? 5 : 4;
  const budgetCell = (sum: GroupBudgetSum | undefined) =>
    showBudgets ? (
      <td className="amount">
        {sum ? (
          <>
            {money(sum.cents / 100)}
            <span className="cell-note">{t('budgetCount', { count: sum.count })}</span>
          </>
        ) : (
          '–'
        )}
      </td>
    ) : null;

  const subRow = (key: string, label: string, value: number) =>
    value !== 0 ? (
      <tr key={key} className="budget-subrow">
        <th scope="row">{label}</th>
        <td className="amount">{money(value)}</td>
        <td colSpan={extraColumns} />
      </tr>
    ) : null;

  return (
    <section className="budget-currency" aria-labelledby={headingId}>
      <h2 id={headingId}>{t('currencyHeading', { currency })}</h2>
      <dl className="budget-summary">
        <div>
          <dt>{t('income')}</dt>
          <dd>{money(figures.income)}</dd>
        </div>
        <div>
          <dt>{t('totalExpenses')}</dt>
          <dd>{money(figures.expenses)}</dd>
        </div>
        <div>
          <dt>{t('basisAmount', { basis: t(`basis.options.${budget.basis.used}`) })}</dt>
          <dd>{basisAmount === null ? '–' : money(basisAmount)}</dd>
        </div>
      </dl>
      {fallback ? (
        <p className="hint budget-fallback">
          {t(`basis.fallback.${fallback}`, { currency: settings.fixedCurrency })}
          {fallback === 'fixedMissing' && !readOnly ? (
            <>
              {' '}
              <a href="#budget-settings">{t('basis.toSettings')}</a>
            </>
          ) : null}
        </p>
      ) : null}
      {basisAmount === null ? (
        <p className="hint">{t(budget.basis.used === 'income' ? 'basis.noBasis.income' : 'basis.noBasis.expenses')}</p>
      ) : null}

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
              {showBudgets ? (
                <th scope="col" className="amount">
                  {t('columns.budgetSum')}
                </th>
              ) : null}
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
                  {budgetCell(budgetSums[group])}
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
              {showBudgets ? <td className="amount">–</td> : null}
            </tr>
          </tbody>
          <tfoot>
            <tr data-group="expenses">
              <th scope="row">{t('totalExpenses')}</th>
              <td className="amount">{money(figures.expenses)}</td>
              <td className="amount">
                {percent(basisAmount === null ? null : (figures.expenses / basisAmount) * 100)}
              </td>
              <td className="amount">{percent(100)}</td>
              <td className="amount">{basisAmount === null ? '–' : money(basisAmount)}</td>
              <td className={`amount ${totalDeviation !== null && totalDeviation > 0 ? 'budget-over' : ''}`}>
                {totalDeviation === null ? '–' : signed(totalDeviation)}
              </td>
              {showBudgets ? <td className="amount">{money(budgetTotal / 100)}</td> : null}
            </tr>
            <tr data-group="not-captured">
              <th scope="row">{t('notCaptured')}</th>
              <td className={`amount ${figures.notCaptured < 0 ? 'budget-over' : ''}`}>{money(figures.notCaptured)}</td>
              <td colSpan={extraColumns} />
            </tr>
            {figures.ownTransfers !== 0 ? (
              <tr className="budget-subrow" data-group="own-transfers">
                <th scope="row">{t('sub.ownTransfers')}</th>
                <td className="amount">{money(figures.ownTransfers)}</td>
                <td colSpan={extraColumns} />
              </tr>
            ) : null}
          </tfoot>
        </table>
      </div>
      <p className="hint budget-footnote">
        {t('notCapturedHint')} {t('netIncomeHint')}
      </p>

      {multiMonth ? (
        <div className="table-scroll budget-months">
          <table className="budget-table">
            <caption>{t('monthsCaption', { currency })}</caption>
            <thead>
              <tr>
                <th scope="col">{t('columns.month')}</th>
                <th scope="col" className="amount">
                  {t('income')}
                </th>
                <th scope="col" className="amount">
                  {t('totalExpenses')}
                </th>
                {BUDGET_GROUPS.map((group) => (
                  <th key={group} scope="col" className="amount">
                    {t(`groups.${group}`)}
                  </th>
                ))}
                <th scope="col" className="amount">
                  {t('notCaptured')}
                </th>
              </tr>
            </thead>
            <tbody>
              {budget.months.map((month) => (
                <tr key={month.month}>
                  <th scope="row">{monthLabel(month.month)}</th>
                  <td className="amount">{money(month.figures.income)}</td>
                  <td className="amount">{money(month.figures.expenses)}</td>
                  {BUDGET_GROUPS.map((group) => (
                    <td key={group} className="amount">
                      {money(month.figures.groups[group].actual)}
                      <span className="cell-note">{percent(month.shares[group])}</span>
                    </td>
                  ))}
                  <td className={`amount ${month.figures.notCaptured < 0 ? 'budget-over' : ''}`}>
                    {money(month.figures.notCaptured)}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      ) : null}
    </section>
  );
}
