/**
 * app/[locale]/dashboard/budgets/page.tsx
 *
 * Budget-Abgleich nach der 50/30/20-Regel: tatsächliche Ausgaben je Gruppe
 * (Needs / Wants / Savings) in Prozent des Einkommens gegen das Ziel, für
 * einen Monat oder Zeitraum (?from=YYYY-MM&to=YYYY-MM).
 *
 * Daten: public.budget_rule_summary() – je Monat und Buchungswährung, über
 * alle Buchungen (manuell, importiert, synchronisiert). Zusammenfassung und
 * Anteile je Währung in lib/budget-rule.ts; Währungen werden nie vermischt.
 * Darunter die Zuordnung der Kategorien (./budget-group-form.tsx).
 *
 * Abfragen filtern ausdrücklich auf den eigenen Nutzer: RLS gibt Beratern
 * zusätzlich die Daten ihrer Mandanten frei.
 */
import type { Metadata } from 'next';
import { getFormatter, getMessages, getTranslations } from 'next-intl/server';

import { Link } from '@/i18n/navigation';
import { toAppLocale } from '@/i18n/routing';
import {
  BUDGET_GROUPS,
  BUDGET_TARGETS,
  addMonths,
  monthCount,
  parseMonthRange,
  rangeDates,
  summarizeByCurrency,
  type BudgetGroupKey,
  type CurrencySummary,
  type MonthKey,
  type MonthRange,
} from '@/lib/budget-rule';
import { categoryDisplayName } from '@/lib/categories';
import { createClient, requireOnboardedUser } from '@/lib/supabase/server';
import { todayInGermany } from '@/lib/transactions';

import { BudgetGroupForm, type BudgetGroupFormCategory } from './budget-group-form';

type BudgetsPageProps = {
  params: Promise<{ locale: string }>;
  searchParams: Promise<Record<string, string | string[] | undefined>>;
};

export async function generateMetadata({
  params,
}: Pick<BudgetsPageProps, 'params'>): Promise<Metadata> {
  const locale = toAppLocale((await params).locale);
  const t = await getTranslations({ locale, namespace: 'Dashboard' });
  return { title: t('budgets.title') };
}

const rangeHref = (range: MonthRange) => `/dashboard/budgets?from=${range.from}&to=${range.to}`;

export default async function BudgetsPage({ searchParams }: BudgetsPageProps) {
  const user = await requireOnboardedUser('/dashboard/budgets');
  const t = await getTranslations('Budgets');
  const tDashboard = await getTranslations('Dashboard');
  const tCategories = await getTranslations('DefaultCategories');
  const format = await getFormatter();

  const currentMonth = todayInGermany().slice(0, 7);
  const range = parseMonthRange(await searchParams, currentMonth);
  const { fromDate, toDate } = rangeDates(range);
  const monthLabel = (month: MonthKey) =>
    format.dateTime(new Date(`${month}-01T00:00:00Z`), { month: 'long', year: 'numeric', timeZone: 'UTC' });

  const supabase = await createClient();
  const [summary, categories] = await Promise.all([
    supabase.rpc('budget_rule_summary', { p_user_id: user.id, p_from: fromDate, p_to: toDate }),
    supabase
      .from('categories')
      .select('id, name, default_key, kind, parent_category_id, sort_order, budget_group')
      .eq('user_id', user.id)
      .neq('kind', 'income')
      .order('sort_order')
      .order('name'),
  ]);
  if (summary.error) {
    console.error('[budgets] Auswertung nicht ladbar', { code: summary.error.code });
  }
  if (categories.error) {
    console.error('[budgets] Kategorien nicht ladbar', { code: categories.error.code });
  }
  const currencies = summarizeByCurrency(summary.data ?? []);

  // Oberkategorien in Sortierung, Unterkategorien jeweils direkt darunter.
  const formCategories: BudgetGroupFormCategory[] = [];
  const all = categories.data ?? [];
  const ids = new Set(all.map((c) => c.id));
  const toFormCategory = (c: (typeof all)[number], isChild: boolean) => ({
    id: c.id,
    label: categoryDisplayName(c, tCategories),
    isChild,
    group: c.budget_group,
  });
  for (const parent of all.filter((c) => !c.parent_category_id || !ids.has(c.parent_category_id))) {
    formCategories.push(toFormCategory(parent, false));
    for (const child of all.filter((c) => c.parent_category_id === parent.id)) {
      formCategories.push(toFormCategory(child, true));
    }
  }

  const presets: { key: 'thisMonth' | 'lastMonth' | 'last3Months' | 'thisYear'; range: MonthRange }[] = [
    { key: 'thisMonth', range: { from: currentMonth, to: currentMonth } },
    { key: 'lastMonth', range: { from: addMonths(currentMonth, -1), to: addMonths(currentMonth, -1) } },
    { key: 'last3Months', range: { from: addMonths(currentMonth, -2), to: currentMonth } },
    { key: 'thisYear', range: { from: `${currentMonth.slice(0, 4)}-01`, to: currentMonth } },
  ];
  const planned = Object.values((await getMessages()).Dashboard.budgets.planned);

  return (
    <section aria-labelledby="page-title" className="budgets-page">
      <h1 id="page-title">{tDashboard('budgets.title')}</h1>
      <p>{tDashboard('budgets.description')}</p>

      <form method="get" className="filters budget-period" aria-label={t('period.label')}>
        <div className="filter-field">
          <label htmlFor="budget-from">{t('period.from')}</label>
          <input id="budget-from" name="from" type="month" defaultValue={range.from} required />
        </div>
        <div className="filter-field">
          <label htmlFor="budget-to">{t('period.to')}</label>
          <input id="budget-to" name="to" type="month" defaultValue={range.to} required />
        </div>
        <div className="filter-actions">
          <button type="submit" className="button">
            {t('period.apply')}
          </button>
        </div>
        <ul className="budget-presets">
          {presets.map((preset) => {
            const active = preset.range.from === range.from && preset.range.to === range.to;
            return (
              <li key={preset.key}>
                <Link href={rangeHref(preset.range)} aria-current={active ? 'true' : undefined}>
                  {t(`period.presets.${preset.key}`)}
                </Link>
              </li>
            );
          })}
        </ul>
      </form>

      <p className="result-count" id="budget-range">
        {monthCount(range) === 1
          ? t('period.single', { month: monthLabel(range.from) })
          : t('period.range', { from: monthLabel(range.from), to: monthLabel(range.to), count: monthCount(range) })}
      </p>

      {summary.error ? (
        <p role="alert" className="form-error">
          {t('loadError')}
        </p>
      ) : currencies.length === 0 ? (
        <p className="empty-state">{t('empty')}</p>
      ) : (
        currencies.map((currency) => (
          <CurrencyBlock
            key={currency.currency}
            summary={currency}
            multiMonth={monthCount(range) > 1}
            monthLabel={monthLabel}
          />
        ))
      )}

      <p className="hint budget-rules">{t('rules')}</p>

      <section className="advisor-section" aria-labelledby="assignment-heading">
        <h2 id="assignment-heading">{t('assignment.heading')}</h2>
        <p>{t('assignment.intro')}</p>
        {categories.error ? (
          <p role="alert" className="form-error">
            {t('assignment.loadError')}
          </p>
        ) : (
          <BudgetGroupForm categories={formCategories} />
        )}
      </section>

      <div className="placeholder-box">
        <p className="placeholder-label">{tDashboard('placeholderLabel')}</p>
        <ul>
          {planned.map((item) => (
            <li key={item}>{item}</li>
          ))}
        </ul>
      </div>
    </section>
  );
}

