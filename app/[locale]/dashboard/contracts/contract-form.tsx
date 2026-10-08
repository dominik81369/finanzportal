'use client';

/**
 * Vertragsformular für Anlegen (./new) und Bearbeiten (./[id]). Die Server
 * Action kommt als Prop: saveContract.bind(null, null | id); nach Erfolg
 * navigiert das Formular zur gelieferten Detailseite.
 *
 * Gegenpartei: Auswahl aus den eigenen Buchungen (verknüpft über denselben
 * Schlüssel wie die Erkennung, auch über Zahlungsvermittler) oder frei
 * eingegeben. Die Auswahl belegt leere Felder Name und Betrag vor.
 */
import { useLocale, useTranslations } from 'next-intl';
import { startTransition, useActionState, useEffect, useState, type FormEvent, type ReactNode } from 'react';

import type { ContractFormState } from '@/lib/actions/contracts';
import {
  CONTRACT_COUNTERPARTY_MAX_LENGTH,
  CONTRACT_NAME_MAX_LENGTH,
  CONTRACT_NOTES_MAX_LENGTH,
  CONTRACT_TYPES,
  DEFAULT_TOLERANCE_PCT,
  MAX_TOLERANCE_PCT,
  RHYTHM_KEYS,
  type ContractField,
  type ContractFormValues,
} from '@/lib/contracts';

import { CategorySelect } from '../transactions/category-select';
import type { CategoryOption } from '../transactions/transaction-form';
import { useShowResult } from './action-form';

export type CounterpartyOption = { key: string; label: string; count: number; lastAmount: number };

type ContractFormProps = {
  mode: 'create' | 'edit';
  action: (prevState: ContractFormState, formData: FormData) => Promise<ContractFormState>;
  counterparties: CounterpartyOption[];
  accounts: { id: string; name: string }[];
  categories: CategoryOption[];
  initialValues?: ContractFormValues;
};

const initialState: ContractFormState = { status: 'idle' };

