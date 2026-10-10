/**
 * app/[locale]/dashboard/contracts/[id]/page.tsx
 *
 * Ein Vertrag: Angaben (mit letzter Abbuchung als reine Information,
 * Jahreskosten und tatsächlich abgebucht in den letzten 12 vollen Monaten)
 * und Löschen sofort; verknüpfte Buchungen, weitere Buchungen derselben
 * Gegenpartei und Bearbeiten gestreamt (contract-bookings.tsx).
 *
 * Nur eigene, angezeigte Verträge (user_id = eigener Nutzer, Status aktiv,
 * Kündigung vorgemerkt oder gekündigt); für Berater, fremde IDs und alte
 * Vorschläge ist die Seite ein 404. Die RPCs prüfen Eigentum selbst.
 */
import type { Metadata } from 'next';
import { notFound } from 'next/navigation';
import { getFormatter, getLocale, getTranslations } from 'next-intl/server';
import { Suspense } from 'react';

import { Link } from '@/i18n/navigation';
import { toAppLocale } from '@/i18n/routing';
import { deleteContract } from '@/lib/actions/contracts';
import { rangeDates } from '@/lib/budget-rule';
import { categoryDisplayName } from '@/lib/categories';
import { actualsByContract, actualsWindow, annualCents, paymentsPerYear, type ContractActualRow } from '@/lib/contract-costs';
import { getContractLabels } from '@/lib/contract-labels';
import { LISTED_CONTRACT_STATUSES, rhythmKey, type ContractFormValues } from '@/lib/contracts';
import { createClient, requireOnboardedUser } from '@/lib/supabase/server';
import { formatAmountInput, isUuid, todayInGermany } from '@/lib/transactions';

import { ActionForm } from '../../action-form';
import { ContractsSkeleton } from '../contracts-skeleton';
import { ContractBookings } from './contract-bookings';

type ContractPageProps = {
  params: Promise<{ locale: string; id: string }>;
  searchParams: Promise<Record<string, string | string[] | undefined>>;
};

export async function generateMetadata({ params }: Pick<ContractPageProps, 'params'>): Promise<Metadata> {
  const locale = toAppLocale((await params).locale);
  const t = await getTranslations({ locale, namespace: 'Contracts' });
  return { title: t('detail.metaTitle') };
}

