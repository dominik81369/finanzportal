/**
 * lib/import/rules.ts
 *
 * Reihenfolge der Kategorisierungsregeln wie in private.match_category_rule:
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
