/**
 * lib/contracts.ts
 *
 * Verträge: Rhythmen, Vertragstypen, angezeigte Status und die Prüfung des
 * Vertragsformulars. Reine Funktionen ohne Server-Abhängigkeiten
 * (Client, Server Actions, Unit-Tests).
 *
 * Rhythmus in der Datenbank: rhythm + interval_count (14-tägig = weekly ×2,
 * zweimonatlich = monthly ×2), siehe private.rhythm_bands() in
 * supabase/migrations/20261010100000_contracts_v1.sql.
 */
import type { AppLocale } from '@/i18n/routing';
import type { Database } from '@/types/database';

import { parseAmountInput, parseIsoDate } from '@/lib/transactions';

export type ContractRhythm = Database['public']['Enums']['contract_rhythm'];
export type ContractType = Database['public']['Enums']['contract_type'];
export type ContractStatus = Database['public']['Enums']['contract_status'];

export const RHYTHM_KEYS = [
  'weekly',
  'biweekly',
  'monthly',
  'bimonthly',
  'quarterly',
  'semiannual',
  'yearly',
] as const;
export type RhythmKey = (typeof RHYTHM_KEYS)[number];

const RHYTHM_PARTS: Record<RhythmKey, { rhythm: ContractRhythm; intervalCount: number }> = {
  weekly: { rhythm: 'weekly', intervalCount: 1 },
  biweekly: { rhythm: 'weekly', intervalCount: 2 },
  monthly: { rhythm: 'monthly', intervalCount: 1 },
  bimonthly: { rhythm: 'monthly', intervalCount: 2 },
  quarterly: { rhythm: 'quarterly', intervalCount: 1 },
  semiannual: { rhythm: 'semiannual', intervalCount: 1 },
  yearly: { rhythm: 'yearly', intervalCount: 1 },
};

/** Reihenfolge in Auswahllisten; „Sonstiges“ zuletzt. */
export const CONTRACT_TYPES: readonly ContractType[] = [
  'subscription',
  'telecom',
  'energy',
  'insurance',
  'housing',
  'loan',
  'membership',
  'public_fee',
  'savings',
  'other',
];

export const CONTRACT_NAME_MAX_LENGTH = 120;
export const CONTRACT_COUNTERPARTY_MAX_LENGTH = 200;
export const CONTRACT_NOTES_MAX_LENGTH = 2000;

/**
 * Status der angezeigten Verträge. Vorschläge und verworfene Verträge der
 * früheren Erkennung bleiben in der Datenbank, erscheinen aber nirgends
 * (supabase/migrations/20261014100000_contracts_cleanup.sql).
 */
export const LISTED_CONTRACT_STATUSES = ['active', 'cancellation_pending', 'cancelled'] as const satisfies readonly ContractStatus[];

export function isRhythmKey(value: string): value is RhythmKey {
  return (RHYTHM_KEYS as readonly string[]).includes(value);
}

export function isContractType(value: string): value is ContractType {
  return (CONTRACT_TYPES as readonly string[]).includes(value);
}

export function rhythmParts(key: RhythmKey): { rhythm: ContractRhythm; intervalCount: number } {
  return RHYTHM_PARTS[key];
}

/** Schlüssel für Anzeige und Formular; null bei anderen Kombinationen (z. B. alle 3 Monate). */
export function rhythmKey(rhythm: ContractRhythm, intervalCount: number): RhythmKey | null {
  const match = RHYTHM_KEYS.find(
    (key) => RHYTHM_PARTS[key].rhythm === rhythm && RHYTHM_PARTS[key].intervalCount === intervalCount,
  );
  return match ?? null;
}

/** Gegenpartei-Schlüssel wie transactions.counterparty_key (i:/m:/n:). */
export function isCounterpartyKey(value: string): boolean {
  return value.length <= 300 && /^[imn]:./.test(value);
}

// ---------------------------------------------------------------------
// Formular
// ---------------------------------------------------------------------

export type ContractField =
  | 'name'
  | 'counterparty'
  | 'rhythm'
  | 'amount'
  | 'nextDate'
  | 'type'
  | 'account'
  | 'category'
  | 'notes';

export type ContractFieldError =
  | 'nameRequired'
  | 'nameTooLong'
  | 'counterpartyTooLong'
  | 'counterpartyInvalid'
  | 'rhythmInvalid'
  | 'amountInvalid'
  | 'dateInvalid'
  | 'typeInvalid'
  | 'selectionInvalid'
  | 'notesTooLong';

