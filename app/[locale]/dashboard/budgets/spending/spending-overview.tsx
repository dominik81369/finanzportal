/**
 * Inhalt des Ausgaben-Dashboards (gestreamt; Fallback: SpendingSkeleton) –
 * für die eigene Seite und die Leseansicht des Beraters (readOnly: keine
 * Links auf Seiten des Mandanten, alle Währungen untereinander).
 *
 * Kopfzahlen (Ausgaben, Einnahmen, Saldo, Gespart/getilgt) mit Vergleich,
 * Hinweise, Verlauf, Kategorien mit Unterkategorien, Top-Gegenparteien und
 * größte Buchungen. Daten: public.spending_report() für den ausgewerteten
 * Zeitraum (mit Details) und den Vergleichszeitraum; Auswertung in
 * lib/spending.ts.
 */
import { getFormatter, getTranslations } from 'next-intl/server';
import type { CSSProperties } from 'react';

import { Link } from '@/i18n/navigation';
import {
  bucketSeries,
  categoryTree,
  changeOf,
  figuresOf,
  hintsOf,
  perDay,
  pickCurrency,
  reportCurrencies,
  toCents,
  type CategoryRow,
  type Change,
  type SpendingCategoryInfo,
  type SpendingReport,
} from '@/lib/spending';
import { dayCount, periodQuery, type SpendingPeriod } from '@/lib/spending-period';

import { SpendingChart } from './spending-chart';
import { hasTransactions, loadSpendingCategories, loadSpendingReport } from './spending-data';

const SPENDING_PATH = '/dashboard/budgets/spending';

type SpendingOverviewProps = {
  userId: string;
  period: SpendingPeriod;
  /** Gewünschte Währung (?currency=); sonst EUR bzw. die erste vorhandene. */
  currency: string | null;
  readOnly?: boolean;
};

