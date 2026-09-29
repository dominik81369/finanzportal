'use server';

/**
 * lib/actions/update-transaction.ts
 *
 * Server Actions: manuelle Buchung bearbeiten bzw. löschen.
 *
 * Die ID wird per .bind() aus der Bearbeiten-Seite übergeben und kommt
 * damit – wie alle Formulardaten – vom Client. Sie ist deshalb nicht
 * vertrauenswürdig: update_/delete_manual_transaction() prüfen Eigentum
 * (user_id = auth.uid()) und Herkunft (nur source = 'manual') selbst.
 * Siehe supabase/migrations/20261002000000_edit_delete_transactions.sql.
 */
import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import { getTranslations } from 'next-intl/server';

import { localizedPath } from '@/i18n/paths';
import { createClient, requireOnboardedUser } from '@/lib/supabase/server';
import type { TransactionFormState } from '@/lib/transaction-form-types';
import { parseTransactionForm, rpcErrorState, rpcMessage } from '@/lib/transaction-form.server';
import { isUuid } from '@/lib/transactions';

export type DeleteTransactionState = { status: 'idle' | 'error'; message?: string };

export async function updateTransaction(
  transactionId: string,
  _prevState: TransactionFormState,
  formData: FormData,
): Promise<TransactionFormState> {
  await requireOnboardedUser('/dashboard/transactions');

  const parsed = await parseTransactionForm(formData);
  if (!parsed.ok) {
    return parsed.state;
  }
  if (!isUuid(transactionId)) {
    const t = await getTranslations('Transactions.errors');
    return { status: 'error', message: t('transactionNotFound'), values: parsed.values };
  }

  const supabase = await createClient();
  const { error } = await supabase.rpc('update_manual_transaction', {
    p_id: transactionId,
    ...parsed.params,
  });
  if (error) {
    return rpcErrorState(error, parsed.values, 'update-transaction');
  }

  revalidatePath('/[locale]/dashboard/transactions', 'page');
  redirect(`${await localizedPath('/dashboard/transactions')}?updated=1`);
}

export async function deleteTransaction(
  transactionId: string,
  _prevState: DeleteTransactionState,
  _formData: FormData,
): Promise<DeleteTransactionState> {
  await requireOnboardedUser('/dashboard/transactions');
  const t = await getTranslations('Transactions.errors');

  if (!isUuid(transactionId)) {
    return { status: 'error', message: t('transactionNotFound') };
  }

  const supabase = await createClient();
  const { error } = await supabase.rpc('delete_manual_transaction', { p_id: transactionId });
  if (error) {
    if (error.message !== 'transaction_not_found' && error.message !== 'transaction_not_editable') {
      console.error('[delete-transaction] RPC fehlgeschlagen', { code: error.code });
    }
    return { status: 'error', message: rpcMessage(error, t) };
  }

  revalidatePath('/[locale]/dashboard/transactions', 'page');
  redirect(`${await localizedPath('/dashboard/transactions')}?deleted=1`);
}