/** Formularwerte als Strings – zum Vorbelegen (Bearbeiten, nach Fehlern). */
export type ContractFormValues = {
  name: string;
  counterpartyKey: string;
  counterpartyName: string;
  rhythm: string;
  amount: string;
  nextDate: string;
  type: string;
  accountId: string;
  categoryId: string;
  notes: string;
};

export type ContractRpcParams = {
  p_name: string;
  p_counterparty_key: string | null;
  p_counterparty_name: string | null;
  p_rhythm: ContractRhythm;
  p_interval_count: number;
  p_amount: number;
  p_next_expected_date: string | null;
  p_contract_type: ContractType;
  p_account_id: string | null;
  p_category_id: string | null;
  p_notes: string | null;
};

export type ParsedContractForm =
  | { ok: true; values: ContractFormValues; params: ContractRpcParams }
  | { ok: false; values: ContractFormValues; errors: Partial<Record<ContractField, ContractFieldError>> };

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

type FormLike = { get(name: string): FormDataEntryValue | null };

/** Formular prüfen und in Parameter für public.save_contract() umsetzen. */
export function parseContractForm(formData: FormLike, locale: AppLocale): ParsedContractForm {
  const text = (name: string) => String(formData.get(name) ?? '');
  const values: ContractFormValues = {
    name: text('name').trim().replace(/\s+/g, ' '),
    counterpartyKey: text('counterparty_key').trim(),
    counterpartyName: text('counterparty_name').trim().replace(/\s+/g, ' '),
    rhythm: text('rhythm'),
    amount: text('amount').trim(),
    nextDate: text('next_date').trim(),
    type: text('type'),
    accountId: text('account'),
    categoryId: text('category'),
    notes: text('notes').trim(),
  };
  const errors: Partial<Record<ContractField, ContractFieldError>> = {};

  if (values.name.length === 0) {
    errors.name = 'nameRequired';
  } else if (values.name.length > CONTRACT_NAME_MAX_LENGTH) {
    errors.name = 'nameTooLong';
  }
  if (values.counterpartyKey !== '' && !isCounterpartyKey(values.counterpartyKey)) {
    errors.counterparty = 'counterpartyInvalid';
  } else if (values.counterpartyName.length > CONTRACT_COUNTERPARTY_MAX_LENGTH) {
    errors.counterparty = 'counterpartyTooLong';
  }
  if (!isRhythmKey(values.rhythm)) {
    errors.rhythm = 'rhythmInvalid';
  }
  const amount = parseAmountInput(values.amount, locale);
  if (amount === null) {
    errors.amount = 'amountInvalid';
  }
  const nextDate = values.nextDate === '' ? null : parseIsoDate(values.nextDate);
  if (values.nextDate !== '' && nextDate === null) {
    errors.nextDate = 'dateInvalid';
  }
  if (!isContractType(values.type)) {
    errors.type = 'typeInvalid';
  }
  if (values.accountId !== '' && !UUID.test(values.accountId)) {
    errors.account = 'selectionInvalid';
  }
  if (values.categoryId !== '' && !UUID.test(values.categoryId)) {
    errors.category = 'selectionInvalid';
  }
  if (values.notes.length > CONTRACT_NOTES_MAX_LENGTH) {
    errors.notes = 'notesTooLong';
  }

  if (Object.keys(errors).length > 0 || amount === null || !isRhythmKey(values.rhythm) || !isContractType(values.type)) {
    return { ok: false, values, errors };
  }
  const { rhythm, intervalCount } = rhythmParts(values.rhythm);
  return {
    ok: true,
    values,
    params: {
      p_name: values.name,
      p_counterparty_key: values.counterpartyKey === '' ? null : values.counterpartyKey,
      // Freie Gegenpartei nur ohne Auswahl aus den Buchungen.
      p_counterparty_name: values.counterpartyKey === '' && values.counterpartyName !== '' ? values.counterpartyName : null,
      p_rhythm: rhythm,
      p_interval_count: intervalCount,
      p_amount: amount,
      p_next_expected_date: nextDate,
      p_contract_type: values.type,
      p_account_id: values.accountId === '' ? null : values.accountId,
      p_category_id: values.categoryId === '' ? null : values.categoryId,
      p_notes: values.notes === '' ? null : values.notes,
    },
  };
}
