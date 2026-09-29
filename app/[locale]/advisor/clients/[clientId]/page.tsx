/**
 * app/[locale]/advisor/clients/[clientId]/page.tsx
 *
 * Leseansicht des Beraters auf die Finanzdaten eines verbundenen Mandanten:
 * Konten mit Saldo (Fremdwährungsbuchungen getrennt, siehe Migration
 * 20261002160000) und Buchungen (mit denselben Filtern und Seiten wie die eigene
 * Liste des Mandanten). Keine Schreibaktionen – RLS erlaubt Beratern auf
 * Mandantendaten ohnehin nur SELECT.
 *
 * Zugriff: Nur mit AKTIVER Verbindung advisor_id = eigener Nutzer,
 * user_id = clientId; sonst 404 (auch für fremde, widerrufene oder
 * ausgedachte IDs – die Seite verrät nicht, ob es den Nutzer gibt).
 * RLS (private.advisor_client_ids()) sichert zusätzlich jede Abfrage ab.
 * Alle Abfragen filtern ausdrücklich auf user_id = clientId, weil RLS die
 * Daten aller aktiven Mandanten und die eigenen des Beraters freigibt.
 */
import type { Metadata } from 'next';
import { notFound } from 'next/navigation';
import { getFormatter, getTranslations } from 'next-intl/server';

import { Link } from '@/i18n/navigation';
import { toAppLocale } from '@/i18n/routing';
import { createClient, requireAdvisor } from '@/lib/supabase/server';
import { hasActiveFilters, parsePage, parseTransactionFilters } from '@/lib/transaction-filters';
import { isUuid } from '@/lib/transactions';

import { loadTransactionFormOptions } from '../../../dashboard/transactions/form-options';
import { Pagination } from '../../../dashboard/transactions/pagination';
import { TransactionFiltersForm } from '../../../dashboard/transactions/transaction-filters-form';
import { loadTransactionList } from '../../../dashboard/transactions/transaction-list';
import { TransactionTable } from '../../../dashboard/transactions/transaction-table';

type ClientPageProps = {
  params: Promise<{ locale: string; clientId: string }>;
  searchParams: Promise<Record<string, string | string[] | undefined>>;
};

export async function generateMetadata({
  params,
}: Pick<ClientPageProps, 'params'>): Promise<Metadata> {
  const locale = toAppLocale((await params).locale);
  const t = await getTranslations({ locale, namespace: 'Advisor.client' });
  return { title: t('metaTitle') };
}

