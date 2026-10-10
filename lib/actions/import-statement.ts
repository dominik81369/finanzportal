'use server';

/**
 * lib/actions/import-statement.ts
 *
 * Server Actions des PDF-Imports (N26). Anders als beim CSV-Import wird die
 * Datei auf dem Server gelesen (lib/import/pdf-text.ts) und bei Vorschau
 * und Import jeweils neu zerlegt und geprüft (lib/import/n26-pdf.ts) –
 * importiert wird nur, was die Saldenprüfung besteht. Die PDF wird nicht
 * gespeichert. Alle Konten eines Auszugs gehen in einem Aufruf von
 * public.import_statement() in die Datenbank (alles oder nichts), siehe
 * supabase/migrations/20261016100100_pdf_import.sql.
 */
import { revalidatePath } from 'next/cache';
import { getFormatter, getTranslations } from 'next-intl/server';

import { parseN26Statement, type N26Error, type N26Section } from '@/lib/import/n26-pdf';
import { looksLikePdf, readPdfPages } from '@/lib/import/pdf-text';
import { createClient, requireOnboardedUser } from '@/lib/supabase/server';
import { isUuid } from '@/lib/transactions';

/** Höchstgröße einer PDF (Vercel begrenzt Request-Bodies auf 4,5 MB). */
const MAX_PDF_BYTES = 4_000_000;
const IMPORT_PATH = '/dashboard/transactions/import';

/** Zielkonto je Abschnitt (IBAN): vorhandenes Konto oder neues mit Namen. */
export type StatementTargets = Record<string, { accountId: string | null; name: string }>;

export type StatementSectionResult = {
  iban: string;
  kind: 'main' | 'space';
  /** Name des Space; null beim Hauptkonto. */
  name: string | null;
  opening: number;
  incoming: number;
  outgoing: number;
  closing: number;
  rows: number;
  skippedZero: number;
  /** Gewähltes Zielkonto (null = neues Konto) und Name für ein neues Konto. */
  accountId: string | null;
  newAccountName: string;
  /** Angelegtes bzw. verwendetes Konto (nach dem Import). */
  resultAccountId: string | null;
  new: number;
  duplicates: number;
  /** Gleiche Buchung aus anderer Quelle im Zielkonto (übersprungen). */
  probable: number;
  probableRows: { booking_date: string; amount: number; counterparty: string | null }[];
  categorized: number;
  enriched: number;
  /** Anfangsbestand wird (wurde) auf den alten Kontostand des Auszugs gesetzt. */
  openingSet: boolean;
  /** Kontostand der App zum Ende des Auszugs (Vorschau: nach dem Import). */
  balance: number;
};

export type StatementAccount = { id: string; name: string; currency: string; iban: string | null };

export type StatementResponse =
  | {
      status: 'ok';
      dryRun: boolean;
      /** Importierbare Konten (aktuell, auch nach dem Anlegen neuer Konten). */
      accounts: StatementAccount[];
      provisional: boolean;
      number: string | null;
      period: { from: string; to: string };
      sections: StatementSectionResult[];
      ownIbansAdded: number;
      learned: number;
      suggested: number;
    }
  | { status: 'error'; message: string };

function suggestedName(section: N26Section): string {
  return section.kind === 'main' ? 'N26 Hauptkonto' : `N26 ${section.name ?? section.iban.slice(-4)}`.slice(0, 120);
}

function parseTargets(raw: FormDataEntryValue | null): StatementTargets {
  if (typeof raw !== 'string' || raw === '') {
    return {};
  }
  try {
    const value: unknown = JSON.parse(raw);
    if (typeof value !== 'object' || value === null) {
      return {};
    }
    const targets: StatementTargets = {};
    for (const [iban, target] of Object.entries(value as Record<string, unknown>)) {
      if (typeof target !== 'object' || target === null) {
        continue;
      }
      const { accountId, name } = target as { accountId?: unknown; name?: unknown };
      targets[iban] = {
        accountId: typeof accountId === 'string' && isUuid(accountId) ? accountId : null,
        name: typeof name === 'string' ? name.trim().slice(0, 120) : '',
      };
    }
    return targets;
  } catch {
    return {};
  }
}

