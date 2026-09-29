'use server';

/**
 * lib/actions/create-transaction.ts
 *
 * Server Action: manuelle Buchung mit Kategorie und Tags erfassen.
 *
 * Ablauf
 *   1. requireOnboardedUser() – angemeldet und mit eigenem Passwort.
 *   2. FormData prüfen (Beträge in der Schreibweise der Seitensprache).
 *   3. RPC create_manual_transaction(): legt Buchung, neue Tags und
 *      Zuordnungen in EINER Datenbanktransaktion an (SECURITY INVOKER, RLS
 *      aktiv) und prüft Konto, Kategorie und Tags auf Eigentum sowie die
 *      Kategorie auf die passende Art. Siehe
 *      supabase/migrations/20260930000000_manual_transactions.sql.
 *   4. Erfolg → Transaktionsliste mit Bestätigung (?saved=1).
 */
import type { PostgrestError } from '@supabase/supabase-js';
import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import { getLocale, getTranslations } from 'next-intl/server';

import { localizedPath } from '@/i18n/paths';
import { createClient, requireOnboardedUser } from '@/lib/supabase/server';
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

export type TransactionType = 'expense' | 'income';

export type TransactionField =
  | 'type'
  | 'amount'
  | 'bookingDate'
  | 'counterparty'
  | 'purpose'
  | 'account'
  | 'category'
  | 'tags';

export type CreateTransactionState = {
  status: 'idle' | 'error';
  message?: string;
  fieldErrors?: Partial<Record<TransactionField, string>>;
  /** Zum Vorbelegen des Formulars nach einem Fehler. */
  values?: {
    type: TransactionType;
    amount: string;
    bookingDate: string;
    counterparty: string;
    purpose: string;
    accountId: string;
    categoryId: string;
    tagIds: string[];
    newTags: string;
  };
};

type ErrorsTranslator = Awaited<ReturnType<typeof getTranslations<'Transactions.errors'>>>;

/** Fachliche Fehler der RPC (Exception-Message) → Feld und Meldung. */
function rpcError(
  error: PostgrestError,
  t: ErrorsTranslator,
): Pick<CreateTransactionState, 'message' | 'fieldErrors'> {
  switch (error.message) {
    case 'invalid_amount':
      return { fieldErrors: { amount: t('amountInvalid') } };
    case 'invalid_booking_date':
      return { fieldErrors: { bookingDate: t('dateInvalid') } };
    case 'account_not_found':
      return { fieldErrors: { account: t('accountNotFound') } };
    case 'category_not_found':
      return { fieldErrors: { category: t('categoryNotFound') } };
    case 'category_kind_mismatch':
      return { fieldErrors: { category: t('categoryMismatch') } };
    case 'tag_not_found':
      return { fieldErrors: { tags: t('tagNotFound') } };
    case 'too_many_tags':
      return {
        fieldErrors: {
          tags: t('tooManyTags', { newMax: NEW_TAGS_MAX, totalMax: TAGS_PER_TRANSACTION_MAX }),
        },
      };
  }
  console.error('[create-transaction] RPC fehlgeschlagen', { code: error.code });
  return { message: t('generic') };
}

export async function createTransaction(
  _prevState: CreateTransactionState,
  formData: FormData,
): Promise<CreateTransactionState> {
  await requireOnboardedUser('/dashboard/transactions/new');

  const locale = await getLocale();
  const t = await getTranslations('Transactions.errors');
  const tValidation = await getTranslations('Validation');

  const rawType = readTrimmed(formData, 'type');
  const values: NonNullable<CreateTransactionState['values']> = {
    type: rawType === 'income' ? 'income' : 'expense',
    amount: readTrimmed(formData, 'amount'),
    bookingDate: readTrimmed(formData, 'booking_date'),
    counterparty: readTrimmed(formData, 'counterparty'),
    purpose: readTrimmed(formData, 'purpose'),
    accountId: readTrimmed(formData, 'account_id'),
    categoryId: readTrimmed(formData, 'category_id'),
    tagIds: formData.getAll('tag_ids').filter((v): v is string => typeof v === 'string'),
    newTags: readTrimmed(formData, 'new_tags'),
  };

  const fieldErrors: NonNullable<CreateTransactionState['fieldErrors']> = {};

  if (rawType !== 'expense' && rawType !== 'income') {
    fieldErrors.type = t('typeInvalid');
  }
  const amount = parseAmountInput(values.amount, locale);
  if (amount === null) {
    fieldErrors.amount = t('amountInvalid');
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
    return { status: 'error', message: tValidation('checkInput'), fieldErrors, values };
  }

  const supabase = await createClient();
  const { error } = await supabase.rpc('create_manual_transaction', {
    p_booking_date: bookingDate,
    p_amount: values.type === 'expense' ? -amount : amount,
    p_counterparty_name: values.counterparty,
    p_purpose: values.purpose || undefined,
    p_account_id: values.accountId || undefined,
    p_category_id: values.categoryId || undefined,
    p_tag_ids: tagIds,
    p_new_tag_names: newTagNames,
  });

  if (error) {
    const { message, fieldErrors: rpcFieldErrors } = rpcError(error, t);
    return {
      status: 'error',
      message: message ?? tValidation('checkInput'),
      fieldErrors: rpcFieldErrors,
      values,
    };
  }

  revalidatePath('/[locale]/dashboard/transactions', 'page');
  redirect(`${await localizedPath('/dashboard/transactions')}?saved=1`);
}