export async function SpendingOverview({ userId, period, currency, readOnly = false }: SpendingOverviewProps) {
  const t = await getTranslations('Spending');
  const [report, compare, categories, anyTransactions] = await Promise.all([
    loadSpendingReport(userId, period.evaluated, period.bucket, true),
    loadSpendingReport(userId, period.compare, period.bucket, false),
    loadSpendingCategories(userId),
    hasTransactions(userId),
  ]);
  if (!report || !categories) {
    return (
      <p role="alert" className="form-error">
        {t('loadError')}
      </p>
    );
  }
  if (!anyTransactions) {
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

  const currencies = reportCurrencies(report);
  const selected = pickCurrency(currencies, currency);
  if (!selected) {
    return <p className="empty-state">{t('empty')}</p>;
  }
  const shown = readOnly ? currencies : [selected];

  return (
    <>
      {!readOnly && currencies.length > 1 ? (
        <nav className="spending-currencies" aria-label={t('currency')}>
          <ul>
            {currencies.map((code) => (
              <li key={code}>
                <Link
                  href={`${SPENDING_PATH}?${periodQuery(period.type, period.range, { compare: period.compareMode, currency: code })}`}
                  aria-current={code === selected ? 'page' : undefined}
                >
                  {code}
                </Link>
              </li>
            ))}
          </ul>
        </nav>
      ) : null}
      {shown.map((code) => (
        <CurrencySpending
          key={code}
          currency={code}
          report={report}
          compare={compare}
          categories={categories}
          period={period}
          readOnly={readOnly}
          headed={readOnly && shown.length > 1}
        />
      ))}
      <p className="hint spending-rules">{t('info.rules')}</p>
    </>
  );
}

async function CurrencySpending({
  currency,
  report,
  compare,
  categories,
  period,
  readOnly,
  headed,
}: {
  currency: string;
  report: SpendingReport;
  compare: SpendingReport | null;
  categories: SpendingCategoryInfo[];
  period: SpendingPeriod;
  readOnly: boolean;
  /** Überschrift mit der Währung (mehrere Blöcke untereinander). */
  headed: boolean;
}) {
  const t = await getTranslations('Spending');
  const format = await getFormatter();
  const money = (cents: number) => format.number(cents / 100, { style: 'currency', currency });
  const date = (value: string) =>
    format.dateTime(new Date(`${value}T00:00:00Z`), { day: '2-digit', month: '2-digit', year: 'numeric', timeZone: 'UTC' });
  const percent = (value: number) => format.number(value / 100, { style: 'percent', maximumFractionDigits: 0 });

  const figures = figuresOf(report, currency);
  const before = compare ? figuresOf(compare, currency) : null;
  const hints = hintsOf(report, currency);
  const rows = categoryTree(report, compare, currency, categories, {
    uncategorized: t('categories.uncategorized'),
    unknown: t('categories.unknown'),
  });
  const points = bucketSeries(report, compare, currency, period);
  const counterparties = report.counterparties.filter((row) => row.currency === currency);
  const largest = report.largest.filter((row) => row.currency === currency);
  const labels = new Map(categories.map((category) => [category.id, category.label]));
  const compareLabel = t('figures.versus', {
    range: format.dateTimeRange(new Date(`${period.compare.from}T00:00:00Z`), new Date(`${period.compare.to}T00:00:00Z`), {
      day: 'numeric',
      month: 'short',
      year: period.compare.from.slice(0, 4) === period.evaluated.from.slice(0, 4) ? undefined : 'numeric',
      timeZone: 'UTC',
    }),
  });
  const { from, to } = period.evaluated;
  const transactionsHref = (params: Record<string, string>) =>
    `/dashboard/transactions?${new URLSearchParams({ ...params, from, to }).toString()}`;

  /** Veränderung als Text; good: ob ein Anstieg gut ist (Farbe nur zusätzlich zum Pfeil). */
  const delta = (change: Change, good: 'up' | 'down', kind: 'pct' | 'amount' = 'pct') => {
    if (change.delta === 0) {
      return <span className="spending-delta">{t('change.same')}</span>;
    }
    if (kind === 'pct' && change.pct === null) {
      return <span className="spending-delta">{t('change.new')}</span>;
    }
    const value = kind === 'pct' ? percent(Math.abs(change.pct!)) : money(Math.abs(change.delta));
    const up = change.delta > 0;
    const tone = up === (good === 'up') ? 'spending-delta-good' : 'spending-delta-bad';
    return <span className={`spending-delta ${tone}`}>{t(up ? 'change.up' : 'change.down', { value })}</span>;
  };

  const hasCounted = figures.expenses !== 0 || figures.income !== 0 || figures.saved !== 0;
  const headingId = `spending-${currency}`;

  return (
    <section className="spending-currency" aria-labelledby={headed ? headingId : undefined} data-currency={currency}>
      {headed ? <h3 id={headingId}>{currency}</h3> : null}

      <dl className="spending-figures" aria-label={t('figures.heading')}>
        <div data-figure="expenses">
          <dt>{t('figures.expenses')}</dt>
          <dd className="spending-figure-value">{money(figures.expenses)}</dd>
          {before ? (
            <dd className="spending-figure-note">
              {delta(changeOf(figures.expenses, before.expenses), 'down')} {compareLabel}
            </dd>
          ) : null}
          <dd className="spending-figure-note">
            {t('figures.perDay', { amount: money(perDay(figures.expenses, dayCount(period.evaluated))) })}
          </dd>
        </div>
        <div data-figure="income">
          <dt>{t('figures.income')}</dt>
          <dd className="spending-figure-value">{money(figures.income)}</dd>
          {before ? (
            <dd className="spending-figure-note">
              {delta(changeOf(figures.income, before.income), 'up')} {compareLabel}
            </dd>
          ) : null}
        </div>
        <div data-figure="balance">
          <dt>{t('figures.balance')}</dt>
          <dd className="spending-figure-value">
            {format.number(figures.balance / 100, { style: 'currency', currency, signDisplay: 'exceptZero' })}
          </dd>
          {before ? (
            <dd className="spending-figure-note">
              {delta(changeOf(figures.balance, before.balance), 'up', 'amount')} {compareLabel}
            </dd>
          ) : null}
        </div>
        <div data-figure="saved">
          <dt>{t('figures.saved')}</dt>
          <dd className="spending-figure-value">{money(figures.saved)}</dd>
          {before ? (
            <dd className="spending-figure-note">
              {delta(changeOf(figures.saved, before.saved), 'up')} {compareLabel}
            </dd>
          ) : null}
          <dd className="spending-figure-note">{t('figures.savedNote')}</dd>
        </div>
      </dl>

      {hints.flagged || hints.sameHolder ? (
        <ul className="spending-hints" aria-label={t('hints.heading')}>
          {hints.flagged ? (
            <li className="spending-hint" data-hint="flagged">
              {t('hints.flagged', {
                count: hints.flagged.count,
                expenses: money(hints.flagged.expenses),
                income: money(hints.flagged.income),
              })}
              {readOnly ? null : (
                <>
                  {' '}
                  <Link href="/dashboard/transactions/groups">{t('hints.flaggedLink')}</Link>
                </>
              )}
            </li>
          ) : null}
          {hints.sameHolder ? (
            <li className="spending-hint" data-hint="same-holder">
              {t(readOnly ? 'hints.sameHolderAdvisor' : 'hints.sameHolder', {
                count: hints.sameHolder.count,
                ibans: hints.sameHolder.ibans,
                outflow: money(hints.sameHolder.outflow),
                inflow: money(hints.sameHolder.inflow),
              })}
              {readOnly ? null : (
                <>
                  {' '}
                  <Link href="/dashboard/transactions/rules#rule-own-heading">{t('hints.sameHolderLink')}</Link>
                </>
              )}
            </li>
          ) : null}
        </ul>
      ) : null}

      {!hasCounted ? (
        <p className="empty-state">{t('empty')}</p>
      ) : (
        <>
          <SpendingChart points={points} bucket={period.bucket} currency={currency} hasCompare={compare !== null} />

          <div className="spending-columns">
            <section className="spending-panel" aria-labelledby={`${headingId}-categories`}>
              <h3 id={`${headingId}-categories`}>{t('categories.heading')}</h3>
              {rows.length === 0 ? (
                <p className="empty-state">{t('categories.empty')}</p>
              ) : (
                <ul className="spending-categories">
                  {rows.map((row) => (
                    <li key={row.categoryId ?? 'none'} data-category={row.categoryId ?? 'none'}>
                      {row.children.length > 0 ? (
                        <details>
                          <summary>
                            <CategoryLine row={row} />
                          </summary>
                          <ul className="spending-subcategories">
                            {row.children.map((child) => (
                              <li key={child.categoryId} data-category={child.categoryId}>
                                <CategoryLine row={child} />
                              </li>
                            ))}
                          </ul>
                        </details>
                      ) : (
                        <CategoryLine row={row} />
                      )}
                    </li>
                  ))}
                </ul>
              )}
            </section>

            <div className="spending-side">
              <section className="spending-panel" aria-labelledby={`${headingId}-counterparties`}>
                <h3 id={`${headingId}-counterparties`}>{t('counterparties.heading')}</h3>
                {counterparties.length === 0 ? (
                  <p className="empty-state">{t('counterparties.empty')}</p>
                ) : (
                  <ol className="spending-list">
                    {counterparties.map((row) => {
                      const name = row.label ?? t('counterparties.unnamed');
                      return (
                        <li key={row.counterparty_key}>
                          <span className="spending-list-label">
                            {readOnly ? (
                              name
                            ) : (
                              <Link
                                href={transactionsHref({ counterparty: row.counterparty_key })}
                                aria-label={t('counterparties.transactionsLabel', { name })}
                              >
                                {name}
                              </Link>
                            )}
                          </span>
                          <span className="spending-list-meta">{t('counterparties.count', { count: row.count })}</span>
                          <span className="spending-list-amount">{money(toCents(row.expenses))}</span>
                        </li>
                      );
                    })}
                  </ol>
                )}
              </section>

              <section className="spending-panel" aria-labelledby={`${headingId}-largest`}>
                <h3 id={`${headingId}-largest`}>{t('largest.heading')}</h3>
                {largest.length === 0 ? (
                  <p className="empty-state">{t('largest.empty')}</p>
                ) : (
                  <ol className="spending-list">
                    {largest.map((row) => {
                      const name = row.counterparty ?? row.purpose ?? t('counterparties.unnamed');
                      return (
                        <li key={row.id}>
                          <span className="spending-list-meta">{date(row.booking_date)}</span>
                          <span className="spending-list-label">
                            {readOnly ? (
                              name
                            ) : (
                              <Link
                                href={`/dashboard/transactions/${row.id}/edit`}
                                aria-label={t('largest.editLabel', { date: date(row.booking_date) })}
                              >
                                {name}
                              </Link>
                            )}
                            {row.category_id && labels.has(row.category_id) ? (
                              <span className="cell-note">{labels.get(row.category_id)}</span>
                            ) : null}
                          </span>
                          <span className="spending-list-amount">{money(-toCents(row.amount))}</span>
                        </li>
                      );
                    })}
                  </ol>
                )}
              </section>
            </div>
          </div>
        </>
      )}

      {hints.transfers || figures.refunds > 0 ? (
        <ul className="hint spending-info">
          {hints.transfers ? (
            <li>
              {t('info.transfers', { outflow: money(hints.transfers.outflow), inflow: money(hints.transfers.inflow) })}
            </li>
          ) : null}
          {figures.refunds > 0 ? <li>{t('info.refunds', { amount: money(figures.refunds) })}</li> : null}
        </ul>
      ) : null}
    </section>
  );

  /** Eine Kategorie: Name (Link in die Transaktionsliste), Betrag, Anteil, Veränderung. */
  function CategoryLine({ row }: { row: CategoryRow }) {
    const share = row.share === null ? null : Math.min(Math.max(row.share, 0), 100);
    return (
      <span className="spending-category">
        <span className="spending-category-name">
          {readOnly ? (
            row.label
          ) : (
            <Link
              href={transactionsHref({ category: row.categoryId ?? 'none' })}
              aria-label={t('categories.transactionsLabel', { name: row.label })}
            >
              {row.label}
            </Link>
          )}
          {row.children.length > 0 ? (
            <span className="cell-note">{t('categories.subcategories', { count: row.children.length })}</span>
          ) : null}
        </span>
        <span className="spending-category-amount">{money(row.cents)}</span>
        <span className="spending-category-share">{row.share === null ? '–' : percent(row.share)}</span>
        <span className="spending-category-change">
          {compare ? delta(changeOf(row.cents, row.compareCents), 'down') : null}
        </span>
        {share !== null ? (
          // Breite als CSS-Variable; Farbe und Maße aus den Tokens.
          <span className="spending-share-bar" aria-hidden="true" style={{ '--spending-share': `${share.toFixed(1)}%` } as CSSProperties}>
            <span />
          </span>
        ) : null}
      </span>
    );
  }
}
