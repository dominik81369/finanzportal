/**
 * Inhalt der Verträge-Seite (gestreamt, Fallback: ContractsSkeleton):
 * Beim Öffnen werden neue Buchungen verknüpft (public.sync_contracts – keine
 * Erkennung, keine Vorschläge), dann die eigenen Verträge mit Jahreskosten
 * (contract-costs.tsx). Alle Abfragen filtern auf user_id = eigener Nutzer
 * (RLS gibt Beratern zusätzlich die Daten ihrer Mandanten frei).
 */
import { getFormatter, getTranslations } from 'next-intl/server';

import { Link } from '@/i18n/navigation';
import { rangeDates } from '@/lib/budget-rule';
import { actualsWindow, annualCents, summarizeContractCosts, type ContractActualRow } from '@/lib/contract-costs';
import { getContractLabels } from '@/lib/contract-labels';
import { LISTED_CONTRACT_STATUSES } from '@/lib/contracts';
import { createClient } from '@/lib/supabase/server';
import { todayInGermany } from '@/lib/transactions';

import { ContractCosts } from './contract-costs';

export async function ContractsOverview({ userId }: { userId: string }) {
  const t = await getTranslations('Contracts');
  const labels = await getContractLabels();
  const format = await getFormatter();

  const supabase = await createClient();
  const synced = await supabase.rpc('sync_contracts');
  if (synced.error) {
    console.error('[contracts] Verknüpfen beim Öffnen fehlgeschlagen', { code: synced.error.code });
  }

  const window = actualsWindow(todayInGermany().slice(0, 7));
  const { fromDate, toDate } = rangeDates(window);
  const [contracts, transactionCount, actuals] = await Promise.all([
    supabase
      .from('recurring_contracts')
      .select(
        `id, name, counterparty_name, contract_type, rhythm, interval_count, expected_amount, currency,
         next_expected_date, status,
         transactions!transactions_recurring_contract_fkey ( count )`,
      )
      .eq('user_id', userId)
      .in('status', LISTED_CONTRACT_STATUSES)
      .order('next_expected_date', { ascending: true, nullsFirst: false })
      .order('name'),
    supabase.from('transactions').select('id', { count: 'exact', head: true }).eq('user_id', userId),
    supabase.rpc('contract_actuals', { p_user_id: userId, p_from: fromDate, p_to: toDate }),
  ]);
  if (contracts.error) {
    console.error('[contracts] Laden fehlgeschlagen', { code: contracts.error.code });
  }
  if (actuals.error) {
    console.error('[contracts] Abbuchungen je Vertrag nicht ladbar', { code: actuals.error.code });
  }

  const mine = (contracts.data ?? []).map((row) => ({ ...row, bookings: row.transactions[0]?.count ?? 0 }));
  const hasTransactions = (transactionCount.count ?? 0) > 0;
  const costs = actuals.error
    ? null
    : summarizeContractCosts(
        mine.map((row) => ({
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

  const money = (amount: number | null, currency: string) =>
    amount === null ? t('notSet') : format.number(Math.abs(amount), { style: 'currency', currency });
  const date = (value: string | null) =>
    value
      ? format.dateTime(new Date(`${value}T00:00:00Z`), { dateStyle: 'medium', timeZone: 'UTC' })
      : t('notSet');
  const annualPerYear = (...args: [...Parameters<typeof annualCents>, string]) => {
    const [amount, rhythm, intervalCount, currency] = args;
    const cents = annualCents(amount, rhythm, intervalCount);
    return cents === null ? t('notSet') : t('costs.approx', { amount: format.number(cents / 100, { style: 'currency', currency }) });
  };

  if (contracts.error) {
    return (
      <p role="alert" className="form-error">
        {t('errors.loadError')}
      </p>
    );
  }
  if (mine.length === 0) {
    const empty = hasTransactions ? 'noContracts' : 'noTransactions';
    return (
      <div className="contract-empty">
        <strong>{t(`empty.${empty}.title`)}</strong>
        <p>{t(`empty.${empty}.text`)}</p>
        <div className="contract-empty-actions">
          {hasTransactions ? null : (
            <Link href="/dashboard/transactions/import" className="button button-small">
              {t('empty.noTransactions.import')}
            </Link>
          )}
          <Link
            href="/dashboard/contracts/new"
            className={hasTransactions ? 'button button-small' : 'button button-secondary button-small'}
          >
            {t('empty.new')}
          </Link>
        </div>
      </div>
    );
  }

  return (
    <>
      <section className="contracts-section" aria-labelledby="mine-heading">
        <h2 id="mine-heading">{t('list.heading')}</h2>
        <div className="table-scroll">
          <table className="transactions-table contract-table">
            <caption>{t('list.caption')}</caption>
            <thead>
              <tr>
                <th scope="col">{t('fields.name')}</th>
                <th scope="col">{t('fields.type')}</th>
                <th scope="col">{t('fields.rhythm')}</th>
                <th scope="col" className="amount">
                  {t('fields.amount')}
                </th>
                <th scope="col">{t('fields.next')}</th>
                <th scope="col" className="amount">
                  {t('costs.perYear')}
                </th>
                <th scope="col" className="amount">
                  {t('fields.bookings')}
                </th>
              </tr>
            </thead>
            <tbody>
              {mine.map((row) => (
                <tr key={row.id}>
                  <td>
                    <Link href={`/dashboard/contracts/${row.id}`}>{row.name}</Link>
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
                  <td className="amount">{annualPerYear(row.expected_amount, row.rhythm, row.interval_count, row.currency)}</td>
                  <td className="amount">{row.bookings}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </section>

      {costs ? (
        <ContractCosts costs={costs} window={window} idPrefix="costs" />
      ) : (
        <p role="alert" className="form-error">
          {t('costs.loadError')}
        </p>
      )}
    </>
  );
}