async function run(formData: FormData, dryRun: boolean): Promise<StatementResponse> {
  const user = await requireOnboardedUser(IMPORT_PATH);
  const t = await getTranslations('Import.pdf.errors');
  const format = await getFormatter();
  const money = (value: number) => format.number(value, { style: 'currency', currency: 'EUR' });

  const file = formData.get('file');
  if (!(file instanceof File) || file.size === 0) {
    return { status: 'error', message: t('noFile') };
  }
  if (file.size > MAX_PDF_BYTES) {
    return { status: 'error', message: t('tooLarge', { max: 4 }) };
  }
  const bytes = new Uint8Array(await file.arrayBuffer());
  if (!looksLikePdf(bytes)) {
    return { status: 'error', message: t('notPdf') };
  }

  let pages;
  try {
    pages = await readPdfPages(bytes);
  } catch (error) {
    console.error('[import-pdf] PDF nicht lesbar', { message: error instanceof Error ? error.message : String(error) });
    return { status: 'error', message: t('unreadable') };
  }
  const parsed = parseN26Statement(pages);
  if (!parsed.ok) {
    return { status: 'error', message: parseErrorMessage(parsed.error, t, money) };
  }
  const statement = parsed.statement;

  const supabase = await createClient();
  // Ausdrücklich eigene Konten: RLS gibt Beratern auch die ihrer Mandanten frei.
  const { data: accounts, error: accountsError } = await supabase
    .from('accounts')
    .select('id, name, currency, iban')
    .eq('user_id', user.id)
    .in('provider', ['manual', 'csv'])
    .is('archived_at', null)
    .order('name');
  if (accountsError) {
    console.error('[import-pdf] Konten nicht ladbar', { code: accountsError.code });
    return { status: 'error', message: t('generic') };
  }

  const targets = parseTargets(formData.get('targets'));
  const chosen = statement.sections.map((section) => {
    const target = targets[section.iban];
    const byIban = accounts.find((account) => account.iban === section.iban)?.id ?? null;
    const accountId = target ? target.accountId : byIban;
    return {
      section,
      accountId: accountId && accounts.some((account) => account.id === accountId) ? accountId : null,
      newAccountName: target?.name || suggestedName(section),
    };
  });

  const { data, error } = await supabase.rpc('import_statement', {
    p_sections: chosen.map(({ section, accountId, newAccountName }) => ({
      iban: section.iban,
      account_id: accountId,
      new_account_name: accountId ? null : newAccountName,
      institution: 'N26',
      opening: section.opening,
      closing: section.closing,
      period_from: statement.period.from,
      period_to: statement.period.to,
      rows: section.rows,
    })),
    p_dry_run: dryRun,
  });

  if (error) {
    console.error('[import-pdf] import_statement fehlgeschlagen', { code: error.code, message: error.message });
    const section = statement.sections.find((s) => s.iban === error.details);
    const account = section ? sectionLabel(section, t) : (error.details ?? '');
    switch (error.message) {
      case 'balance_mismatch':
        return { status: 'error', message: t('balanceMismatchDb', { account }) };
      case 'iban_mismatch':
        return { status: 'error', message: t('ibanMismatch', { account }) };
      case 'iban_in_use':
        return { status: 'error', message: t('ibanInUse', { account }) };
      case 'duplicate_target':
        return { status: 'error', message: t('duplicateTarget', { account }) };
      case 'invalid_account_name':
        return { status: 'error', message: t('accountName', { account }) };
      case 'account_not_found':
      case 'account_not_importable':
        return { status: 'error', message: t('accountNotFound', { account }) };
      case 'too_many_rows':
        return { status: 'error', message: t('tooManyRows', { max: 5000 }) };
      default:
        return { status: 'error', message: t('generic') };
    }
  }

  const result = data as {
    sections: {
      iban: string;
      account_id: string | null;
      new: number;
      duplicates: number;
      probable: number;
      probable_rows: { booking_date: string; amount: number; counterparty: string | null }[];
      categorized: number;
      enriched: number;
      opening_set: boolean;
      balance: number;
    }[];
    own_ibans_added: number;
    learned: number;
    suggested: number;
  };

  let currentAccounts: StatementAccount[] = accounts;
  if (!dryRun) {
    const reloaded = await supabase
      .from('accounts')
      .select('id, name, currency, iban')
      .eq('user_id', user.id)
      .in('provider', ['manual', 'csv'])
      .is('archived_at', null)
      .order('name');
    currentAccounts = reloaded.data ?? accounts;
    const synced = await supabase.rpc('sync_contracts');
    if (synced.error) {
      console.error('[import-pdf] Verknüpfen mit Verträgen fehlgeschlagen', { code: synced.error.code });
    }
    revalidatePath('/[locale]/dashboard/transactions', 'page');
    revalidatePath('/[locale]/dashboard/contracts', 'layout');
    revalidatePath('/[locale]/dashboard', 'layout');
  }

  return {
    status: 'ok',
    dryRun,
    accounts: currentAccounts,
    provisional: statement.provisional,
    number: statement.number,
    period: statement.period,
    sections: chosen.map(({ section, accountId, newAccountName }) => {
      const row = result.sections.find((s) => s.iban === section.iban);
      return {
        iban: section.iban,
        kind: section.kind,
        name: section.name,
        opening: section.opening,
        incoming: section.incoming,
        outgoing: section.outgoing,
        closing: section.closing,
        rows: section.rows.length,
        skippedZero: section.skippedZero,
        accountId,
        newAccountName,
        resultAccountId: row?.account_id ?? null,
        new: Number(row?.new ?? 0),
        duplicates: Number(row?.duplicates ?? 0),
        probable: Number(row?.probable ?? 0),
        probableRows: (row?.probable_rows ?? []).map((p) => ({ ...p, amount: Number(p.amount) })),
        categorized: Number(row?.categorized ?? 0),
        enriched: Number(row?.enriched ?? 0),
        openingSet: row?.opening_set === true,
        balance: Number(row?.balance ?? 0),
      };
    }),
    ownIbansAdded: Number(result.own_ibans_added ?? 0),
    learned: Number(result.learned ?? 0),
    suggested: Number(result.suggested ?? 0),
  };
}

