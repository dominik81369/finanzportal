/**
 * Kachel „Ausgaben diesen Monat“ auf der Übersicht (gestreamt): Ausgaben
 * des laufenden Monats bis heute in EUR (sonst der ersten vorhandenen
 * Währung) mit Veränderung zum gleichen Zeitraum des Vormonats und Link
 * zum Ausgaben-Dashboard.
 */
import { getFormatter, getTranslations } from 'next-intl/server';

import { Link } from '@/i18n/navigation';
import { changeOf, figuresOf, pickCurrency, reportCurrencies } from '@/lib/spending';
import { parseSpendingPeriod } from '@/lib/spending-period';
import { todayInGermany } from '@/lib/transactions';

import { loadSpendingReport } from './budgets/spending/spending-data';

export async function SpendingTile({ userId }: { userId: string }) {
  const t = await getTranslations('Spending');
  const format = await getFormatter();
  const period = parseSpendingPeriod({}, todayInGermany());
  const [report, compare] = await Promise.all([
    loadSpendingReport(userId, period.evaluated, 'month', false),
    loadSpendingReport(userId, period.compare, 'month', false),
  ]);

  const body = (() => {
    if (!report) {
      return (
        <p role="alert" className="form-error">
          {t('tile.loadError')}
        </p>
      );
    }
    const currencies = reportCurrencies(report);
    const currency = pickCurrency(currencies, null);
    if (!currency) {
      return <p className="spending-figure-note">{t('tile.empty')}</p>;
    }
    const money = (cents: number) => format.number(cents / 100, { style: 'currency', currency });
    const expenses = figuresOf(report, currency).expenses;
    const change = compare ? changeOf(expenses, figuresOf(compare, currency).expenses) : null;
    const others = currencies.filter((code) => code !== currency);
    const range = format.dateTimeRange(
      new Date(`${period.compare.from}T00:00:00Z`),
      new Date(`${period.compare.to}T00:00:00Z`),
      { day: 'numeric', month: 'short', timeZone: 'UTC' },
    );
    return (
      <>
        <p className="spending-figure-value" data-currency={currency}>
          {money(expenses)}
        </p>
        {change ? (
          <p className="spending-figure-note">
            {change.delta === 0 ? (
              <span className="spending-delta">{t('change.same')}</span>
            ) : change.pct === null ? (
              <span className="spending-delta">{t('change.new')}</span>
            ) : (
              <span className={`spending-delta ${change.delta > 0 ? 'spending-delta-bad' : 'spending-delta-good'}`}>
                {t(change.delta > 0 ? 'change.up' : 'change.down', {
                  value: format.number(Math.abs(change.pct) / 100, { style: 'percent', maximumFractionDigits: 0 }),
                })}
              </span>
            )}{' '}
            {t('figures.versus', { range })}
          </p>
        ) : null}
        {others.length > 0 ? (
          <p className="spending-figure-note">{t('tile.otherCurrencies', { currencies: others.join(', ') })}</p>
        ) : null}
      </>
    );
  })();

  return (
    <section className="spending-tile" aria-labelledby="spending-tile-heading" id="spending-tile">
      <h2 id="spending-tile-heading">{t('tile.heading')}</h2>
      {body}
      <p>
        <Link href="/dashboard/budgets/spending">{t('tile.link')} →</Link>
      </p>
    </section>
  );
}
