/**
 * Detailseite eines Vertrags, gestreamter Teil: verknüpfte Buchungen
 * (lösen), manuell gelöste Buchungen derselben Gegenpartei (wieder
 * verknüpfen) und das Bearbeiten-Formular. Nur eigene Daten
 * (user_id = eigener Nutzer).
 */
import { getFormatter, getTranslations } from 'next-intl/server';

import { linkContractTransaction, saveContract, unlinkContractTransaction } from '@/lib/actions/contracts';
import type { ContractFormValues, ContractStatus } from '@/lib/contracts';
import { createClient } from '@/lib/supabase/server';

import { ActionForm } from '../action-form';
import { ContractForm } from '../contract-form';
import { loadContractFormData } from '../form-data';

type ContractBookingsProps = {
  contract: { id: string; name: string; status: ContractStatus; counterpartyKey: string | null };
  userId: string;
  editable: boolean;
  initialValues: ContractFormValues;
};

export async function ContractBookings({ contract, userId, editable, initialValues }: ContractBookingsProps) {
  const t = await getTranslations('Contracts');
  const format = await getFormatter();
  const supabase = await createClient();

  const [linked, unlinked, formData] = await Promise.all([
    supabase
      .from('transactions')
      .select(
        'id, booking_date, amount, currency, counterparty_name, purpose, account:accounts!transactions_account_fkey ( name )',
      )
      .eq('user_id', userId)
      .eq('recurring_contract_id', contract.id)
      .order('booking_date', { ascending: false })
      .limit(500),
    contract.counterpartyKey && contract.status !== 'dismissed'
      ? supabase
          .from('transactions')
          .select('id, booking_date, amount, currency, purpose')
          .eq('user_id', userId)
          .eq('counterparty_key', contract.counterpartyKey)
          .is('recurring_contract_id', null)
          .eq('contract_link_manual', true)
          .lt('amount', 0)
          .order('booking_date', { ascending: false })
          .limit(50)
      : Promise.resolve({ data: [], error: null }),
    editable ? loadContractFormData(userId) : Promise.resolve(null),
  ]);
  if (linked.error || unlinked.error) {
    console.error('[contracts] Buchungen nicht ladbar', { code: (linked.error ?? unlinked.error)?.code });
  }

  const money = (amount: number, currency: string) =>
    format.number(Math.abs(amount), { style: 'currency', currency });
  const date = (value: string) =>
    format.dateTime(new Date(`${value}T00:00:00Z`), { dateStyle: 'medium', timeZone: 'UTC' });
  const linkedRows = linked.data ?? [];

  return (
    <>
      <section className="contracts-section" aria-labelledby="linked-heading">
        <h2 id="linked-heading">{t('detail.linkedHeading', { count: linkedRows.length })}</h2>
        {linked.error ? (
          <p role="alert" className="form-error">
            {t('errors.loadError')}
          </p>
        ) : linkedRows.length === 0 ? (
          <p className="empty-state">
            {contract.counterpartyKey ? t('detail.linkedEmpty') : t('detail.linkedEmptyNoCounterparty')}
          </p>
        ) : (
          <>
            <p className="hint">{t('detail.linkedHint')}</p>
            <div className="table-scroll">
              <table className="transactions-table">
                <caption>{t('detail.linkedCaption', { name: contract.name })}</caption>
                <thead>
                  <tr>
                    <th scope="col">{t('detail.date')}</th>
                    <th scope="col">{t('detail.booking')}</th>
                    <th scope="col">{t('detail.account')}</th>
                    <th scope="col" className="amount">
                      {t('detail.amount')}
                    </th>
                    {contract.status !== 'dismissed' ? (
                      <th scope="col">
                        <span className="sr-only">{t('detail.actions')}</span>
                      </th>
                    ) : null}
                  </tr>
                </thead>
                <tbody>
                  {linkedRows.map((tx) => (
                    <tr key={tx.id}>
                      <td className="nowrap">{date(tx.booking_date)}</td>
                      <td>
                        {tx.counterparty_name ?? t('notSet')}
                        {tx.purpose ? <span className="cell-note">{tx.purpose}</span> : null}
                      </td>
                      <td>{tx.account?.name ?? t('notSet')}</td>
                      <td className="amount">{money(tx.amount, tx.currency)}</td>
                      {contract.status !== 'dismissed' ? (
                        <td className="row-actions">
                          <ActionForm action={unlinkContractTransaction.bind(null, contract.id, tx.id)}>
                            <button
                              type="submit"
                              className="link-button"
                              aria-label={t('detail.unlinkLabel', { date: date(tx.booking_date) })}
                            >
                              {t('detail.unlink')}
                            </button>
                          </ActionForm>
                        </td>
                      ) : null}
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </>
        )}
      </section>

      {(unlinked.data ?? []).length > 0 ? (
        <section className="contracts-section" aria-labelledby="unlinked-heading">
          <h2 id="unlinked-heading">{t('detail.unlinkedHeading')}</h2>
          <p className="hint">{t('detail.unlinkedHint')}</p>
          <div className="contract-bookings">
            <ul>
              {(unlinked.data ?? []).map((tx) => (
                <li key={tx.id}>
                  <span>
                    {date(tx.booking_date)} · {money(tx.amount, tx.currency)}
                    {tx.purpose ? <span className="cell-note">{tx.purpose}</span> : null}
                  </span>
                  <ActionForm action={linkContractTransaction.bind(null, contract.id, tx.id)}>
                    <button
                      type="submit"
                      className="link-button"
                      aria-label={t('detail.linkLabel', { date: date(tx.booking_date) })}
                    >
                      {t('detail.link')}
                    </button>
                  </ActionForm>
                </li>
              ))}
            </ul>
          </div>
        </section>
      ) : null}

      {editable ? (
        <section className="contracts-section" aria-labelledby="edit-heading">
          <h2 id="edit-heading">{t('detail.editHeading')}</h2>
          {formData ? (
            <ContractForm
              mode="edit"
              action={saveContract.bind(null, contract.id)}
              counterparties={formData.counterparties}
              accounts={formData.accounts}
              categories={formData.categories}
              initialValues={initialValues}
            />
          ) : (
            <p role="alert" className="form-error">
              {t('errors.loadError')}
            </p>
          )}
        </section>
      ) : null}
    </>
  );
}
