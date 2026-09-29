'use client';

import { useTranslations } from 'next-intl';
import { startTransition, useActionState, useState, type FormEvent, type ReactNode } from 'react';

import {
  createTransaction,
  type CreateTransactionState,
  type TransactionField,
  type TransactionType,
} from '@/lib/actions/create-transaction';
import { COUNTERPARTY_MAX_LENGTH, PURPOSE_MAX_LENGTH } from '@/lib/transactions';
import type { Account, Category, Tag } from '@/types/domain';

export type CategoryOption = { id: string; kind: Category['kind']; label: string };

type TransactionFormProps = {
  accounts: Pick<Account, 'id' | 'name' | 'currency'>[];
  categories: CategoryOption[];
  tags: Pick<Tag, 'id' | 'name'>[];
  /** Vorbelegung des Datums (YYYY-MM-DD, deutsche Zeitzone). */
  today: string;
};

const initialState: CreateTransactionState = { status: 'idle' };

/** Welche Kategoriearten zur Buchungsart passen (wie create_manual_transaction()). */
const KINDS_FOR_TYPE: Record<TransactionType, readonly Category['kind'][]> = {
  expense: ['expense', 'transfer'],
  income: ['income', 'transfer'],
};

export function TransactionForm({ accounts, categories, tags, today }: TransactionFormProps) {
  const t = useTranslations('Transactions.form');
  const [state, formAction, isPending] = useActionState(createTransaction, initialState);
  const values = state.values;
  const fieldErrors = state.fieldErrors ?? {};

  // Kontrolliert, weil Art und Konto die Kategorieauswahl bzw. den
  // Währungshinweis steuern.
  const [type, setType] = useState<TransactionType>(values?.type ?? 'expense');
  const [accountId, setAccountId] = useState(values?.accountId ?? accounts[0]?.id ?? '');
  const [categoryId, setCategoryId] = useState(values?.categoryId ?? '');
  const currency = accounts.find((a) => a.id === accountId)?.currency ?? 'EUR';

  const errorProps = (field: TransactionField, id: string, hintId?: string) => {
    const describedBy = [fieldErrors[field] ? `${id}-error` : null, hintId].filter(Boolean).join(' ');
    return {
      'aria-invalid': fieldErrors[field] ? true : undefined,
      'aria-describedby': describedBy || undefined,
    };
  };
  const fieldError = (field: TransactionField, id: string): ReactNode =>
    fieldErrors[field] ? (
      <p id={`${id}-error`} className="field-error">
        {fieldErrors[field]}
      </p>
    ) : null;

  // React setzt ein <form action> nach jeder Action zurück – auch nach einem
  // Validierungsfehler, und Auswahllisten verlören dabei ihren Wert. Mit JS
  // daher selbst absenden (kein automatisches Zurücksetzen); ohne JS greift
  // weiterhin action={formAction}.
  const handleSubmit = (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    const formData = new FormData(event.currentTarget);
    startTransition(() => formAction(formData));
  };

  const allowedKinds = KINDS_FOR_TYPE[type];
  const categoryGroups = (['expense', 'income', 'transfer'] as const)
    .filter((kind) => allowedKinds.includes(kind))
    .map((kind) => ({ kind, options: categories.filter((c) => c.kind === kind) }))
    .filter((group) => group.options.length > 0);

  return (
    <form action={formAction} onSubmit={handleSubmit} className="form">
      {state.status === 'error' && state.message ? (
        <p role="alert" className="form-error">
          {state.message}
        </p>
      ) : null}

      <fieldset className="choice-group" {...errorProps('type', 'type')}>
        <legend>{t('type')}</legend>
        {(['expense', 'income'] as const).map((option) => (
          <label key={option} className="choice">
            <input
              type="radio"
              name="type"
              value={option}
              checked={type === option}
              onChange={() => {
                setType(option);
                // Eine Kategorie der anderen Art wäre ungültig.
                const kind = categories.find((c) => c.id === categoryId)?.kind;
                if (kind && !KINDS_FOR_TYPE[option].includes(kind)) {
                  setCategoryId('');
                }
              }}
            />
            {t(option)}
          </label>
        ))}
      </fieldset>
      {fieldError('type', 'type')}

      <label htmlFor="amount">{t('amount')}</label>
      <input
        id="amount"
        name="amount"
        type="text"
        inputMode="decimal"
        autoComplete="off"
        required
        maxLength={20}
        defaultValue={values?.amount ?? ''}
        {...errorProps('amount', 'amount', 'amount-hint')}
      />
      <p id="amount-hint" className="hint">
        {t('amountHint', { currency })}
      </p>
      {fieldError('amount', 'amount')}

      <label htmlFor="booking_date">{t('date')}</label>
      <input
        id="booking_date"
        name="booking_date"
        type="date"
        required
        defaultValue={values?.bookingDate ?? today}
        {...errorProps('bookingDate', 'booking_date')}
      />
      {fieldError('bookingDate', 'booking_date')}

      <label htmlFor="counterparty">{t('counterparty')}</label>
      <input
        id="counterparty"
        name="counterparty"
        type="text"
        required
        maxLength={COUNTERPARTY_MAX_LENGTH}
        defaultValue={values?.counterparty ?? ''}
        {...errorProps('counterparty', 'counterparty')}
      />
      {fieldError('counterparty', 'counterparty')}

      <label htmlFor="purpose">{t('purpose')}</label>
      <textarea
        id="purpose"
        name="purpose"
        rows={2}
        maxLength={PURPOSE_MAX_LENGTH}
        defaultValue={values?.purpose ?? ''}
        {...errorProps('purpose', 'purpose')}
      />
      {fieldError('purpose', 'purpose')}

      {accounts.length > 0 ? (
        <>
          <label htmlFor="account_id">{t('account')}</label>
          <select
            id="account_id"
            name="account_id"
            value={accountId}
            onChange={(event) => setAccountId(event.target.value)}
            {...errorProps('account', 'account_id')}
          >
            {accounts.map((account) => (
              <option key={account.id} value={account.id}>
                {account.name}
              </option>
            ))}
          </select>
          {fieldError('account', 'account_id')}
        </>
      ) : (
        <p className="hint">{t('noAccountHint')}</p>
      )}

      <label htmlFor="category_id">{t('category')}</label>
      <select
        id="category_id"
        name="category_id"
        value={categoryId}
        onChange={(event) => setCategoryId(event.target.value)}
        {...errorProps('category', 'category_id')}
      >
        <option value="">{t('noCategory')}</option>
        {categoryGroups.map((group) => (
          <optgroup key={group.kind} label={t(`categoryGroups.${group.kind}`)}>
            {group.options.map((category) => (
              <option key={category.id} value={category.id}>
                {category.label}
              </option>
            ))}
          </optgroup>
        ))}
      </select>
      {fieldError('category', 'category_id')}

      <fieldset className="tag-group" {...errorProps('tags', 'tags', 'new_tags-hint')}>
        <legend>{t('tags')}</legend>
        {tags.length > 0 ? (
          <div className="tag-options">
            {tags.map((tag) => (
              <label key={tag.id} className="tag-option">
                <input
                  type="checkbox"
                  name="tag_ids"
                  value={tag.id}
                  defaultChecked={values?.tagIds.includes(tag.id) ?? false}
                />
                {tag.name}
              </label>
            ))}
          </div>
        ) : null}
        <label htmlFor="new_tags">{t('newTags')}</label>
        <input
          id="new_tags"
          name="new_tags"
          type="text"
          autoComplete="off"
          maxLength={600}
          defaultValue={values?.newTags ?? ''}
          aria-describedby="new_tags-hint"
        />
        <p id="new_tags-hint" className="hint">
          {t('newTagsHint')}
        </p>
      </fieldset>
      {fieldError('tags', 'tags')}

      <button type="submit" disabled={isPending}>
        {isPending ? t('submitting') : t('submit')}
      </button>
    </form>
  );
}
