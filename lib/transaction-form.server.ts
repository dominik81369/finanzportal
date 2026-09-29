/**
 * lib/transaction-form.server.ts
 *
 * Gemeinsame Serverlogik für das Anlegen und Bearbeiten von Buchungen:
 * FormData prüfen und in RPC-Parameter übersetzen, RPC-Fehler in Meldungen.
 * Genutzt von lib/actions/create-transaction.ts und update-transaction.ts.
 */
import 'server-only';

import type { PostgrestError } from '@supabase/supabase-js';
import { getLocale, getTranslations } from 'next-intl/server';

import { isSupportedCurrency } from '@/lib/currency';
import type { TransactionFormState, TransactionFormValues } from '@/lib/transaction-form-types';
import {
  COUNTERPARTY_MAX_LENGTH,
  NEW_TAGS_MAX,
  PURPOSE_MAX_LENGTH,
  TAG_NAME_MAX_LENGTH,
  TAGS_PER_TRANSACTION_MAX,
  isUuid,
  parseAmountInput,
  parseIsoDate,
  parseTagNames,
} from '@/lib/transactions';
import { readTrimmed } from '@/lib/validation';
import type { Database } from '@/types/database';

/** Parameter von create_/update_manual_transaction() ohne p_id. */
export type ManualTransactionParams = Database['public']['Functions']['create_manual_transaction']['Args'];

type ErrorsTranslator = Awaited<ReturnType<typeof getTranslations<'Transactions.errors'>>>;

type ParseResult =
  | { ok: true; values: TransactionFormValues; params: ManualTransactionParams }
  | { ok: false; state: TransactionFormState };

/** Prüft das Buchungsformular (Beträge in der Schreibweise der Seitensprache). */
export async function parseTransactionForm(formData: FormData): Promise<ParseResult> {
  const locale = await getLocale();
  const t = await getTranslations('Transactions.errors');
  const tValidation = await getTranslations('Validation');

  const rawType = readTrimmed(formData, 'type');
  const values: TransactionFormValues = {
    type: rawType === 'income' ? 'income' : 'expense',
    amount: readTrimmed(formData, 'amount'),
    currency: readTrimmed(formData, 'currency'),
    bookingDate: readTrimmed(formData, 'booking_date'),
    counterparty: readTrimmed(formData, 'counterparty'),
    purpose: readTrimmed(formData, 'purpose'),
    accountId: readTrimmed(formData, 'account_id'),
    categoryId: readTrimmed(formData, 'category_id'),
    tagIds: formData.getAll('tag_ids').filter((v): v is string => typeof v === 'string'),
    newTags: readTrimmed(formData, 'new_tags'),
  };

  const fieldErrors: NonNullable<TransactionFormState['fieldErrors']> = {};

  if (rawType !== 'expense' && rawType !== 'income') {
    fieldErrors.type = t('typeInvalid');
  }
  const amount = parseAmountInput(values.amount, locale);
  if (amount === null) {
    fieldErrors.amount = t('amountInvalid');
  }
  // Leer → Kontowährung (Standard der RPC).
  if (values.currency && !isSupportedCurrency(values.currency)) {
    fieldErrors.currency = t('currencyInvalid');
  }
  const bookingDate = parseIsoDate(values.bookingDate);
  if (!bookingDate) {
    fieldErrors.bookingDate = t('dateInvalid');
  }
  if (values.counterparty.length === 0) {
    fieldErrors.counterparty = t('counterpartyRequired');
  } else if (values.counterparty.length > COUNTERPARTY_MAX_LENGTH) {
    fieldErrors.counterparty = tValidation('maxLength', { max: COUNTERPARTY_MAX_LENGTH });
  }
  if (values.purpose.length > PURPOSE_MAX_LENGTH) {
    fieldErrors.purpose = tValidation('maxLength', { max: PURPOSE_MAX_LENGTH });
  }
  // Unbekannte IDs meldet die RPC; hier nur offensichtlich kaputte Werte abfangen.
  if (values.accountId && !isUuid(values.accountId)) {
    fieldErrors.account = t('accountNotFound');
  }
  if (values.categoryId && !isUuid(values.categoryId)) {
    fieldErrors.category = t('categoryNotFound');
  }

  const tagIds = [...new Set(values.tagIds)];
  const newTagNames = parseTagNames(values.newTags);
  if (!tagIds.every(isUuid)) {
    fieldErrors.tags = t('tagNotFound');
  } else if (newTagNames.some((name) => name.length > TAG_NAME_MAX_LENGTH)) {
    fieldErrors.tags = t('tagTooLong', { max: TAG_NAME_MAX_LENGTH });
  } else if (
    newTagNames.length > NEW_TAGS_MAX ||
    tagIds.length + newTagNames.length > TAGS_PER_TRANSACTION_MAX
  ) {
    fieldErrors.tags = t('tooManyTags', {
      newMax: NEW_TAGS_MAX,
      totalMax: TAGS_PER_TRANSACTION_MAX,
    });
  }

  if (amount === null || !bookingDate || Object.keys(fieldErrors).length > 0) {
    return {
      ok: false,
      state: { status: 'error', message: tValidation('checkInput'), fieldErrors, values },
    };
  }

  return {
    ok: true,
    values,
    params: {
      p_booking_date: bookingDate,
      p_amount: values.type === 'expense' ? -amount : amount,
      p_counterparty_name: values.counterparty,
      p_purpose: values.purpose || undefined,
      p_account_id: values.accountId || undefined,
      p_category_id: values.categoryId || undefined,
      p_tag_ids: tagIds,
      p_new_tag_names: newTagNames,
      p_currency: values.currency || undefined,
    },
  };
}

/** Fachliche Fehler der RPCs (Exception-Message) → Formularzustand. */
export async function rpcErrorState(
  error: PostgrestError,
  values: TransactionFormValues,
  logPrefix: string,
): Promise<TransactionFormState> {
  const t = await getTranslations('Transactions.errors');
  const tValidation = await getTranslations('Validation');
  const fieldErrors = rpcFieldErrors(error, t);

  if (!fieldErrors) {
    console.error(`[${logPrefix}] RPC fehlgeschlagen`, { code: error.code });
  }
  return {
    status: 'error',
    message: fieldErrors ? tValidation('checkInput') : rpcMessage(error, t),
    fieldErrors: fieldErrors ?? undefined,
    values,
  };
}

function rpcFieldErrors(
  error: PostgrestError,
  t: ErrorsTranslator,
): TransactionFormState['fieldErrors'] | null {
  switch (error.message) {
    case 'invalid_amount':
      return { amount: t('amountInvalid') };
    case 'invalid_currency':
      return { currency: t('currencyInvalid') };
    case 'invalid_booking_date':
      return { bookingDate: t('dateInvalid') };
    case 'account_not_found':
      return { account: t('accountNotFound') };
    case 'category_not_found':
      return { category: t('categoryNotFound') };
    case 'category_kind_mismatch':
      return { category: t('categoryMismatch') };
    case 'tag_not_found':
      return { tags: t('tagNotFound') };
    case 'too_many_tags':
      return { tags: t('tooManyTags', { newMax: NEW_TAGS_MAX, totalMax: TAGS_PER_TRANSACTION_MAX }) };
  }
  return null;
}

/** Fehler, die nicht zu einem Feld gehören. */
export function rpcMessage(error: PostgrestError, t: ErrorsTranslator): string {
  switch (error.message) {
    case 'transaction_not_found':
      return t('transactionNotFound');
    case 'transaction_not_editable':
      return t('transactionNotEditable');
  }
  return t('generic');
}
