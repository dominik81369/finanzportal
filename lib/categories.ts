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
