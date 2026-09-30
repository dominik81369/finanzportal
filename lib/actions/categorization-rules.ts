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
import { sortRules } from '@/lib/import/rules';
import { createClient, requireOnboardedUser } from '@/lib/supabase/server';
import { isUuid } from '@/lib/transactions';

const RULES_PATH = '/dashboard/transactions/rules';

export type RuleFormState = {
  status: 'idle' | 'success' | 'error';
  message?: string;
  values?: { pattern: string; categoryId: string };
  /** Neu je Erfolg – das Formular wird damit geleert. */
  nonce?: number;
};

export async function createRule(_prevState: RuleFormState, formData: FormData): Promise<RuleFormState> {
  await requireOnboardedUser(RULES_PATH);
  const t = await getTranslations('Rules.errors');
  const pattern = String(formData.get('pattern') ?? '').trim();
  const categoryId = String(formData.get('category') ?? '');
  const values = { pattern, categoryId };

  if (pattern.length < 2 || pattern.length > 200) {
    return { status: 'error', message: t('invalidPattern'), values };
  }
  if (!isUuid(categoryId)) {
    return { status: 'error', message: t('categoryMissing'), values };
  }

  const supabase = await createClient();
  const { error } = await supabase.rpc('create_categorization_rule', { p_pattern: pattern, p_category_id: categoryId });
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
    .eq('user_id', user.id);
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

  const learned = (data as { learned_pattern?: string | null } | null)?.learned_pattern ?? null;
  revalidatePath('/[locale]/dashboard/transactions', 'page');
  revalidatePath(`/[locale]${RULES_PATH}`, 'page');
  const query = new URLSearchParams({ categorized: '1' });
  if (learned) {
    query.set('learned', learned);
  }
  redirect(`${await localizedPath('/dashboard/transactions')}?${query.toString()}`);
}
