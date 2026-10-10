/**
 * Verlauf der Ausgaben: schlichte Säulen je Tag, Woche oder Monat (ohne
 * Diagramm-Bibliothek), mit Marke für den gleichen Teilzeitraum der
 * Vergleichsperiode, Legende und Tooltip beim Überfahren. Die Säulen sind
 * für Screenreader ausgeblendet; dieselben Werte stehen in der Tabelle
 * darunter. Mobil scrollt die Fläche waagerecht.
 */
import type { DateTimeFormatOptions } from 'next-intl';
import { getFormatter, getTranslations } from 'next-intl/server';
import type { CSSProperties } from 'react';

import type { BucketPoint } from '@/lib/spending';
import type { Bucket } from '@/lib/spending-period';

type SpendingChartProps = {
  points: BucketPoint[];
  bucket: Bucket;
  currency: string;
  hasCompare: boolean;
};

export async function SpendingChart({ points, bucket, currency, hasCompare }: SpendingChartProps) {
  const t = await getTranslations('Spending.chart');
  const format = await getFormatter();
  const money = (cents: number) => format.number(cents / 100, { style: 'currency', currency });
  const day = (value: string, options: DateTimeFormatOptions) =>
    format.dateTime(new Date(`${value}T00:00:00Z`), { ...options, timeZone: 'UTC' });
  const label = (start: string) =>
    bucket === 'day'
      ? day(start, { day: '2-digit', month: '2-digit' })
      : bucket === 'week'
        ? t('weekOf', { date: day(start, { day: '2-digit', month: '2-digit' }) })
        : day(start, { month: 'short', year: '2-digit' });

  const max = Math.max(1, ...points.flatMap((point) => [point.expenses, point.compareExpenses ?? 0]));
  const height = (cents: number) => `${((Math.max(cents, 0) / max) * 100).toFixed(1)}%`;
  const axisLabels = points.length > 2 ? [0, Math.floor((points.length - 1) / 2), points.length - 1] : points.map((_, i) => i);
  const captionId = `spending-chart-${currency}`;

  return (
    <figure className="spending-chart" aria-labelledby={captionId}>
      <figcaption id={captionId}>
        <span className="spending-chart-title">{t('heading')}</span>
        <span className="cell-note">{t('caption', { bucket, currency })}</span>
      </figcaption>
      <ul className="spending-legend" aria-hidden="true">
        <li>
          <span className="spending-legend-bar" />
          {t('current')}
        </li>
        {hasCompare ? (
          <li>
            <span className="spending-legend-compare" />
            {t('compare')}
          </li>
        ) : null}
      </ul>
      <div className="spending-plot-scroll">
        {/* Mindestbreite je Säule über die Anzahl; mobil scrollt die Fläche waagerecht. */}
        <div className="spending-plot-inner" style={{ '--spending-count': points.length } as CSSProperties}>
        <div className="spending-plot" aria-hidden="true">
          <span className="spending-plot-max">{format.number(max / 100, { style: 'currency', currency, maximumFractionDigits: 0 })}</span>
          {points.map((point) => (
            // Höhen als CSS-Variablen; Farben und Maße aus den Tokens.
            <span key={point.start} className="spending-column" style={{ '--spending-value': height(point.expenses), '--spending-compare': height(point.compareExpenses ?? 0) } as CSSProperties}>
              <span className="spending-column-bar" />
              {point.compareExpenses !== null && point.compareExpenses > 0 ? <span className="spending-column-compare" /> : null}
              <span className="spending-tip">
                {point.compareExpenses === null
                  ? t('tip', { label: label(point.start), amount: money(point.expenses) })
                  : t('tipCompare', {
                      label: label(point.start),
                      amount: money(point.expenses),
                      compare: money(point.compareExpenses),
                    })}
              </span>
            </span>
          ))}
        </div>
        <div className="spending-axis" aria-hidden="true">
          {axisLabels.map((index) => (
            <span key={index}>{label(points[index]!.start)}</span>
          ))}
        </div>
        </div>
      </div>
      <details className="spending-table">
        <summary>{t('showTable')}</summary>
        <div className="table-scroll">
          <table className="transactions-table">
            <caption className="sr-only">{t('caption', { bucket, currency })}</caption>
            <thead>
              <tr>
                <th scope="col">{t('columns.bucket')}</th>
                <th scope="col" className="amount">
                  {t('columns.current')}
                </th>
                {hasCompare ? (
                  <th scope="col" className="amount">
                    {t('columns.compare')}
                  </th>
                ) : null}
              </tr>
            </thead>
            <tbody>
              {points.map((point) => (
                <tr key={point.start}>
                  <th scope="row">{label(point.start)}</th>
                  <td className="amount">{money(point.expenses)}</td>
                  {hasCompare ? (
                    <td className="amount">{point.compareExpenses === null ? '–' : money(point.compareExpenses)}</td>
                  ) : null}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </details>
    </figure>
  );
}
