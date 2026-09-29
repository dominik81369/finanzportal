'use server';

/**
 * lib/actions/create-transaction.ts
 *
 * Server Action: manuelle Buchung mit Kategorie und Tags erfassen.
 *
 * Ablauf
 *   1. requireOnboardedUser() – angemeldet und mit eigenem Passwort.
 *   2. FormData prüfen (lib/transaction-form.server.ts – gemeinsam mit dem
 *      Bearbeiten).
 *   3. RPC create_manual_transaction(): legt Buchung, neue Tags und
 *      Zuordnungen in EINER Datenbanktransaktion an (SECURITY INVOKER, RLS
 *      aktiv) und prüft Konto, Kategorie, Tags und Währung. Siehe
 *      supabase/migrations/20261002000000_edit_delete_transactions.sql.
 *   4. Erfolg → Transaktionsliste mit Bestätigung (?saved=1).
 */
import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';

import { localizedPath } from '@/i18n/paths';
import { createClient, requireOnboardedUser } from '@/lib/supabase/server';
import type { TransactionFormState } from '@/lib/transaction-form-types';
import { parseTransactionForm, rpcErrorState } from '@/lib/transaction-form.server';

export async function createTransaction(
  _prevState: TransactionFormState,
  formData: FormData,
): Promise<TransactionFormState> {
  await requireOnboardedUser('/dashboard/transactions/new');

  const parsed = await parseTransactionForm(formData);
  if (!parsed.ok) {
    return parsed.state;
  }

  const supabase = await createClient();
  const { error } = await supabase.rpc('create_manual_transaction', parsed.params);
  if (error) {
    return rpcErrorState(error, parsed.values, 'create-transaction');
  }

  revalidatePath('/[locale]/dashboard/transactions', 'page');
  redirect(`${await localizedPath('/dashboard/transactions')}?saved=1`);
}
