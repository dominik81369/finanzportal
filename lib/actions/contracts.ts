'use server';

/**
 * lib/actions/contracts.ts
 *
 * Server Actions für Verträge: erneut erkennen, Vorschläge bestätigen,
 * verwerfen und wiederherstellen, manuelle Verträge anlegen, ändern und
 * löschen, Buchungen lösen bzw. verknüpfen.
 *
 * IDs kommen per .bind() vom Client und sind nicht vertrauenswürdig: die
 * SECURITY-INVOKER-RPCs prüfen Eigentum (user_id = auth.uid()) selbst; RLS
 * lässt Beratern ohnehin nur Lesen zu. Siehe
 * supabase/migrations/20261010100000_contracts_v1.sql.
 *
 * Kein redirect() und kein revalidatePath(): Die Vertragsseiten streamen
 * ihre Daten (Suspense); eine Weiterleitung aus der Action auf eine solche
 * Seite wurde vom Router gelegentlich nicht übernommen (Next.js 15). Die
 * Actions liefern daher das Ziel ({ redirectTo }), und der Client navigiert
 * selbst (action-form.tsx, contract-form.tsx). Die Seiten sind dynamisch
 * und werden bei jeder Navigation neu geladen.
 */
import { getLocale, getTranslations } from 'next-intl/server';

import { localizedPath } from '@/i18n/paths';
import { toAppLocale } from '@/i18n/routing';
import {
  isContractType,
  parseContractForm,
  type ContractField,
  type ContractFieldError,
  type ContractFormValues,
} from '@/lib/contracts';
import { createClient, requireOnboardedUser } from '@/lib/supabase/server';
import { isUuid } from '@/lib/transactions';

const CONTRACTS_PATH = '/dashboard/contracts';

export type ContractFormState = {
  status: 'idle' | 'error' | 'success';
  message?: string;
  fieldErrors?: Partial<Record<ContractField, string>>;
  /** Zum Vorbelegen des Formulars nach einem Fehler. */
  values?: ContractFormValues;
  /** Nach Erfolg: Ziel der Navigation (lokalisiert, mit Meldung). */
  redirectTo?: string;
};

/** Ergebnis der Knopf-Actions: wohin der Client danach navigiert. */
export type ContractActionResult = { redirectTo: string };

async function target(path: string, params: Record<string, string>): Promise<ContractActionResult> {
  const query = new URLSearchParams(params).toString();
  return { redirectTo: `${await localizedPath(path)}${query ? `?${query}` : ''}` };
}

/** Erkennung neu laufen lassen; meldet die Anzahl neuer Vorschläge. */
export async function refreshContracts(): Promise<ContractActionResult> {
  await requireOnboardedUser(CONTRACTS_PATH);
  const supabase = await createClient();
  const { data, error } = await supabase.rpc('refresh_contracts');
  if (error) {
    console.error('[contracts] Erkennung fehlgeschlagen', { code: error.code });
    return target(CONTRACTS_PATH, { error: '1' });
  }
  const created = Number((data as { created?: number } | null)?.created ?? 0);
  return target(CONTRACTS_PATH, { refreshed: String(created) });
}

/** Vorschlag bestätigen, optional mit geändertem Vertragstyp. */
export async function confirmContract(contractId: string, formData: FormData): Promise<ContractActionResult> {
  await requireOnboardedUser(CONTRACTS_PATH);
  const type = String(formData.get('type') ?? '');
  if (!isUuid(contractId) || (type !== '' && !isContractType(type))) {
    return target(CONTRACTS_PATH, { error: '1' });
  }
  const supabase = await createClient();
  const { error } = await supabase.rpc('set_contract_status', {
    p_id: contractId,
    p_status: 'active',
    p_contract_type: isContractType(type) ? type : null,
  });
  if (error) {
    console.error('[contracts] Bestätigen fehlgeschlagen', { code: error.code });
    return target(CONTRACTS_PATH, { error: '1' });
  }
  return target(CONTRACTS_PATH, { confirmed: '1' });
}

/** Vorschlag oder erkannten Vertrag verwerfen (wird nicht erneut vorgeschlagen). */
export async function dismissContract(contractId: string): Promise<ContractActionResult> {
  await requireOnboardedUser(CONTRACTS_PATH);
  if (!isUuid(contractId)) {
    return target(CONTRACTS_PATH, { error: '1' });
  }
  const supabase = await createClient();
  const { error } = await supabase.rpc('set_contract_status', { p_id: contractId, p_status: 'dismissed' });
  if (error) {
    console.error('[contracts] Verwerfen fehlgeschlagen', { code: error.code });
    return target(CONTRACTS_PATH, { error: '1' });
  }
  return target(CONTRACTS_PATH, { dismissed: '1' });
}

/** Verworfenen Vorschlag wiederherstellen. */
export async function restoreContract(contractId: string): Promise<ContractActionResult> {
  await requireOnboardedUser(CONTRACTS_PATH);
  if (!isUuid(contractId)) {
    return target(CONTRACTS_PATH, { error: '1' });
  }
  const supabase = await createClient();
  const { error } = await supabase.rpc('set_contract_status', { p_id: contractId, p_status: 'suggested' });
  if (error) {
    console.error('[contracts] Wiederherstellen fehlgeschlagen', { code: error.code });
    return target(CONTRACTS_PATH, { error: '1' });
  }
  return target(CONTRACTS_PATH, { restored: '1' });
}

