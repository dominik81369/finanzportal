/**
 * app/[locale]/dashboard/transactions/form-options.ts
 *
 * Auswahllisten des Buchungsformulars (Konten, Kategorien, Tags) für
 * Anlegen und Bearbeiten.
 *
 * Alle Abfragen filtern ausdrücklich auf user_id = eigener Nutzer: RLS lässt
 * Berater zusätzlich die Daten ihrer Mandanten LESEN – ohne Filter stünden
 * deren Konten und Kategorien in der Auswahl.
 */
import 'server-only';

import { getTranslations } from 'next-intl/server';

import { categoryDisplayName } from '@/lib/categories';
import { createClient } from '@/lib/supabase/server';

import type { CategoryOption } from './transaction-form';

/** null, wenn eine der Abfragen fehlschlägt. */
export async function loadTransactionFormOptions(userId: string) {
  const supabase = await createClient();

  const [accounts, categories, tags] = await Promise.all([
    supabase
      .from('accounts')
      .select('id, name, currency')
      .eq('user_id', userId)
      .is('archived_at', null)
      .order('name'),
    supabase
      .from('categories')
      .select('id, name, default_key, kind, parent_category_id, sort_order')
      .eq('user_id', userId)
      .order('sort_order')
      .order('name'),
    supabase.from('tags').select('id, name').eq('user_id', userId).order('name'),
  ]);

  if (accounts.error || categories.error || tags.error) {
    const code = (accounts.error ?? categories.error ?? tags.error)?.code;
    console.error('[transactions] Auswahllisten nicht ladbar', { code });
    return null;
  }

  // Standardkategorien in der Sprache der Seite; Unterkategorien als
  // "Oberkategorie › Unterkategorie".
  const tCategories = await getTranslations('DefaultCategories');
  const categoryNames = new Map(
    categories.data.map((c) => [c.id, categoryDisplayName(c, tCategories)]),
  );
  const categoryOptions: CategoryOption[] = categories.data.map((c) => {
    const parent = c.parent_category_id ? categoryNames.get(c.parent_category_id) : undefined;
    const name = categoryNames.get(c.id) ?? c.name;
    return { id: c.id, kind: c.kind, label: parent ? `${parent} › ${name}` : name };
  });

  return { accounts: accounts.data, categories: categoryOptions, tags: tags.data };
}
