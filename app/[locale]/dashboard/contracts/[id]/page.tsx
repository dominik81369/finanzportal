/**
 * app/[locale]/dashboard/contracts/[id]/page.tsx
 *
 * Ein Vertrag: Angaben und Status-Aktionen (Vorschlag bestätigen/verwerfen,
 * erkannten Vertrag verwerfen, wiederherstellen, manuellen löschen) sofort;
 * verknüpfte Buchungen und Bearbeiten gestreamt (contract-bookings.tsx).
 *
 * Nur eigene Verträge (user_id = eigener Nutzer); für Berater und fremde
 * IDs ist die Seite ein 404. Die RPCs prüfen Eigentum zusätzlich selbst.
 */
import type { Metadata } from 'next';
import { notFound } from 'next/navigation';
import { getFormatter, getLocale, getTranslations } from 'next-intl/server';
import { Suspense } from 'react';

import { Link } from '@/i18n/navigation';
import { toAppLocale } from '@/i18n/routing';
import { confirmContract, deleteContract, dismissContract, restoreContract } from '@/lib/actions/contracts';
import { categoryDisplayName } from '@/lib/categories';
import { getContractLabels } from '@/lib/contract-labels';
import { CONTRACT_TYPES, rhythmKey, type ContractFormValues } from '@/lib/contracts';
import { createClient, requireOnboardedUser } from '@/lib/supabase/server';
import { formatAmountInput, isUuid } from '@/lib/transactions';

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
       amount_tolerance_pct, currency, first_booking_date, last_booking_date, next_expected_date, status,
       detection_source, detection_confidence, notes, account_id, category_id,
       account:accounts!recurring_contracts_account_fkey ( name ),
       category:categories!recurring_contracts_category_fkey ( name, default_key )`,
    )
    .eq('id', id)
    .eq('user_id', user.id)
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

  const editable = ['active', 'cancellation_pending', 'cancelled'].includes(contract.status);
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
    tolerance: String(Number(contract.amount_tolerance_pct)),
    notes: contract.notes ?? '',
  };
  const auto = contract.detection_source === 'auto';

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
          <dd>
            {money(contract.expected_amount, contract.currency)}
            <span className="cell-note">
              {' '}
              {t('detail.tolerance', { pct: Number(contract.amount_tolerance_pct) })}
            </span>
          </dd>
        </div>
        <div>
          <dt>{t('fields.next')}</dt>
          <dd>{date(contract.next_expected_date)}</dd>
        </div>
        <div>
          <dt>{t('fields.last')}</dt>
          <dd>{date(contract.last_booking_date)}</dd>
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
          <dt>{t('fields.source')}</dt>
          <dd>
            {auto
              ? t('detail.sourceAuto', { level: labels.confidence(contract.detection_confidence) })
              : t('detail.sourceManual')}
          </dd>
        </div>
      </dl>
      {contract.notes ? <p className="contract-card-sub">{contract.notes}</p> : null}

      <div className="contract-actions">
        {contract.status === 'suggested' ? (
          <>
            <ActionForm action={confirmContract.bind(null, contract.id)}>
              <label htmlFor="detail-type">
                {t('fields.type')}
                <select id="detail-type" name="type" defaultValue={contract.contract_type}>
                  {CONTRACT_TYPES.map((type) => (
                    <option key={type} value={type}>
                      {labels.type(type)}
                    </option>
                  ))}
                </select>
              </label>
              <button type="submit" className="button button-small">
                {t('suggestions.confirm')}
              </button>
            </ActionForm>
            <ActionForm action={dismissContract.bind(null, contract.id)}>
              <button type="submit" className="button button-secondary button-small">
                {t('suggestions.dismiss')}
              </button>
            </ActionForm>
          </>
        ) : null}
        {contract.status === 'active' && auto ? (
          <ActionForm action={dismissContract.bind(null, contract.id)}>
            <button type="submit" className="button button-secondary button-small">
              {t('detail.dismissActive')}
            </button>
          </ActionForm>
        ) : null}
        {contract.status === 'dismissed' && auto ? (
          <ActionForm action={restoreContract.bind(null, contract.id)}>
            <button type="submit" className="button button-secondary button-small">
              {t('dismissed.restore')}
            </button>
          </ActionForm>
        ) : null}
      </div>

      {/* Neuer Schlüssel je Server-Render, siehe ../page.tsx. */}
      <Suspense key={crypto.randomUUID()} fallback={<ContractsSkeleton variant="detail" />}>
        <ContractBookings
          contract={{
            id: contract.id,
            name: contract.name,
            status: contract.status,
            counterpartyKey: contract.counterparty_key,
          }}
          userId={user.id}
          editable={editable}
          initialValues={initialValues}
        />
      </Suspense>

      {contract.detection_source === 'manual' ? (
        <details className="contract-danger">
          <summary>{t('detail.delete')}</summary>
          <p>{t('detail.deleteConfirm')}</p>
          <ActionForm action={deleteContract.bind(null, contract.id)}>
            <button type="submit" className="button button-danger button-small">
              {t('detail.deleteButton')}
            </button>
          </ActionForm>
        </details>
      ) : null}
    </section>
  );
}