/** Manuell angelegten Vertrag löschen. */
export async function deleteContract(contractId: string): Promise<ContractActionResult> {
  await requireOnboardedUser(CONTRACTS_PATH);
  if (!isUuid(contractId)) {
    return target(CONTRACTS_PATH, { error: '1' });
  }
  const supabase = await createClient();
  const { error } = await supabase.rpc('delete_contract', { p_id: contractId });
  if (error) {
    console.error('[contracts] Löschen fehlgeschlagen', { code: error.code });
    return target(`${CONTRACTS_PATH}/${contractId}`, { error: '1' });
  }
  return target(CONTRACTS_PATH, { deleted: '1' });
}

/** Buchung vom Vertrag lösen; die Automatik verknüpft sie danach nicht wieder. */
export async function unlinkContractTransaction(contractId: string, transactionId: string): Promise<ContractActionResult> {
  return setLink(contractId, transactionId, null, 'unlinked');
}

/** Buchung manuell mit dem Vertrag verknüpfen. */
export async function linkContractTransaction(contractId: string, transactionId: string): Promise<ContractActionResult> {
  return setLink(contractId, transactionId, contractId, 'linked');
}

async function setLink(
  contractId: string,
  transactionId: string,
  linkTo: string | null,
  done: 'linked' | 'unlinked',
): Promise<ContractActionResult> {
  await requireOnboardedUser(CONTRACTS_PATH);
  const detailPath = `${CONTRACTS_PATH}/${contractId}`;
  if (!isUuid(contractId) || !isUuid(transactionId)) {
    return target(CONTRACTS_PATH, { error: '1' });
  }
  const supabase = await createClient();
  const { error } = await supabase.rpc('set_contract_link', {
    p_transaction_id: transactionId,
    p_contract_id: linkTo,
  });
  if (error) {
    console.error('[contracts] Verknüpfung ändern fehlgeschlagen', { code: error.code });
    return target(detailPath, { error: '1' });
  }
  return target(detailPath, { [done]: '1' });
}

const RPC_FIELD_ERRORS: Record<string, { field: ContractField; key: ContractFieldError }> = {
  invalid_name: { field: 'name', key: 'nameRequired' },
  invalid_counterparty: { field: 'counterparty', key: 'counterpartyInvalid' },
  invalid_rhythm: { field: 'rhythm', key: 'rhythmInvalid' },
  invalid_amount: { field: 'amount', key: 'amountInvalid' },
  invalid_tolerance: { field: 'tolerance', key: 'toleranceInvalid' },
  invalid_notes: { field: 'notes', key: 'notesTooLong' },
  account_not_found: { field: 'account', key: 'selectionInvalid' },
  category_not_found: { field: 'category', key: 'selectionInvalid' },
};

/**
 * Vertrag anlegen (contractId null) oder ändern. Bei Erfolg weiter zur
 * Detailseite, sonst Fehler mit den eingegebenen Werten.
 */
export async function saveContract(
  contractId: string | null,
  _prevState: ContractFormState,
  formData: FormData,
): Promise<ContractFormState> {
  await requireOnboardedUser(contractId ? `${CONTRACTS_PATH}/${contractId}` : `${CONTRACTS_PATH}/new`);
  const t = await getTranslations('Contracts.form.errors');
  const locale = toAppLocale(await getLocale());

  const parsed = parseContractForm(formData, locale);
  if (!parsed.ok) {
    const fieldErrors: Partial<Record<ContractField, string>> = {};
    for (const [field, key] of Object.entries(parsed.errors) as [ContractField, ContractFieldError][]) {
      fieldErrors[field] = t(key);
    }
    return { status: 'error', message: t('summary'), fieldErrors, values: parsed.values };
  }
  if (contractId !== null && !isUuid(contractId)) {
    return { status: 'error', message: t('notFound'), values: parsed.values };
  }

  const supabase = await createClient();
  const { data, error } = await supabase.rpc('save_contract', { p_id: contractId, ...parsed.params });
  if (error || !data) {
    const mapped = error ? RPC_FIELD_ERRORS[error.message] : undefined;
    if (mapped) {
      return {
        status: 'error',
        message: t('summary'),
        fieldErrors: { [mapped.field]: t(mapped.key) },
        values: parsed.values,
      };
    }
    if (error?.message === 'contract_not_found') {
      return { status: 'error', message: t('notFound'), values: parsed.values };
    }
    if (error?.message === 'contract_not_editable') {
      return { status: 'error', message: t('notEditable'), values: parsed.values };
    }
    console.error('[contracts] Speichern fehlgeschlagen', { code: error?.code });
    return { status: 'error', message: t('generic'), values: parsed.values };
  }

  const { redirectTo } = await target(`${CONTRACTS_PATH}/${data}`, { [contractId ? 'saved' : 'created']: '1' });
  return { status: 'success', redirectTo };
}
