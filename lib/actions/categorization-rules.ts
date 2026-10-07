'use server';

/**
 * lib/actions/categorization-rules.ts
 *
 * Server Actions für Kategorisierungsregeln und die manuelle Kategorie-
 * Korrektur einer Buchung (mit Lernen). Alles über SECURITY-INVOKER-RPCs
 * bzw. den Server-Client mit RLS; siehe
 * supabase/migrations/20261002170000_csv_import_and_categorization.sql.
 */
import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import { getTranslations } from 'next-intl/server';

import { localizedPath } from '@/i18n/paths';
import { isRuleDirection, isRuleField, isRuleMatchType, sortRules } from '@/lib/import/rules';
import { createClient, requireOnboardedUser } from '@/lib/supabase/server';
import { isUuid } from '@/lib/transactions';

const RULES_PATH = '/dashboard/transactions/rules';
const TRANSACTIONS_PATH = '/dashboard/transactions';

export type RuleFormState = {
  status: 'idle' | 'success' | 'error';
  message?: string;
  values?: { pattern: string; categoryId: string; field: string; matchType: string; direction: string };
  /** Neu je Erfolg – das Formular wird damit geleert. */
  nonce?: number;
};

export async function createRule(_prevState: RuleFormState, formData: FormData): Promise<RuleFormState> {
  await requireOnboardedUser(RULES_PATH);
  const t = await getTranslations('Rules.errors');
  const pattern = String(formData.get('pattern') ?? '').trim();
  const categoryId = String(formData.get('category') ?? '');
  const field = String(formData.get('field') ?? 'counterparty_or_purpose');
  const matchType = String(formData.get('matchType') ?? 'contains');
  const direction = String(formData.get('direction') ?? '');
  const values = { pattern, categoryId, field, matchType, direction };

  if (pattern.length < 2 || pattern.length > 200) {
    return { status: 'error', message: t('invalidPattern'), values };
  }
  if (!isUuid(categoryId)) {
    return { status: 'error', message: t('categoryMissing'), values };
  }
  if (!isRuleField(field) || !isRuleMatchType(matchType) || !isRuleDirection(direction)) {
    return { status: 'error', message: t('generic'), values };
  }

  const supabase = await createClient();
  const { error } = await supabase.rpc('create_categorization_rule', {
    p_pattern: pattern,
    p_category_id: categoryId,
    p_match_field: field,
    p_match_type: matchType,
    p_direction: direction === '' ? null : direction,
  });
  if (error) {
    const message =
      error.message === 'invalid_pattern'
        ? t('invalidPattern')
        : error.message === 'rule_exists'
          ? t('ruleExists')
          : error.message === 'category_not_found'
            ? t('categoryMissing')
            : t('generic');
    if (message === t('generic')) {
      console.error('[rules] Anlegen fehlgeschlagen', { code: error.code });
    }
    return { status: 'error', message, values };
  }

  revalidatePath(`/[locale]${RULES_PATH}`, 'page');
  return { status: 'success', message: (await getTranslations('Rules'))('created'), nonce: Date.now() };
}

/** Regel eine Position nach oben/unten schieben (schreibt die ganze Reihenfolge). */
export async function moveRule(ruleId: string, direction: 'up' | 'down'): Promise<void> {
  const user = await requireOnboardedUser(RULES_PATH);
  if (!isUuid(ruleId)) {
    return;
  }
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('categorization_rules')
    .select('id, pattern, priority, created_at')
    .eq('user_id', user.id)
    .neq('origin', 'standard');
  if (error || !data) {
    console.error('[rules] Laden für Umsortieren fehlgeschlagen', { code: error?.code });
    return;
  }
  const ids = sortRules(data).map((rule) => rule.id);
  const index = ids.indexOf(ruleId);
  const target = direction === 'up' ? index - 1 : index + 1;
  if (index === -1 || target < 0 || target >= ids.length) {
    return;
  }
  [ids[index], ids[target]] = [ids[target]!, ids[index]!];

  const { error: reorderError } = await supabase.rpc('reorder_categorization_rules', { p_ids: ids });
  if (reorderError) {
    console.error('[rules] Umsortieren fehlgeschlagen', { code: reorderError.code });
  }
  revalidatePath(`/[locale]${RULES_PATH}`, 'page');
}

export async function deleteRule(ruleId: string): Promise<void> {
  const user = await requireOnboardedUser(RULES_PATH);
  if (!isUuid(ruleId)) {
    return;
  }
  const supabase = await createClient();
  const { error } = await supabase.from('categorization_rules').delete().eq('id', ruleId).eq('user_id', user.id);
  if (error) {
    console.error('[rules] Löschen fehlgeschlagen', { code: error.code });
  }
  revalidatePath(`/[locale]${RULES_PATH}`, 'page');
}

export type CategoryFormState = { status: 'idle' | 'error'; message?: string };

