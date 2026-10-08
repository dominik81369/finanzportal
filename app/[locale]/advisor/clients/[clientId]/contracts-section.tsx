/**
 * Leseansicht des Beraters: Verträge eines verbundenen Mandanten
 * (bestätigte bzw. manuell angelegte; offene Vorschläge nur als Anzahl).
 * Keine Aktionen und keine Erkennung – RLS erlaubt Beratern nur SELECT.
 * Die Abfrage filtert ausdrücklich auf user_id = clientId.
 */
import { getFormatter, getTranslations } from 'next-intl/server';

import { getContractLabels } from '@/lib/contract-labels';
import { createClient } from '@/lib/supabase/server';

export async function AdvisorContractsSection({ clientId, name }: { clientId: string; name: string }) {
  const t = await getTranslations('Advisor.client.contracts');
  const tContracts = await getTranslations('Contracts');
  const labels = await getContractLabels();
  const format = await getFormatter();

  const supabase = await createClient();
  const { data, error } = await supabase
    .from('recurring_contracts')
    .select(
      `id, name, counterparty_name, contract_type, rhythm, interval_count, expected_amount, currency,
       next_expected_date, status,
       transactions!transactions_recurring_contract_fkey ( count )`,
    )
    .eq('user_id', clientId)
    .in('status', ['suggested', 'active', 'cancellation_pending', 'cancelled'])
    .order('next_expected_date', { ascending: true, nullsFirst: false })
    .order('name');
  if (error) {
    console.error('[advisor] Verträge des Mandanten nicht ladbar', { code: error.code });
  }
  const rows = (data ?? []).filter((row) => row.status !== 'suggested');
  const open = (data ?? []).length - rows.length;
  const money = (amount: number | null, currency: string) =>
    amount === null ? tContracts('notSet') : format.number(Math.abs(amount), { style: 'currency', currency });
  const date = (value: string | null) =>
    value
      ? format.dateTime(new Date(`${value}T00:00:00Z`), { dateStyle: 'medium', timeZone: 'UTC' })
      : tContracts('notSet');

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
                  <td className="amount">{row.transactions[0]?.count ?? 0}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      {open > 0 ? <p className="hint">{t('openSuggestions', { count: open })}</p> : null}
    </section>
  );
}
