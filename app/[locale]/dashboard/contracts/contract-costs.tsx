/**
 * Jahreskosten der Verträge je Währung und Vertragstyp (lib/contract-costs.ts):
 * Jahreskosten, ≈ pro Monat und tatsächlich abgebucht (letzte 12 volle
 * Monate, netto nach Gegenbuchungen). Für die Verträge-Seite und die
 * Leseansicht des Beraters.
 */
import { getFormatter, getTranslations } from 'next-intl/server';

import type { MonthRange } from '@/lib/budget-rule';
import { getContractLabels } from '@/lib/contract-labels';
import type { CurrencyCosts } from '@/lib/contract-costs';

type ContractCostsProps = {
  costs: CurrencyCosts[];
  window: MonthRange;
  /** Eindeutiges Präfix der Überschrift (Seite und Berateransicht). */
  idPrefix: string;
};

export async function ContractCosts({ costs, window, idPrefix }: ContractCostsProps) {
  const t = await getTranslations('Contracts');
  const labels = await getContractLabels();
  const format = await getFormatter();
  const monthYear = (month: string) =>
    format.dateTime(new Date(`${month}-01T00:00:00Z`), { month: 'short', year: 'numeric', timeZone: 'UTC' });
  const windowLabel = t('costs.window', { from: monthYear(window.from), to: monthYear(window.to) });

  return (
    <section className="contracts-section contract-costs" aria-labelledby={`${idPrefix}-heading`}>
      <h2 id={`${idPrefix}-heading`}>{t('costs.heading')}</h2>
      {costs.length === 0 ? (
        <p className="empty-state">{t('costs.empty')}</p>
      ) : (
        <>
          <p className="hint">{t('costs.intro')}</p>
          {costs.map((block) => {
            const money = (cents: number) => format.number(cents / 100, { style: 'currency', currency: block.currency });
            return (
              <div key={block.currency} className="table-scroll" data-currency={block.currency}>
                <table className="transactions-table contract-costs-table">
                  <caption>{t('costs.caption', { currency: block.currency })}</caption>
                  <thead>
                    <tr>
                      <th scope="col">{t('costs.columns.type')}</th>
                      <th scope="col" className="amount">
                        {t('costs.columns.count')}
                      </th>
                      <th scope="col" className="amount">
                        {t('costs.columns.annual')}
                      </th>
                      <th scope="col" className="amount">
                        {t('costs.columns.monthly')}
                      </th>
                      <th scope="col" className="amount">
                        {t('costs.columns.actual')}
                        <span className="cell-note">{windowLabel}</span>
                      </th>
                    </tr>
                  </thead>
                  <tbody>
                    {block.types.map((row) => (
                      <tr key={row.type} data-type={row.type}>
                        <th scope="row">{labels.type(row.type)}</th>
                        <td className="amount">{row.count}</td>
                        <td className="amount">{money(row.annualCents)}</td>
                        <td className="amount">{money(row.monthlyCents)}</td>
                        <td className="amount">{money(row.actualCents)}</td>
                      </tr>
                    ))}
                  </tbody>
                  <tfoot>
                    <tr data-type="total">
                      <th scope="row">{t('costs.total')}</th>
                      <td className="amount">{block.total.count}</td>
                      <td className="amount">{money(block.total.annualCents)}</td>
                      <td className="amount">{money(block.total.monthlyCents)}</td>
                      <td className="amount">{money(block.total.actualCents)}</td>
                    </tr>
                  </tfoot>
                </table>
                {block.withoutAmount > 0 ? (
                  <p className="cell-note">{t('costs.withoutAmount', { count: block.withoutAmount })}</p>
                ) : null}
              </div>
            );
          })}
          <p className="hint">{t('costs.note')}</p>
        </>
      )}
    </section>
  );
}