export default async function ContractPage({ params, searchParams }: ContractPageProps) {
  const { id } = await params;
  if (!isUuid(id)) {
    notFound();
  }
  const user = await requireOnboardedUser(`/dashboard/contracts/${id}`);
  const query = await searchParams;
  const t = await getTranslations('Contracts');
  const tCategories = await getTranslations('DefaultCategories');
  const labels = await getContractLabels();
  const format = await getFormatter();
  const locale = toAppLocale(await getLocale());

  const supabase = await createClient();
  const { data: contract, error } = await supabase
    .from('recurring_contracts')
    .select(
      `id, name, counterparty_name, counterparty_key, contract_type, rhythm, interval_count, expected_amount,
       currency, first_booking_date, last_booking_date, next_expected_date, status, notes, account_id, category_id,
       account:accounts!recurring_contracts_account_fkey ( name ),
       category:categories!recurring_contracts_category_fkey ( name, default_key )`,
    )
    .eq('id', id)
    .eq('user_id', user.id)
    .in('status', LISTED_CONTRACT_STATUSES)
    .maybeSingle();
  if (error) {
    console.error('[contracts] Vertrag nicht ladbar', { code: error.code });
  } else if (!contract) {
    notFound();
  }

  if (!contract) {
    return (
      <section aria-labelledby="page-title" className="contracts-page">
        <p className="back-link">
          <Link href="/dashboard/contracts">← {t('back')}</Link>
        </p>
        <h1 id="page-title">{t('detail.metaTitle')}</h1>
        <p role="alert" className="form-error">
          {t('errors.loadError')}
        </p>
      </section>
    );
  }

  const window = actualsWindow(todayInGermany().slice(0, 7));
  const { fromDate, toDate } = rangeDates(window);
  const [actualRows, lastDebit] = await Promise.all([
    supabase.rpc('contract_actuals', { p_user_id: user.id, p_from: fromDate, p_to: toDate }),
    supabase
      .from('transactions')
      .select('booking_date, amount, currency')
      .eq('user_id', user.id)
      .eq('recurring_contract_id', contract.id)
      .lt('amount', 0)
      .order('booking_date', { ascending: false })
      .order('id', { ascending: false })
      .limit(1)
      .maybeSingle(),
  ]);
  if (actualRows.error || lastDebit.error) {
    console.error('[contracts] Abbuchungen des Vertrags nicht ladbar', { code: (actualRows.error ?? lastDebit.error)?.code });
  }
  const actual = actualRows.error
    ? null
    : (actualsByContract([contract], (actualRows.data ?? []) as ContractActualRow[]).get(contract.id) ?? {
        debitCount: 0,
        creditCount: 0,
        netCents: 0,
      });
  const annual = annualCents(contract.expected_amount, contract.rhythm, contract.interval_count);
  const monthShort = (month: string) =>
    format.dateTime(new Date(`${month}-01T00:00:00Z`), { month: 'short', year: 'numeric', timeZone: 'UTC' });

  const money = (amount: number | null, currency: string) =>
    amount === null ? t('notSet') : format.number(Math.abs(amount), { style: 'currency', currency });
  const date = (value: string | null) =>
    value
      ? format.dateTime(new Date(`${value}T00:00:00Z`), { dateStyle: 'medium', timeZone: 'UTC' })
      : t('notSet');

  const param = (name: string) => typeof query[name] === 'string';
  const notice = param('error')
    ? null
    : param('created')
      ? t('messages.created')
      : param('saved')
        ? t('messages.saved')
        : param('unlinked')
          ? t('messages.unlinked')
          : param('linked')
            ? t('messages.linked')
            : null;

  const initialValues: ContractFormValues = {
    name: contract.name,
    counterpartyKey: contract.counterparty_key ?? '',
    counterpartyName: contract.counterparty_name ?? '',
    rhythm: rhythmKey(contract.rhythm, contract.interval_count) ?? 'monthly',
    amount: contract.expected_amount === null ? '' : formatAmountInput(contract.expected_amount, locale),
    nextDate: contract.next_expected_date ?? '',
    type: contract.contract_type,
    accountId: contract.account_id ?? '',
    categoryId: contract.category_id ?? '',
    notes: contract.notes ?? '',
  };

  return (
    <section aria-labelledby="page-title" className="contracts-page">
      <p className="back-link">
        <Link href="/dashboard/contracts">← {t('back')}</Link>
      </p>
      <div className="contract-detail-header">
        <h1 id="page-title">{contract.name}</h1>
        <span className={`badge contract-status contract-status-${contract.status}`}>{labels.status(contract.status)}</span>
      </div>

      {param('error') ? (
        <p role="alert" className="form-error">
          {t('errors.generic')}
        </p>
      ) : notice ? (
        <p role="status" className="form-success">
          {notice}
        </p>
      ) : null}

      <dl className="contract-facts">
        <div>
          <dt>{t('fields.counterparty')}</dt>
          <dd>{contract.counterparty_name ?? t('notSet')}</dd>
        </div>
        <div>
          <dt>{t('fields.type')}</dt>
          <dd>{labels.type(contract.contract_type)}</dd>
        </div>
        <div>
          <dt>{t('fields.rhythm')}</dt>
          <dd>{labels.rhythm(contract.rhythm, contract.interval_count)}</dd>
        </div>
        <div>
          <dt>{t('fields.amount')}</dt>
          <dd>{money(contract.expected_amount, contract.currency)}</dd>
        </div>
        <div>
          <dt>{t('fields.next')}</dt>
          <dd>{date(contract.next_expected_date)}</dd>
        </div>
        <div>
          <dt>{t('fields.last')}</dt>
          <dd>
            {lastDebit.data
              ? t('detail.lastValue', {
                  date: date(lastDebit.data.booking_date),
                  amount: money(lastDebit.data.amount, lastDebit.data.currency),
                })
              : t('notSet')}
          </dd>
        </div>
        <div>
          <dt>{t('fields.first')}</dt>
          <dd>{date(contract.first_booking_date)}</dd>
        </div>
        <div>
          <dt>{t('fields.account')}</dt>
          <dd>{contract.account?.name ?? t('notSet')}</dd>
        </div>
        <div>
          <dt>{t('fields.category')}</dt>
          <dd>{contract.category ? categoryDisplayName(contract.category, tCategories) : t('notSet')}</dd>
        </div>
        <div>
          <dt>{t('fields.annual')}</dt>
          <dd>
            {annual === null || contract.expected_amount === null
              ? t('notSet')
              : t('detail.annualValue', {
                  amount: format.number(annual / 100, { style: 'currency', currency: contract.currency }),
                  count: format.number(paymentsPerYear(contract.rhythm, contract.interval_count), { maximumFractionDigits: 2 }),
                  single: money(contract.expected_amount, contract.currency),
                })}
          </dd>
        </div>
        <div>
          <dt>{t('fields.actual', { window: t('costs.window', { from: monthShort(window.from), to: monthShort(window.to) }) })}</dt>
          <dd>
            {actual === null
              ? t('notSet')
              : t('detail.actualValue', {
                  amount: format.number(actual.netCents / 100, { style: 'currency', currency: contract.currency }),
                  debits: actual.debitCount,
                  credits: actual.creditCount,
                })}
          </dd>
        </div>
      </dl>
      {contract.notes ? <p className="contract-card-sub">{contract.notes}</p> : null}

      {/* Neuer Schlüssel je Server-Render, siehe ../page.tsx. */}
      <Suspense key={crypto.randomUUID()} fallback={<ContractsSkeleton variant="detail" />}>
        <ContractBookings
          contract={{
            id: contract.id,
            name: contract.name,
            counterpartyKey: contract.counterparty_key,
          }}
          userId={user.id}
          initialValues={initialValues}
        />
      </Suspense>

      <details className="contract-danger">
        <summary>{t('detail.delete')}</summary>
        <p>{t('detail.deleteConfirm')}</p>
        <ActionForm action={deleteContract.bind(null, contract.id)}>
          <button type="submit" className="button button-danger button-small">
            {t('detail.deleteButton')}
          </button>
        </ActionForm>
      </details>
    </section>
  );
}
