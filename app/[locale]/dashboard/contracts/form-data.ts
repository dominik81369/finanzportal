/**
 * Auswahllisten des Vertragsformulars: Gegenparteien der eigenen Ausgaben
 * (public.contract_counterparties), Konten und Kategorien – nur eigene
 * Daten (Berater sehen per RLS auch Mandantendaten).
 */
import 'server-only';

import { createClient } from '@/lib/supabase/server';

import { loadTransactionFormOptions } from '../transactions/form-options';
import type { CounterpartyOption } from './contract-form';

/** null, wenn eine der Abfragen fehlschlägt. */
export async function loadContractFormData(userId: string) {
  const supabase = await createClient();
  const [counterparties, options] = await Promise.all([
    supabase.rpc('contract_counterparties', { p_limit: 300 }),
    loadTransactionFormOptions(userId),
  ]);
  if (counterparties.error || !options) {
    console.error('[contracts] Auswahllisten nicht ladbar', { code: counterparties.error?.code });
    return null;
  }
  const list: CounterpartyOption[] = (counterparties.data ?? []).map((row) => ({
    key: row.counterparty_key,
    label: row.label ?? row.counterparty_key,
    count: row.tx_count,
    lastAmount: Number(row.last_amount),
  }));
  return {
    counterparties: list,
    accounts: options.accounts.map(({ id, name }) => ({ id, name })),
    categories: options.categories,
  };
}
