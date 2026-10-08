/**
 * Inhalt der Verträge-Seite (gestreamt, Fallback: ContractsSkeleton):
 * Erkennung beim Öffnen (public.refresh_contracts – ändert nur Vorschläge
 * und verknüpft neue Buchungen), dann Vorschläge, eigene Verträge und
 * verworfene. Alle Abfragen filtern auf user_id = eigener Nutzer (RLS gibt
 * Beratern zusätzlich die Daten ihrer Mandanten frei).
 */
import { getFormatter, getTranslations } from 'next-intl/server';

import { Link } from '@/i18n/navigation';
import { confirmContract, dismissContract, restoreContract } from '@/lib/actions/contracts';
import { getContractLabels } from '@/lib/contract-labels';
import { CONTRACT_TYPES, confidenceLevel } from '@/lib/contracts';
import { createClient } from '@/lib/supabase/server';

import { ActionForm } from './action-form';

/** Je Vorschlag angezeigte verknüpfte Buchungen (Rest als „… und N weitere“). */
const BOOKINGS_PER_SUGGESTION = 12;

export async function ContractsOverview({ userId }: { userId: string }) {
  const t = await getTranslations('Contracts');
  const labels = await getContractLabels();
  const format = await getFormatter();

  const supabase = await createClient();
  const refreshed = await supabase.rpc('refresh_contracts');
  if (refreshed.error) {
    console.error('[contracts] Erkennung beim Öffnen fehlgeschlagen', { code: refreshed.error.code });
  }

  const [contracts, transactionCount] = await Promise.all([
    supabase
      .from('recurring_contracts')
      .select(
        `id, name, counterparty_name, contract_type, rhythm, interval_count, expected_amount, currency,
         next_expected_date, status, detection_source, detection_confidence,
         account:accounts!recurring_contracts_account_fkey ( name ),
         transactions!transactions_recurring_contract_fkey ( count )`,
      )
      .eq('user_id', userId)
      .order('next_expected_date', { ascending: true, nullsFirst: false })
      .order('name'),
    supabase.from('transactions').select('id', { count: 'exact', head: true }).eq('user_id', userId),
  ]);
  if (contracts.error) {
    console.error('[contracts] Laden fehlgeschlagen', { code: contracts.error.code });
  }

  const rows = (contracts.data ?? []).map((row) => ({ ...row, bookings: row.transactions[0]?.count ?? 0 }));
  const suggestions = rows.filter((row) => row.status === 'suggested');
  const mine = rows.filter((row) => ['active', 'cancellation_pending', 'cancelled'].includes(row.status));
  const dismissed = rows.filter((row) => row.status === 'dismissed');
  const hasTransactions = (transactionCount.count ?? 0) > 0;

  // Verknüpfte Buchungen der Vorschläge (zum Aufklappen).
  const bookings = new Map<string, { id: string; booking_date: string; amount: number; currency: string; label: string }[]>();
  if (suggestions.length > 0) {
    const { data, error } = await supabase
      .from('transactions')
      .select('id, recurring_contract_id, booking_date, amount, currency, purpose, account:accounts!transactions_account_fkey ( name )')
      .eq('user_id', userId)
      .in(
        'recurring_contract_id',
        suggestions.map((row) => row.id),
      )
      .order('booking_date', { ascending: false })
      .limit(1000);
    if (error) {
      console.error('[contracts] Buchungen der Vorschläge nicht ladbar', { code: error.code });
    }
    for (const tx of data ?? []) {
      if (!tx.recurring_contract_id) {
        continue;
      }
      const list = bookings.get(tx.recurring_contract_id) ?? [];
      list.push({
        id: tx.id,
        booking_date: tx.booking_date,
        amount: tx.amount,
        currency: tx.currency,
        label: [tx.account?.name, tx.purpose].filter(Boolean).join(' · '),
      });
      bookings.set(tx.recurring_contract_id, list);
    }
  }

  const money = (amount: number | null, currency: string) =>
    amount === null ? t('notSet') : format.number(Math.abs(amount), { style: 'currency', currency });
  const date = (value: string | null) =>
    value
      ? format.dateTime(new Date(`${value}T00:00:00Z`), { dateStyle: 'medium', timeZone: 'UTC' })
      : t('notSet');

  return (
    <>
        {contracts.error ? (
          <p role="alert" className="form-error">
            {t('errors.loadError')}
          </p>
        ) : !hasTransactions && suggestions.length === 0 && mine.length === 0 ? (
          <div className="contract-empty">
            <strong>{t('empty.noTransactions.title')}</strong>
            <p>{t('empty.noTransactions.text')}</p>
            <div className="contract-empty-actions">
              <Link href="/dashboard/transactions/import" className="button button-small">
                {t('empty.noTransactions.import')}
              </Link>
              <Link href="/dashboard/contracts/new" className="button button-secondary button-small">
                {t('empty.noTransactions.new')}
              </Link>
            </div>
          </div>
        ) : (
          <>
            <section className="contracts-section" aria-labelledby="suggestions-heading">
              <h2 id="suggestions-heading">{t('suggestions.heading')}</h2>
              {suggestions.length === 0 ? (
                mine.length === 0 ? (
                  <div className="contract-empty">
                    <strong>{t('empty.nothingDetected.title')}</strong>
                    <p>{t('empty.nothingDetected.text')}</p>
                    <div className="contract-empty-actions">
                      <Link href="/dashboard/contracts/new" className="button button-secondary button-small">
                        {t('empty.noTransactions.new')}
                      </Link>
                    </div>
                  </div>
                ) : (
                  <p className="empty-state">{t('suggestions.empty')}</p>
                )
              ) : (
                <>
                  <p className="hint">{t('suggestions.intro')}</p>
                  <ul className="contract-cards">
                    {suggestions.map((row, index) => {
                      const id = `suggestion-${index}`;
                      const level = confidenceLevel(row.detection_confidence);
                      const linked = bookings.get(row.id) ?? [];
                      return (
                        <li key={row.id} className="contract-card" aria-labelledby={`${id}-name`}>
                          <div className="contract-card-header">
                            <h3 id={`${id}-name`} className="contract-card-title">
                              {row.name}
                            </h3>
                            <span className={`badge contract-confidence-${level}`}>
                              {t('suggestions.confidence', { level: labels.confidence(row.detection_confidence) })}
                              {row.bookings <= 2 ? ` · ${t('suggestions.fewBookings', { count: row.bookings })}` : null}
                            </span>
                          </div>
                          {row.counterparty_name && row.counterparty_name !== row.name ? (
                            <p className="contract-card-sub">
                              {t('fields.counterparty')}: {row.counterparty_name}
                            </p>
                          ) : null}
                          <dl className="contract-facts">
                            <div>
                              <dt>{t('fields.rhythm')}</dt>
                              <dd>{labels.rhythm(row.rhythm, row.interval_count)}</dd>
                            </div>
                            <div>
                              <dt>{t('fields.amount')}</dt>
                              <dd>{money(row.expected_amount, row.currency)}</dd>
                            </div>
                            <div>
                              <dt>{t('fields.next')}</dt>
                              <dd>{date(row.next_expected_date)}</dd>
                            </div>
                            <div>
                              <dt>{t('fields.account')}</dt>
                              <dd>{row.account?.name ?? t('notSet')}</dd>
                            </div>
                          </dl>
                          {linked.length > 0 ? (
                            <details className="contract-bookings">
                              <summary>{t('suggestions.showBookings', { count: row.bookings })}</summary>
                              <ul>
                                {linked.slice(0, BOOKINGS_PER_SUGGESTION).map((tx) => (
                                  <li key={tx.id}>
                                    <span>
                                      {date(tx.booking_date)}
                                      {tx.label ? <span className="cell-note">{tx.label}</span> : null}
                                    </span>
                                    <span>{money(tx.amount, tx.currency)}</span>
                                  </li>
                                ))}
                                {linked.length > BOOKINGS_PER_SUGGESTION ? (
                                  <li>{t('suggestions.moreBookings', { count: linked.length - BOOKINGS_PER_SUGGESTION })}</li>
                                ) : null}
                              </ul>
                            </details>
                          ) : null}
                          <div className="contract-actions">
                            <ActionForm action={confirmContract.bind(null, row.id)}>
                              <label htmlFor={`${id}-type`}>
                                {t('fields.type')}
                                <select id={`${id}-type`} name="type" defaultValue={row.contract_type}>
                                  {CONTRACT_TYPES.map((type) => (
                                    <option key={type} value={type}>
                                      {labels.type(type)}
                                    </option>
                                  ))}
                                </select>
                              </label>
                              <button
                                type="submit"
                                className="button button-small"
                                aria-label={t('suggestions.confirmLabel', { name: row.name })}
                              >
                                {t('suggestions.confirm')}
                              </button>
                            </ActionForm>
                            <ActionForm action={dismissContract.bind(null, row.id)}>
                              <button
                                type="submit"
                                className="button button-secondary button-small"
                                aria-label={t('suggestions.dismissLabel', { name: row.name })}
                              >
                                {t('suggestions.dismiss')}
                              </button>
                            </ActionForm>
                          </div>
                        </li>
                      );
                    })}
                  </ul>
                </>
              )}
            </section>

            <section className="contracts-section" aria-labelledby="mine-heading">
              <h2 id="mine-heading">{t('list.heading')}</h2>
              {mine.length === 0 ? (
                <p className="empty-state">{t('list.empty')}</p>
              ) : (
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
                          <td className="amount">{row.bookings}</td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              )}
            </section>

            {dismissed.length > 0 ? (
              <section className="contracts-section" aria-labelledby="dismissed-heading">
                <details className="contract-dismissed">
                  <summary>
                    <span id="dismissed-heading">{t('dismissed.heading', { count: dismissed.length })}</span>
                  </summary>
                  <p className="hint">{t('dismissed.hint')}</p>
                  <ul>
                    {dismissed.map((row) => (
                      <li key={row.id}>
                        <span>
                          {row.name}
                          <span className="cell-note">
                            {labels.rhythm(row.rhythm, row.interval_count)} · {money(row.expected_amount, row.currency)}
                          </span>
                        </span>
                        {row.detection_source === 'auto' ? (
                          <ActionForm action={restoreContract.bind(null, row.id)}>
                            <button
                              type="submit"
                              className="button button-secondary button-small"
                              aria-label={t('dismissed.restoreLabel', { name: row.name })}
                            >
                              {t('dismissed.restore')}
                            </button>
                          </ActionForm>
                        ) : null}
                      </li>
                    ))}
                  </ul>
                </details>
              </section>
            ) : null}
          </>
        )}
    </>
  );
}
