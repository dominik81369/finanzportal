'use server';

/**
 * lib/actions/import-transactions.ts
 *
 * Server Actions des CSV-/Excel-Imports. Die Datei wird im Browser gelesen
 * und normalisiert (lib/import/); hierher kommen nur die Zeilen. Beide
 * Actions rufen public.import_transactions() auf (SECURITY INVOKER, RLS
 * aktiv), die jede Zeile erneut prüft, Duplikate per Hash überspringt und
 * Kategorisierungsregeln anwendet – previewImport mit p_dry_run (zählt nur).
 * Siehe supabase/migrations/20261002170000_csv_import_and_categorization.sql.
 */
import { revalidatePath } from 'next/cache';
import { getTranslations } from 'next-intl/server';

import { isSupportedCurrency } from '@/lib/currency';
import { MAX_IMPORT_ROWS, type ImportRow } from '@/lib/import/statement';
import { createClient, requireOnboardedUser } from '@/lib/supabase/server';
import { isUuid } from '@/lib/transactions';

export type ImportTarget =
  | { accountId: string; newAccount?: undefined }
  | { accountId: null; newAccount: { name: string; currency: string } };

export type ImportRequest = ImportTarget & { rows: ImportRow[] };

export type ImportSummary = {
  accountId: string | null;
  currency: string;
  total: number;
  new: number;
  duplicates: number;
  categorized: number;
  balance: number | null;
};

export type ImportResponse = { status: 'ok'; summary: ImportSummary } | { status: 'error'; message: string };

function isImportRow(value: unknown): value is ImportRow {
  if (typeof value !== 'object' || value === null) {
    return false;
  }
  const row = value as Record<string, unknown>;
  const optionalString = (key: string) => row[key] === null || row[key] === undefined || typeof row[key] === 'string';
  return (
    typeof row.booking_date === 'string' &&
    typeof row.amount === 'number' &&
    Number.isFinite(row.amount) &&
    optionalString('value_date') &&
    optionalString('currency') &&
    optionalString('counterparty') &&
    optionalString('purpose') &&
    optionalString('transaction_type') &&
    optionalString('counterparty_iban') &&
    optionalString('description')
  );
}

async function callImport(request: ImportRequest, dryRun: boolean): Promise<ImportResponse> {
  await requireOnboardedUser('/dashboard/transactions/import');
  const t = await getTranslations('Import.errors');

  const rows: unknown = request?.rows;
  if (!Array.isArray(rows) || rows.length === 0) {
    return { status: 'error', message: t('noRows') };
  }
  if (rows.length > MAX_IMPORT_ROWS) {
    return { status: 'error', message: t('tooManyRows', { max: MAX_IMPORT_ROWS }) };
  }
  if (!rows.every(isImportRow)) {
    return { status: 'error', message: t('invalidData') };
  }

  let accountId: string | null = null;
  let newName: string | null = null;
  let newCurrency: string | null = null;
  if (request.accountId !== null) {
    if (typeof request.accountId !== 'string' || !isUuid(request.accountId)) {
      return { status: 'error', message: t('accountNotFound') };
    }
    accountId = request.accountId;
  } else {
    newName = typeof request.newAccount?.name === 'string' ? request.newAccount.name.trim() : '';
    newCurrency = request.newAccount?.currency ?? '';
    if (newName.length < 1 || newName.length > 120) {
      return { status: 'error', message: t('accountName') };
    }
    if (!isSupportedCurrency(newCurrency)) {
      return { status: 'error', message: t('invalidData') };
    }
  }

  const supabase = await createClient();
  const { data, error } = await supabase.rpc('import_transactions', {
    p_account_id: accountId,
    p_rows: rows,
    p_dry_run: dryRun,
    p_new_account_name: newName,
    p_new_account_currency: newCurrency,
  });

  if (error) {
    console.error('[import] import_transactions fehlgeschlagen', { code: error.code, message: error.message });
    switch (error.message) {
      case 'invalid_row':
        return { status: 'error', message: t('invalidRow', { row: error.details ?? '?' }) };
      case 'account_not_found':
        return { status: 'error', message: t('accountNotFound') };
      case 'account_not_importable':
        return { status: 'error', message: t('accountNotImportable') };
      case 'too_many_rows':
        return { status: 'error', message: t('tooManyRows', { max: MAX_IMPORT_ROWS }) };
      case 'invalid_account_name':
        return { status: 'error', message: t('accountName') };
      default:
        return { status: 'error', message: t('generic') };
    }
  }

  const result = data as Record<string, unknown>;
  if (!dryRun) {
    revalidatePath('/[locale]/dashboard/transactions', 'page');
  }
  return {
    status: 'ok',
    summary: {
      accountId: (result.account_id as string | null) ?? null,
      currency: String(result.currency),
      total: Number(result.total),
      new: Number(result.new),
      duplicates: Number(result.duplicates),
      categorized: Number(result.categorized),
      balance: result.balance === null || result.balance === undefined ? null : Number(result.balance),
    },
  };
}

/** Vorschau: zählt neue Buchungen, Duplikate und Regel-Treffer, schreibt nichts. */
export async function previewImport(request: ImportRequest): Promise<ImportResponse> {
  return callImport(request, true);
}

/** Import ausführen. */
export async function runImport(request: ImportRequest): Promise<ImportResponse> {
  return callImport(request, false);
}