async function CurrencyBlock({
  summary,
  multiMonth,
  monthLabel,
}: {
  summary: CurrencySummary;
  multiMonth: boolean;
  monthLabel: (month: MonthKey) => string;
}) {
  const t = await getTranslations('Budgets');
  const format = await getFormatter();
  const { currency, totals, shares } = summary;
  const money = (value: number) => format.number(value, { style: 'currency', currency });
  const percent = (value: number | null) =>
    value === null ? '–' : format.number(value / 100, { style: 'percent', maximumFractionDigits: 1 });
  const hasIncome = totals.income > 0;
  const headingId = `budget-${currency}`;

  return (
    <section className="budget-currency" aria-labelledby={headingId}>
      <h2 id={headingId}>{t('currencyHeading', { currency })}</h2>
      <p className="budget-income">
        {t('income')}: <strong>{money(totals.income)}</strong>
      </p>
      {!hasIncome ? <p className="hint">{t('noIncome')}</p> : null}

      <div className="table-scroll">
        <table className="budget-table">
          <caption>{t('caption', { currency })}</caption>
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
            </tr>
          </thead>
          <tbody>
            {BUDGET_GROUPS.map((group: BudgetGroupKey) => {
              const share = shares[group];
              const target = BUDGET_TARGETS[group];
              return (
                <tr key={group} data-group={group}>
                  <th scope="row">
                    {t(`groups.${group}`)}
                    {share !== null ? (
                      <span className="budget-bar" aria-hidden="true">
                        <span
                          className={`budget-bar-fill budget-bar-${group}`}
                          style={{ width: `${Math.min(Math.max(share, 0), 100)}%` }}
                        />
                        <span className="budget-bar-target" style={{ left: `${target}%` }} />
                      </span>
                    ) : null}
                  </th>
                  <td className="amount">{money(totals[group])}</td>
                  <td className="amount">{percent(share)}</td>
                  <td className="amount">{percent(target)}</td>
                  <td className="amount">{hasIncome ? money((totals.income * target) / 100) : '–'}</td>
                </tr>
              );
            })}
            <tr data-group="unassigned">
              <th scope="row">{t('unassigned')}</th>
              <td className="amount">{money(totals.unassigned)}</td>
              <td className="amount">{percent(shares.unassigned)}</td>
              <td className="amount">–</td>
              <td className="amount">–</td>
            </tr>
          </tbody>
          <tfoot>
            <tr data-group="remaining">
              <th scope="row">{t('remaining')}</th>
              <td className={`amount ${summary.remaining < 0 ? 'amount-negative' : ''}`}>
                {money(summary.remaining)}
              </td>
              <td className="amount">{percent(hasIncome ? (summary.remaining / totals.income) * 100 : null)}</td>
              <td className="amount">–</td>
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
                  {t('income')}
                </th>
                {BUDGET_GROUPS.map((group) => (
                  <th key={group} scope="col" className="amount">
                    {t(`groups.${group}`)}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {summary.months.map((month) => (
                <tr key={month.month}>
                  <th scope="row">{monthLabel(month.month)}</th>
                  <td className="amount">{money(month.totals.income)}</td>
                  {BUDGET_GROUPS.map((group) => (
                    <td key={group} className="amount">
                      {money(month.totals[group])}
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