export default async function AdvisorClientPage({ params, searchParams }: ClientPageProps) {
  const advisor = await requireAdvisor();
  const { clientId } = await params;
  if (!isUuid(clientId)) {
    notFound();
  }

  const t = await getTranslations('Advisor.client');
  const tAdvisor = await getTranslations('Advisor');
  const tList = await getTranslations('Transactions.list');
  const tTypes = await getTranslations('AccountTypes');
  const format = await getFormatter();

  const supabase = await createClient();
  const { data: link, error: linkError } = await supabase
    .from('advisor_clients')
    .select(
      `invited_email, accepted_at,
       client:profiles!advisor_clients_user_id_fkey ( first_name, last_name )`,
    )
    .eq('advisor_id', advisor.id)
    .eq('user_id', clientId)
    .eq('status', 'active')
    .maybeSingle();

  if (linkError) {
    console.error('[advisor] Verbindung nicht ladbar', { code: linkError.code });
    throw new Error('advisor_client_link_unavailable');
  }
  if (!link) {
    notFound();
  }

  const name =
    [link.client?.first_name, link.client?.last_name].filter(Boolean).join(' ') ||
    tAdvisor('clients.noName');
  const listPath = `/advisor/clients/${clientId}`;

  const query = await searchParams;
  const filters = parseTransactionFilters(query);
  const filtered = hasActiveFilters(filters);
  const page = parsePage(query);

  const [accounts, foreign, { transactions, total, pages, firstRow }, options] = await Promise.all([
    supabase
      .from('accounts')
      .select('id, name, type, currency, institution_name, balance')
      .eq('user_id', clientId)
      .is('archived_at', null)
      .order('name'),
    // Buchungen in Fremdwährung zählen nicht zum Saldo – getrennt ausweisen.
    supabase.rpc('account_foreign_currency_totals', { p_user_id: clientId }),
    loadTransactionList({ userId: clientId, filters, page, listPath }),
    loadTransactionFormOptions(clientId),
  ]);

  if (foreign.error) {
    console.error('[advisor] Fremdwährungssummen nicht ladbar', { code: foreign.error.code });
  }
  const foreignByAccount = new Map<string, { currency: string; total: number }[]>();
  for (const row of foreign.data ?? []) {
    foreignByAccount.set(row.account_id, [...(foreignByAccount.get(row.account_id) ?? []), row]);
  }
  const money = (amount: number, currency: string) => format.number(amount, { style: 'currency', currency });

  if (accounts.error) {
    console.error('[advisor] Konten des Mandanten nicht ladbar', { code: accounts.error.code });
  }

  return (
    <div className="advisor-client">
      <p className="back-link">
        <Link href="/advisor">{t('back')}</Link>
      </p>
      <h1>{name}</h1>
      <p className="cell-note">
        {link.invited_email}
        {link.accepted_at
          ? ` · ${tAdvisor('clients.since', {
              date: format.dateTime(new Date(link.accepted_at), { dateStyle: 'medium' }),
            })}`
          : null}
      </p>
      <p className="read-only-note">{t('readOnly')}</p>

      <section className="advisor-section" aria-labelledby="accounts-heading">
        <h2 id="accounts-heading">{t('accounts.heading')}</h2>
        {accounts.error ? (
          <p role="alert" className="form-error">
            {t('accounts.loadError')}
          </p>
        ) : accounts.data.length === 0 ? (
          <p className="empty-state">{t('accounts.empty')}</p>
        ) : (
          <ul className="link-list">
            {accounts.data.map((account) => (
              <li key={account.id} className="link-item">
                <div className="link-item-text">
                  <strong>{account.name}</strong>
                  <span className="cell-note">
                    {[tTypes(account.type), account.institution_name, account.currency]
                      .filter(Boolean)
                      .join(' · ')}
                  </span>
                </div>
                <div className="account-balance">
                  <span className="sr-only">{t('accounts.balance')}: </span>
                  <strong className={account.balance < 0 ? 'amount-negative' : undefined}>
                    {money(account.balance, account.currency)}
                  </strong>
                  {(foreignByAccount.get(account.id) ?? []).map((row) => (
                    <span key={row.currency} className="cell-note">
                      {t('accounts.foreign', { amount: money(row.total, row.currency) })}
                    </span>
                  ))}
                </div>
              </li>
            ))}
          </ul>
        )}
      </section>

      <section className="advisor-section" aria-labelledby="transactions-heading">
        <h2 id="transactions-heading">{t('transactions.heading')}</h2>

        {options && (filtered || (transactions && transactions.length > 0)) ? (
          <TransactionFiltersForm filters={filters} active={filtered} basePath={listPath} {...options} />
        ) : null}

        {filtered && transactions ? (
          <p role="status" className="result-count">
            {tList('resultCount', { count: total })}
          </p>
        ) : null}

        {!transactions ? (
          <p role="alert" className="form-error">
            {tList('loadError')}
          </p>
        ) : transactions.length === 0 ? (
          <p className="empty-state">{filtered ? tList('noMatches') : t('transactions.empty')}</p>
        ) : (
          <>
            <TransactionTable
              transactions={transactions}
              caption={t('transactions.caption', { name })}
              editable={false}
            />
            <Pagination
              basePath={listPath}
              filters={filters}
              page={page}
              pages={pages}
              total={total}
              firstRow={firstRow}
              lastRow={firstRow + transactions.length - 1}
            />
          </>
        )}
      </section>
    </div>
  );
}