/**
 * Kategorie einer Buchung setzen. Bei importierten/synchronisierten
 * Buchungen lernt die Datenbank daraus eine Regel; der gelernte Händlername
 * erscheint als Hinweis in der Transaktionsliste.
 */
export async function setTransactionCategory(
  transactionId: string,
  _prevState: CategoryFormState,
  formData: FormData,
): Promise<CategoryFormState> {
  await requireOnboardedUser('/dashboard/transactions');
  const t = await getTranslations('TransactionCategory.errors');
  const raw = String(formData.get('category') ?? '');
  const categoryId = raw === '' ? null : raw;
  if (!isUuid(transactionId) || (categoryId !== null && !isUuid(categoryId))) {
    return { status: 'error', message: t('generic') };
  }

  const supabase = await createClient();
  const { data, error } = await supabase.rpc('set_transaction_category', {
    p_id: transactionId,
    p_category_id: categoryId,
  });
  if (error) {
    if (error.code !== 'P0002') {
      console.error('[transactions] Kategorie setzen fehlgeschlagen', { code: error.code });
    }
    return { status: 'error', message: error.code === 'P0002' ? t('notFound') : t('generic') };
  }

  const result = data as { learned_pattern?: string | null; rule_id?: string | null; similar?: number } | null;
  const learned = result?.learned_pattern ?? null;
  revalidatePath('/[locale]/dashboard/transactions', 'page');
  revalidatePath(`/[locale]${RULES_PATH}`, 'page');
  const query = new URLSearchParams({ categorized: '1' });
  if (learned) {
    query.set('learned', learned);
  }
  // „N ähnliche Buchungen gefunden, auch zuordnen?“
  if (result?.rule_id && result.similar && result.similar > 0) {
    query.set('similar', String(result.similar));
    query.set('rule', result.rule_id);
  }
  redirect(`${await localizedPath('/dashboard/transactions')}?${query.toString()}`);
}

/** Seiten neu laden, deren Zahlen von Kategorien abhängen. */
function revalidateCategorization() {
  revalidatePath(`/[locale]${TRANSACTIONS_PATH}`, 'page');
  revalidatePath(`/[locale]${RULES_PATH}`, 'page');
  revalidatePath('/[locale]/dashboard', 'page');
  revalidatePath('/[locale]/dashboard/budgets', 'page');
}

async function redirectWith(path: string, params: Record<string, string>): Promise<never> {
  redirect(`${await localizedPath(path)}?${new URLSearchParams(params).toString()}`);
}

/** Schicht 3: Standard-Regelset übernehmen (idempotent). */
export async function loadStandardRules(): Promise<void> {
  await requireOnboardedUser(RULES_PATH);
  const supabase = await createClient();
  const { data, error } = await supabase.rpc('load_standard_rules');
  if (error) {
    console.error('[rules] Standardregeln laden fehlgeschlagen', { code: error.code });
    await redirectWith(RULES_PATH, { error: '1' });
  }
  revalidateCategorization();
  await redirectWith(RULES_PATH, { loaded: String(data ?? 0) });
}

/** Alle Regeln auf alle Buchungen ohne Kategorie anwenden. */
export async function applyRules(): Promise<void> {
  await requireOnboardedUser(RULES_PATH);
  const supabase = await createClient();
  const { data, error } = await supabase.rpc('apply_categorization_rules', {});
  if (error) {
    console.error('[rules] Anwenden fehlgeschlagen', { code: error.code });
    await redirectWith(RULES_PATH, { error: '1' });
  }
  revalidateCategorization();
  await redirectWith(RULES_PATH, { applied: String(data ?? 0) });
}

/** Maschinell (per Regel) vergebene Kategorien entfernen; manuelle bleiben. */
export async function resetMachineCategorization(): Promise<void> {
  await requireOnboardedUser(RULES_PATH);
  const supabase = await createClient();
  const { data, error } = await supabase.rpc('reset_machine_categorization');
  if (error) {
    console.error('[rules] Zurücksetzen fehlgeschlagen', { code: error.code });
    await redirectWith(RULES_PATH, { error: '1' });
  }
  revalidateCategorization();
  await redirectWith(RULES_PATH, { reset: String(data ?? 0) });
}

/** „N ähnliche Buchungen gefunden, auch zuordnen?“ – nur diese Regel anwenden. */
export async function applyRuleToSimilar(ruleId: string): Promise<void> {
  await requireOnboardedUser(TRANSACTIONS_PATH);
  if (!isUuid(ruleId)) {
    await redirectWith(TRANSACTIONS_PATH, {});
  }
  const supabase = await createClient();
  const { data, error } = await supabase.rpc('apply_categorization_rules', { p_rule_id: ruleId });
  if (error) {
    console.error('[rules] Ähnliche zuordnen fehlgeschlagen', { code: error.code });
    await redirectWith(TRANSACTIONS_PATH, {});
  }
  revalidateCategorization();
  await redirectWith(TRANSACTIONS_PATH, { applied: String(data ?? 0) });
}
