/**
 * Zeitraum des Ausgaben-Dashboards: Art (Woche, Monat, Quartal, Jahr, frei),
 * blättern mit ‹ ›, „Heute“, freier Zeitraum per GET-Formular und beim
 * Monat und Quartal der Vergleich mit Vorperiode oder Vorjahr. Alles Links
 * bzw. ein GET-Formular – funktioniert ohne JavaScript.
 */
import { getFormatter, getTranslations } from 'next-intl/server';

import { Link } from '@/i18n/navigation';
import {
  PERIOD_TYPES,
  hasNext,
  isoWeek,
  periodQuery,
  periodRange,
  shiftRange,
  type CompareMode,
  type SpendingPeriod,
} from '@/lib/spending-period';

const SPENDING_PATH = '/dashboard/budgets/spending';

type SpendingControlsProps = {
  period: SpendingPeriod;
  today: string;
  currency: string | null;
};

export async function SpendingControls({ period, today, currency }: SpendingControlsProps) {
  const t = await getTranslations('Spending.period');
  const format = await getFormatter();
  const href = (type: SpendingPeriod['type'], range: SpendingPeriod['range'], compare: CompareMode = period.compareMode) =>
    `${SPENDING_PATH}?${periodQuery(type, range, { compare, currency })}`;
  const at = (value: string) => new Date(`${value}T00:00:00Z`);
  const { range } = period;

  const label =
    period.type === 'month'
      ? format.dateTime(at(range.from), { month: 'long', year: 'numeric', timeZone: 'UTC' })
      : period.type === 'quarter'
        ? t('quarter', { quarter: Math.floor(Number(range.from.slice(5, 7)) / 3) + 1, year: range.from.slice(0, 4) })
        : period.type === 'year'
          ? range.from.slice(0, 4)
          : period.type === 'week'
            ? t('week', {
                week: isoWeek(range.from),
                range: format.dateTimeRange(at(range.from), at(range.to), {
                  day: '2-digit',
                  month: '2-digit',
                  year: 'numeric',
                  timeZone: 'UTC',
                }),
              })
            : format.dateTimeRange(at(range.from), at(range.to), { dateStyle: 'medium', timeZone: 'UTC' });
  // Beim Wechsel der Art: Periode um das Ende des ausgewerteten Zeitraums.
  const anchor = period.evaluated.to;

  return (
    <div className="spending-controls">
      <nav className="spending-types" aria-label={t('label')}>
        <ul>
          {PERIOD_TYPES.map((type) => (
            <li key={type}>
              <Link
                href={type === 'custom' ? href('custom', period.evaluated) : href(type, periodRange(type, anchor))}
                aria-current={type === period.type ? 'page' : undefined}
              >
                {t(`types.${type}`)}
              </Link>
            </li>
          ))}
        </ul>
      </nav>

      <div className="spending-nav">
        <Link href={href(period.type, shiftRange(period.type, range, -1))} aria-label={t('previous')} className="spending-step">
          ‹
        </Link>
        <span className="spending-period-label" id="spending-period">
          {label}
          {period.running ? <span className="cell-note"> {t('toDate')}</span> : null}
        </span>
        {hasNext(period, today) ? (
          <Link href={href(period.type, shiftRange(period.type, range, 1))} aria-label={t('next')} className="spending-step">
            ›
          </Link>
        ) : (
          <span className="spending-step spending-step-disabled" aria-hidden="true">
            ›
          </span>
        )}
        {period.type !== 'custom' && !period.running ? (
          <Link href={href(period.type, periodRange(period.type, today))} className="spending-today">
            {t('today')}
          </Link>
        ) : null}
      </div>

      {period.type === 'custom' ? (
        <form method="get" className="spending-custom" aria-label={t('label')}>
          <input type="hidden" name="period" value="custom" />
          {currency ? <input type="hidden" name="currency" value={currency} /> : null}
          <div className="filter-field">
            <label htmlFor="spending-from">{t('from')}</label>
            <input id="spending-from" name="from" type="date" max={today} defaultValue={range.from} required />
          </div>
          <div className="filter-field">
            <label htmlFor="spending-to">{t('to')}</label>
            <input id="spending-to" name="to" type="date" max={today} defaultValue={range.to} required />
          </div>
          <button type="submit" className="button button-small">
            {t('apply')}
          </button>
        </form>
      ) : null}

      {period.type === 'month' || period.type === 'quarter' ? (
        <p className="spending-compare">
          <span>{t('compare')}</span>{' '}
          {(['previous', 'year'] as const).map((mode) => (
            <Link key={mode} href={href(period.type, range, mode)} aria-current={mode === period.compareMode ? 'true' : undefined}>
              {t(`compareOptions.${mode}`)}
            </Link>
          ))}
        </p>
      ) : null}
    </div>
  );
}
