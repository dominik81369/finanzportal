/**
 * lib/categories.ts
 *
 * Anzeigename von Kategorien. Standardkategorien tragen einen Schlüssel
 * (categories.default_key, Migration 20261002120000) und werden in der
 * Sprache der Seite angezeigt (messages/*.json → DefaultCategories).
 * Eigene Kategorien – und Standardkategorien ohne bekannten Schlüssel –
 * zeigen den gespeicherten Namen.
 *
 * Wichtig für ein späteres Umbenennen von Kategorien: Beim Umbenennen einer
 * Standardkategorie default_key auf NULL setzen, sonst bliebe die
 * Übersetzung sichtbar statt des neuen Namens.
 */
import type de from '@/messages/de.json';

type DefaultCategoryKey = keyof (typeof de)['DefaultCategories'];

/** Übersetzer für den Namespace DefaultCategories (getTranslations/useTranslations). */
type DefaultCategoryTranslator = {
  (key: DefaultCategoryKey): string;
  has(key: DefaultCategoryKey): boolean;
};

export function categoryDisplayName(
  category: { name: string; default_key: string | null },
  t: DefaultCategoryTranslator,
): string {
  const key = category.default_key as DefaultCategoryKey | null;
  return key && t.has(key) ? t(key) : category.name;
}

/**
 * Kategorien in Baumreihenfolge: jede Oberkategorie, direkt darunter ihre
 * Unterkategorien (beliebig tief). Die Eingabe bestimmt die Reihenfolge
 * innerhalb einer Ebene (z. B. nach sort_order, name sortiert). Kategorien,
 * deren Oberkategorie fehlt, gelten als Oberkategorien.
 */
export function orderCategoryTree<T extends { id: string; parent_category_id: string | null }>(
  categories: T[],
): { category: T; depth: number }[] {
  const ids = new Set(categories.map((c) => c.id));
  const result: { category: T; depth: number }[] = [];
  const seen = new Set<string>();
  const visit = (category: T, depth: number) => {
    if (seen.has(category.id)) {
      return;
    }
    seen.add(category.id);
    result.push({ category, depth });
    for (const child of categories.filter((c) => c.parent_category_id === category.id)) {
      visit(child, depth + 1);
    }
  };
  for (const root of categories.filter((c) => !c.parent_category_id || !ids.has(c.parent_category_id))) {
    visit(root, 0);
  }
  return result;
}
