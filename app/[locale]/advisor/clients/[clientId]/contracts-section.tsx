/**
 * Leseansicht des Beraters: Verträge eines verbundenen Mandanten (aktiv,
 * Kündigung vorgemerkt, gekündigt) mit Jahreskosten.
 * Keine Aktionen und kein Verknüpfen – RLS erlaubt Beratern nur SELECT.
 * Die Abfrage filtert ausdrücklich auf user_id = clientId.
 */
import { getFormatter, getTranslations } from 'next-intl/server';

import { rangeDates } from '@/lib/budget-rule';
import { actualsWindow, annualCents, summarizeContractCosts, type ContractActualRow } from '@/lib/contract-costs';
import { getContractLabels } from '@/lib/contract-labels';
import { LISTED_CONTRACT_STATUSES } from '@/lib/contracts';
import { createClient } from '@/lib/supabase/server';
import { todayInGermany } from '@/lib/transactions';

import { ContractCosts } from '../../../dashboard/contracts/contract-costs';

export async function AdvisorContractsSection({ clientId, name }: { clientId: string; name: string }) {
  const t = await getTranslations('Advisor.client.contracts');
  const tContracts = await getTranslations('Contracts');
  const labels = await getContractLabels();
  const format = await getFormatter();

  const supabase = await createClient();
  const window = actualsWindow(todayInGermany().slice(0, 7));
  const { fromDate, toDate } = rangeDates(window);
  const actuals = await supabase.rpc('contract_actuals', { p_user_id: clientId, p_from: fromDate, p_to: toDate });
  if (actuals.error) {
    console.error('[advisor] Abbuchungen je Vertrag nicht ladbar', { code: actuals.error.code });
  }
  const { data, error } = await supabase
    .from('recurring_contracts')
    .select(
      `id, name, counterparty_name, contract_type, rhythm, interval_count, expected_amount, currency,
       next_expected_date, status,
       transactions!transactions_recurring_contract_fkey ( count )`,
    )
    .eq('user_id', clientId)
    .in('status', LISTED_CONTRACT_STATUSES)
    .order('next_expected_date', { ascending: true, nullsFirst: false })
    .order('name');
  if (error) {
    console.error('[advisor] Verträge des Mandanten nicht ladbar', { code: error.code });
  }
  const rows = data ?? [];
  const money = (amount: number | null, currency: string) =>
    amount === null ? tContracts('notSet') : format.number(Math.abs(amount), { style: 'currency', currency });
  const date = (value: string | null) =>
    value
      ? format.dateTime(new Date(`${value}T00:00:00Z`), { dateStyle: 'medium', timeZone: 'UTC' })
      : tContracts('notSet');
  const perYear = (row: (typeof rows)[number]) => {
    const cents = annualCents(row.expected_amount, row.rhythm, row.interval_count);
    return cents === null
      ? tContracts('notSet')
      : tContracts('costs.approx', { amount: format.number(cents / 100, { style: 'currency', currency: row.currency }) });
  };
  const costs = actuals.error
    ? null
    : summarizeContractCosts(
        rows.map((row) => ({
          id: row.id,
          contractType: row.contract_type,
          status: row.status,
          rhythm: row.rhythm,
          intervalCount: row.interval_count,
          expectedAmount: row.expected_amount,
          currency: row.currency,
        })),
        (actuals.data ?? []) as ContractActualRow[],
      );

  return (
    <section className="advisor-section" aria-labelledby="contracts-heading">
      <h2 id="contracts-heading">{t('heading')}</h2>
      {error ? (
        <p role="alert" className="form-error">
          {t('loadError')}
        </p>
      ) : rows.length === 0 ? (
        <p className="empty-state">{t('empty')}</p>
      ) : (
        <div className="table-scroll">
          <table className="transactions-table contract-table">
            <caption>{t('caption', { name })}</caption>
            <thead>
              <tr>
                <th scope="col">{tContracts('fields.name')}</th>
                <th scope="col">{tContracts('fields.type')}</th>
                <th scope="col">{tContracts('fields.rhythm')}</th>
                <th scope="col" className="amount">
                  {tContracts('fields.amount')}
                </th>
                <th scope="col">{tContracts('fields.next')}</th>
                <th scope="col" className="amount">
                  {tContracts('costs.perYear')}
                </th>
                <th scope="col" className="amount">
                  {tContracts('fields.bookings')}
                </th>
              </tr>
            </thead>
            <tbody>
              {rows.map((row) => (
                <tr key={row.id}>
                  <td>
                    {row.name}
                    {row.status !== 'active' ? (
                      <>
                        {' '}
                        <span className="badge contract-status">{labels.status(row.status)}</span>
                      </>
                    ) : null}
                    {row.counterparty_name && row.counterparty_name !== row.name ? (
                      <span className="cell-note">{row.counterparty_name}</span>
                    ) : null}
                  </td>
                  <td>{labels.type(row.contract_type)}</td>
                  <td>{labels.rhythm(row.rhythm, row.interval_count)}</td>
                  <td className="amount">{money(row.expected_amount, row.currency)}</td>
                  <td className="nowrap">{date(row.next_expected_date)}</td>
                  <td className="amount">{perYear(row)}</td>
                  <td className="amount">{row.transactions[0]?.count ?? 0}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      {rows.length > 0 && costs ? <ContractCosts costs={costs} window={window} idPrefix="advisor-costs" /> : null}
    </section>
  );
}