type ErrorTranslator = Awaited<ReturnType<typeof getTranslations<'Import.pdf.errors'>>>;

function sectionLabel(section: { kind: 'main' | 'space'; name: string | null; iban: string }, t: ErrorTranslator): string {
  return section.kind === 'main' ? t('mainAccount') : t('space', { name: section.name ?? section.iban });
}

function parseErrorMessage(error: N26Error, t: ErrorTranslator, money: (value: number) => string): string {
  switch (error.code) {
    case 'notN26':
      return t('notN26');
    case 'noSections':
      return t('noSections');
    case 'layout':
      return t('layout', { page: error.page, text: error.text.slice(0, 80) });
    case 'missingSummary':
      return t('missingSummary', { account: sectionLabel({ kind: error.name ? 'space' : 'main', ...error }, t) });
    case 'balanceMismatch':
      return t('balanceMismatch', {
        account: sectionLabel({ kind: error.name ? 'space' : 'main', ...error }, t),
        opening: money(error.opening),
        incoming: money(error.incoming),
        outgoing: money(Math.abs(error.outgoing)),
        closing: money(error.closing),
      });
    case 'sumMismatch':
      return t('sumMismatch', {
        account: sectionLabel({ kind: error.name ? 'space' : 'main', ...error }, t),
        direction: error.direction,
        actual: money(Math.abs(error.actual)),
        expected: money(Math.abs(error.expected)),
      });
  }
}

/** Vorschau: zerlegen, prüfen, Abgleich mit vorhandenen Buchungen (schreibt nichts). */
export async function previewStatement(formData: FormData): Promise<StatementResponse> {
  return run(formData, true);
}

/** Import ausführen (alle Konten des Auszugs oder keins). */
export async function importStatement(formData: FormData): Promise<StatementResponse> {
  return run(formData, false);
}
