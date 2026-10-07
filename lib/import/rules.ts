/**
 * lib/import/rules.ts
 *
 * Reihenfolge der eigenen Kategorisierungsregeln wie in private.match_rule
 * (Standardregeln laufen danach):
 * priority aufsteigend, bei Gleichstand das längere (spezifischere) Muster
 * zuerst, dann die ältere Regel. Gespeicherte Muster sind bereits
 * normalisiert (public.create_categorization_rule, gelernte Regeln).
 */
export type SortableRule = { id: string; pattern: string; priority: number; created_at: string };

export function sortRules<T extends SortableRule>(rules: readonly T[]): T[] {
  return [...rules].sort(
    (a, b) =>
      a.priority - b.priority ||
      b.pattern.length - a.pattern.length ||
      a.created_at.localeCompare(b.created_at) ||
      a.id.localeCompare(b.id),
  );
}

/** Felder, die eine eigene Regel prüfen kann (Formular „Neue Regel“). */
export const RULE_FIELDS = [
  'counterparty_or_purpose',
  'counterparty',
  'purpose',
  'description',
  'transaction_type',
  'counterparty_iban',
  'any_text',
] as const;
export type RuleField = (typeof RULE_FIELDS)[number];

/** Vergleichsarten im Formular (regex nur per Datenbank). */
export const RULE_MATCH_TYPES = ['contains', 'word', 'equals', 'starts_with'] as const;
export type RuleMatchType = (typeof RULE_MATCH_TYPES)[number];

/** Richtung: '' = Ein- und Ausgänge, in = nur Eingänge, out = nur Ausgaben. */
export const RULE_DIRECTIONS = ['', 'in', 'out'] as const;
export type RuleDirection = (typeof RULE_DIRECTIONS)[number];

export const isRuleField = (value: string): value is RuleField => (RULE_FIELDS as readonly string[]).includes(value);
export const isRuleMatchType = (value: string): value is RuleMatchType =>
  (RULE_MATCH_TYPES as readonly string[]).includes(value);
export const isRuleDirection = (value: string): value is RuleDirection =>
  (RULE_DIRECTIONS as readonly string[]).includes(value);

/** Richtung aus dem Betragsbereich einer Regel (wie public.create_categorization_rule). */
export function ruleDirection(rule: { amount_min: number | null; amount_max: number | null }): RuleDirection {
  if (rule.amount_min !== null && rule.amount_min > 0 && rule.amount_max === null) {
    return 'in';
  }
  if (rule.amount_max !== null && rule.amount_max < 0 && rule.amount_min === null) {
    return 'out';
  }
  return '';
}
