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
const GROUPS_PATH = '/dashboard/transactions/groups';

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

  const result = data as {
    learned_pattern?: string | null;
    rule_id?: string | null;
    similar?: number;
    similar_auto?: number;
  } | null;
  const learned = result?.learned_pattern ?? null;
  revalidatePath('/[locale]/dashboard/transactions', 'page');
  revalidatePath(`/[locale]${RULES_PATH}`, 'page');
  const query = new URLSearchParams({ categorized: '1' });
  if (learned) {
    query.set('learned', learned);
  }
  // „N ähnliche Buchungen gefunden, auch zuordnen?“ – ohne Kategorie bzw.
  // automatisch anders zugeordnet (manuelle zählen nie mit).
  const similar = result?.similar ?? 0;
  const similarAuto = result?.similar_auto ?? 0;
  if (result?.rule_id && (similar > 0 || similarAuto > 0)) {
    query.set('similar', String(similar));
    query.set('similarAuto', String(similarAuto));
    query.set('rule', result.rule_id);
  }
  redirect(`${await localizedPath('/dashboard/transactions')}?${query.toString()}`);
}

/** Seiten neu laden, deren Zahlen von Kategorien abhängen. */
function revalidateCategorization() {
  revalidatePath(`/[locale]${TRANSACTIONS_PATH}`, 'page');
  revalidatePath(`/[locale]${RULES_PATH}`, 'page');
  revalidatePath(`/[locale]${GROUPS_PATH}`, 'page');
  revalidatePath('/[locale]/dashboard', 'page');
  revalidatePath('/[locale]/dashboard/budgets', 'page');
}

async function redirectWith(path: string, params: Record<string, string>): Promise<never> {
  redirect(`${await localizedPath(path)}?${new URLSearchParams(params).toString()}`);
}

/**
 * Schicht 3: Standard-Regelset abgleichen (fehlende ergänzen, veraltete
 * entfernen) und auf Buchungen ohne Kategorie anwenden.
 */