export function ContractForm({ mode, action, counterparties, accounts, categories, initialValues }: ContractFormProps) {
  const t = useTranslations('Contracts');
  const locale = useLocale();
  const showResult = useShowResult();
  const [state, formAction, isPending] = useActionState(action, initialState);
  const values = state.values ?? initialValues;

  // Nach dem Speichern zur Detailseite (die Action leitet nicht selbst weiter,
  // siehe action-form.tsx).
  useEffect(() => {
    const { status, redirectTo } = state;
    if (status === 'success' && redirectTo) {
      startTransition(() => showResult(redirectTo));
    }
  }, [state, showResult]);
  const fieldErrors = state.fieldErrors ?? {};

  // Kontrolliert, weil die Auswahl der Gegenpartei Name und Betrag vorbelegt.
  const [counterpartyKey, setCounterpartyKey] = useState(values?.counterpartyKey ?? '');
  const [name, setName] = useState(values?.name ?? '');
  const [amount, setAmount] = useState(values?.amount ?? '');
  const amountInput = (value: number) =>
    new Intl.NumberFormat(locale, { minimumFractionDigits: 2, maximumFractionDigits: 2, useGrouping: false }).format(value);
  // Gespeicherter Schlüssel ohne Buchungen: als eigene Option anbieten.
  const options =
    counterpartyKey !== '' && !counterparties.some((c) => c.key === counterpartyKey)
      ? [{ key: counterpartyKey, label: values?.counterpartyName || counterpartyKey, count: 0, lastAmount: 0 }, ...counterparties]
      : counterparties;

  const errorProps = (field: ContractField, id: string, hintId?: string) => {
    const describedBy = [fieldErrors[field] ? `${id}-error` : null, hintId].filter(Boolean).join(' ');
    return {
      'aria-invalid': fieldErrors[field] ? true : undefined,
      'aria-describedby': describedBy || undefined,
    };
  };
  const fieldError = (field: ContractField, id: string): ReactNode =>
    fieldErrors[field] ? (
      <p id={`${id}-error`} className="field-error">
        {fieldErrors[field]}
      </p>
    ) : null;

  // Ohne automatisches Zurücksetzen absenden (Auswahllisten behalten ihren
  // Wert nach einem Fehler); ohne JS greift action={formAction}.
  const handleSubmit = (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    const formData = new FormData(event.currentTarget);
    startTransition(() => formAction(formData));
  };

  return (
    <form action={formAction} onSubmit={handleSubmit} className="form contract-form">
      {state.status === 'error' && state.message ? (
        <p role="alert" className="form-error">
          {state.message}
        </p>
      ) : null}

      <label htmlFor="contract-counterparty">{t('form.counterparty')}</label>
      <select
        id="contract-counterparty"
        name="counterparty_key"
        value={counterpartyKey}
        onChange={(event) => {
          const key = event.target.value;
          setCounterpartyKey(key);
          const option = counterparties.find((c) => c.key === key);
          if (option && name.trim() === '') {
            setName(option.label);
          }
          if (option && amount.trim() === '' && option.lastAmount > 0) {
            setAmount(amountInput(option.lastAmount));
          }
        }}
        {...errorProps('counterparty', 'contract-counterparty', 'contract-counterparty-hint')}
      >
        <option value="">{t('form.counterpartyNone')}</option>
        {options.map((option) => (
          <option key={option.key} value={option.key}>
            {option.count > 0 ? t('form.counterpartyOption', { label: option.label, count: option.count }) : option.label}
          </option>
        ))}
      </select>
      <p id="contract-counterparty-hint" className="hint">
        {t('form.counterpartyHint')}
      </p>
      {counterpartyKey === '' ? (
        <>
          <label htmlFor="contract-counterparty-name">{t('form.counterpartyFree')}</label>
          <input
            id="contract-counterparty-name"
            name="counterparty_name"
            type="text"
            maxLength={CONTRACT_COUNTERPARTY_MAX_LENGTH}
            defaultValue={values?.counterpartyName ?? ''}
            {...errorProps('counterparty', 'contract-counterparty-name')}
          />
        </>
      ) : null}
      {fieldError('counterparty', 'contract-counterparty')}

      <label htmlFor="contract-name">{t('form.name')}</label>
      <input
        id="contract-name"
        name="name"
        type="text"
        required
        maxLength={CONTRACT_NAME_MAX_LENGTH}
        value={name}
        onChange={(event) => setName(event.target.value)}
        {...errorProps('name', 'contract-name')}
      />
      {fieldError('name', 'contract-name')}

      <label htmlFor="contract-type">{t('fields.type')}</label>
      <select id="contract-type" name="type" defaultValue={values?.type ?? 'other'} {...errorProps('type', 'contract-type')}>
        {CONTRACT_TYPES.map((type) => (
          <option key={type} value={type}>
            {t(`types.${type}`)}
          </option>
        ))}
      </select>
      {fieldError('type', 'contract-type')}

      <label htmlFor="contract-rhythm">{t('fields.rhythm')}</label>
      <select
        id="contract-rhythm"
        name="rhythm"
        defaultValue={values?.rhythm || 'monthly'}
        {...errorProps('rhythm', 'contract-rhythm')}
      >
        {RHYTHM_KEYS.map((key) => (
          <option key={key} value={key}>
            {t(`rhythms.${key}`)}
          </option>
        ))}
      </select>
      {fieldError('rhythm', 'contract-rhythm')}

      <label htmlFor="contract-amount">{t('form.amount')}</label>
      <input
        id="contract-amount"
        name="amount"
        type="text"
        inputMode="decimal"
        autoComplete="off"
        required
        maxLength={20}
        value={amount}
        onChange={(event) => setAmount(event.target.value)}
        {...errorProps('amount', 'contract-amount', 'contract-amount-hint')}
      />
      <p id="contract-amount-hint" className="hint">
        {t('form.amountHint')}
      </p>
      {fieldError('amount', 'contract-amount')}

      <label htmlFor="contract-next">{t('fields.next')}</label>
      <input
        id="contract-next"
        name="next_date"
        type="date"
        defaultValue={values?.nextDate ?? ''}
        {...errorProps('nextDate', 'contract-next', 'contract-next-hint')}
      />
      <p id="contract-next-hint" className="hint">
        {t('form.nextHint')}
      </p>
      {fieldError('nextDate', 'contract-next')}

      <label htmlFor="contract-account">{t('fields.account')}</label>
      <select
        id="contract-account"
        name="account"
        defaultValue={values?.accountId ?? ''}
        {...errorProps('account', 'contract-account', 'contract-account-hint')}
      >
        <option value="">{t('form.noAccount')}</option>
        {accounts.map((account) => (
          <option key={account.id} value={account.id}>
            {account.name}
          </option>
        ))}
      </select>
      <p id="contract-account-hint" className="hint">
        {t('form.accountHint')}
      </p>
      {fieldError('account', 'contract-account')}

      <label htmlFor="contract-category">{t('fields.category')}</label>
      <CategorySelect
        id="contract-category"
        name="category"
        categories={categories}
        defaultValue={values?.categoryId ?? ''}
        emptyLabel={t('form.noCategory')}
      />
      {fieldError('category', 'contract-category')}

      <label htmlFor="contract-tolerance">{t('form.tolerance')}</label>
      <input
        id="contract-tolerance"
        name="tolerance"
        type="number"
        min={0}
        max={MAX_TOLERANCE_PCT}
        step={1}
        defaultValue={values?.tolerance || String(DEFAULT_TOLERANCE_PCT)}
        {...errorProps('tolerance', 'contract-tolerance', 'contract-tolerance-hint')}
      />
      <p id="contract-tolerance-hint" className="hint">
        {t('form.toleranceHint')}
      </p>
      {fieldError('tolerance', 'contract-tolerance')}

      <label htmlFor="contract-notes">{t('fields.notes')}</label>
      <textarea
        id="contract-notes"
        name="notes"
        rows={3}
        maxLength={CONTRACT_NOTES_MAX_LENGTH}
        defaultValue={values?.notes ?? ''}
        {...errorProps('notes', 'contract-notes')}
      />
      {fieldError('notes', 'contract-notes')}

      <button type="submit" disabled={isPending || state.status === 'success'}>
        {isPending || state.status === 'success'
          ? t('form.saving')
          : mode === 'create'
            ? t('form.create')
            : t('form.save')}
      </button>
    </form>
  );
}