export async function loadStandardRules(): Promise<void> {
  await requireOnboardedUser(RULES_PATH);
  const supabase = await createClient();
  const { data, error } = await supabase.rpc('load_standard_rules');
  if (error) {
    console.error('[rules] Standardregeln laden fehlgeschlagen', { code: error.code });
    await redirectWith(RULES_PATH, { error: '1' });
  }
  const result = (data ?? {}) as { added?: number; removed?: number; applied?: number };
  revalidateCategorization();
  await redirectWith(RULES_PATH, {
    loaded: String(result.added ?? 0),
    removed: String(result.removed ?? 0),
    applied: String(result.applied ?? 0),
  });
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

/**
 * „N ähnliche Buchungen gefunden, auch zuordnen?“ – nur diese Regel anwenden;
 * overwrite: auch automatisch anders zugeordnete Buchungen (nie manuelle).
 */
export async function applyRuleToSimilar(ruleId: string, overwrite: boolean): Promise<void> {
  await requireOnboardedUser(TRANSACTIONS_PATH);
  if (!isUuid(ruleId)) {
    await redirectWith(TRANSACTIONS_PATH, {});
  }
  const supabase = await createClient();
  const { data, error } = await supabase.rpc('apply_categorization_rules', {
    p_rule_id: ruleId,
    p_overwrite_auto: overwrite === true,
  });
  if (error) {
    console.error('[rules] Ähnliche zuordnen fehlgeschlagen', { code: error.code });
    await redirectWith(TRANSACTIONS_PATH, {});
  }
  revalidateCategorization();
  await redirectWith(TRANSACTIONS_PATH, { applied: String(data ?? 0) });
}

export type OwnAccountFormState = {
  status: 'idle' | 'success' | 'error';
  message?: string;
  values?: { kind: string; value: string; categoryId: string };
  nonce?: number;
};

/**
 * Eigenes Konto erkennen (Schicht vor den Standardregeln): Name (Vor- und
 * Nachname, alle Wörter im Empfänger) oder IBAN → Umbuchung. Die Regel wird
 * sofort angewendet.
 */
export async function addOwnAccount(_prevState: OwnAccountFormState, formData: FormData): Promise<OwnAccountFormState> {
  await requireOnboardedUser(RULES_PATH);
  const t = await getTranslations('Rules.ownAccounts');
  const kind = String(formData.get('kind') ?? '');
  const value = String(formData.get('value') ?? '').trim();
  const rawCategory = String(formData.get('category') ?? '');
  const categoryId = rawCategory === '' ? null : rawCategory;
  const values = { kind, value, categoryId: rawCategory };
  if (
    (kind !== 'name' && kind !== 'iban') ||
    value.length === 0 ||
    value.length > 200 ||
    (categoryId !== null && !isUuid(categoryId))
  ) {
    return { status: 'error', message: t(kind === 'iban' ? 'errors.invalidIban' : 'errors.invalidName'), values };
  }

  const supabase = await createClient();
  // Zielkategorie nur für IBANs (Namen sind Vorschläge für „Umbuchung“).
  const { data, error } = await supabase.rpc('add_own_account_identifier', {
    p_kind: kind,
    p_value: value,
    p_category_id: kind === 'iban' ? categoryId : null,
  });
  if (error) {
    const key =
      error.message === 'invalid_name'
        ? 'errors.invalidName'
        : error.message === 'invalid_iban'
          ? 'errors.invalidIban'
          : error.message === 'rule_exists'
            ? 'errors.exists'
            : error.message === 'category_not_found'
              ? 'errors.noTransferCategory'
              : 'errors.generic';
    if (key === 'errors.generic') {
      console.error('[rules] Eigenes Konto anlegen fehlgeschlagen', { code: error.code });
    }
    return { status: 'error', message: t(key), values };
  }

  revalidateCategorization();
  const result = (data ?? {}) as { applied?: number; suggested?: number };
  const message =
    kind === 'name'
      ? t('addedName', { count: Number(result.suggested ?? 0) })
      : t('added', { count: Number(result.applied ?? 0) });
  return { status: 'success', message, nonce: Date.now() };
}

/** Zielkategorie eines eigenen Kontos (IBAN) ändern und neu anwenden. */
export async function setOwnAccountCategory(ruleId: string, formData: FormData): Promise<void> {
  await requireOnboardedUser(RULES_PATH);
  const categoryId = String(formData.get('category') ?? '');
  if (!isUuid(ruleId) || !isUuid(categoryId)) {
    await redirectWith(RULES_PATH, { error: '1' });
  }
  const supabase = await createClient();
  const { data, error } = await supabase.rpc('set_own_account_category', {
    p_rule_id: ruleId,
    p_category_id: categoryId,
  });
  if (error) {
    console.error('[rules] Zielkategorie ändern fehlgeschlagen', { code: error.code });
    await redirectWith(RULES_PATH, { error: '1' });
  }
  revalidateCategorization();
  await redirectWith(RULES_PATH, { ownUpdated: String(data ?? 0) });
}

/** Regel mit vielen Korrekturen deaktivieren bzw. wieder aktivieren. */
export async function setRuleActive(ruleId: string, active: boolean): Promise<void> {
  await requireOnboardedUser(RULES_PATH);
  if (!isUuid(ruleId)) {
    return;
  }
  const supabase = await createClient();
  const { error } = await supabase.rpc('set_rule_active', { p_rule_id: ruleId, p_active: active === true });
  if (error) {
    console.error('[rules] Regel (de)aktivieren fehlgeschlagen', { code: error.code });
  }
  revalidatePath(`/[locale]${RULES_PATH}`, 'page');
}

/**
 * Gruppenansicht: alle Buchungen ohne Kategorie einer Gegenpartei manuell
 * zuordnen. Die Zuordnung füttert das Gegenpartei-Gedächtnis.
 */
export async function categorizeGroup(groupKey: string, formData: FormData): Promise<void> {
  await requireOnboardedUser(GROUPS_PATH);
  const categoryId = String(formData.get('category') ?? '');
  if (groupKey.length === 0 || groupKey.length > 300 || !isUuid(categoryId)) {
    await redirectWith(GROUPS_PATH, { error: 'category' });
  }
  const supabase = await createClient();
  const { data, error } = await supabase.rpc('categorize_group', { p_key: groupKey, p_category_id: categoryId });
  if (error) {
    console.error('[groups] Gruppe zuordnen fehlgeschlagen', { code: error.code });
    await redirectWith(GROUPS_PATH, { error: '1' });
  }
  revalidateCategorization();
  await redirectWith(GROUPS_PATH, { assigned: String(data ?? 0) });
}

const REVIEW_PATH = '/dashboard/transactions/review';

/** Prüfliste: Kategorie einer Buchung setzen (Vorschlag übernehmen oder ändern). */
export async function reviewAssign(transactionId: string, formData: FormData): Promise<void> {
  await requireOnboardedUser(REVIEW_PATH);
  const categoryId = String(formData.get('category') ?? '');
  if (!isUuid(transactionId) || !isUuid(categoryId)) {
    await redirectWith(REVIEW_PATH, { error: 'category' });
  }
  const supabase = await createClient();
  const { error } = await supabase.rpc('set_transaction_category', {
    p_id: transactionId,
    p_category_id: categoryId,
  });
  if (error) {
    console.error('[review] Zuordnen fehlgeschlagen', { code: error.code });
    await redirectWith(REVIEW_PATH, { error: '1' });
  }
  revalidateCategorization();
  await redirectWith(REVIEW_PATH, { done: '1' });
}

/** Prüfliste: alle angezeigten Vorschläge übernehmen (gelten dann als manuell). */
export async function confirmAllSuggestions(formData: FormData): Promise<void> {
  await requireOnboardedUser(REVIEW_PATH);
  const ids = formData
    .getAll('id')
    .map(String)
    .filter((id) => isUuid(id))
    .slice(0, 1000);
  if (ids.length === 0) {
    await redirectWith(REVIEW_PATH, {});
  }
  const supabase = await createClient();
  const { data, error } = await supabase.rpc('confirm_suggestions', { p_ids: ids });
  if (error) {
    console.error('[review] Übernehmen fehlgeschlagen', { code: error.code });
    await redirectWith(REVIEW_PATH, { error: '1' });
  }
  revalidateCategorization();
  await redirectWith(REVIEW_PATH, { confirmed: String(data ?? 0) });
}

export type SettingsFormState = { status: 'idle' | 'success' | 'error'; message?: string };

/** Schwelle (in %) und Prüfgrenze (Betrag) des Lernverfahrens speichern. */
export async function saveCategorizationSettings(
  _prevState: SettingsFormState,
  formData: FormData,
): Promise<SettingsFormState> {
  await requireOnboardedUser(RULES_PATH);
  const t = await getTranslations('Rules.learning');
  const threshold = Number(String(formData.get('threshold') ?? '').replace(',', '.'));
  const limit = Number(String(formData.get('limit') ?? '').replace(/\./g, '').replace(',', '.'));
  if (!Number.isFinite(threshold) || threshold < 50 || threshold > 99.9 || !Number.isFinite(limit) || limit <= 0) {
    return { status: 'error', message: t('invalid') };
  }
  const supabase = await createClient();
  const { error } = await supabase.rpc('save_categorization_settings', {
    p_threshold: threshold / 100,
    p_review_amount_limit: limit,
  });
  if (error) {
    console.error('[rules] Einstellungen speichern fehlgeschlagen', { code: error.code });
    return { status: 'error', message: error.code === '22023' ? t('invalid') : t('error') };
  }
  revalidateCategorization();
  revalidatePath(`/[locale]${REVIEW_PATH}`, 'page');
  return { status: 'success', message: t('saved') };
}
