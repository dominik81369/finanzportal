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
      .select('id, name, kind, parent_category_id, sort_order')
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

  // Unterkategorien als "Oberkategorie › Unterkategorie" anzeigen.
  const categoryNames = new Map(categories.data.map((c) => [c.id, c.name]));
  const categoryOptions: CategoryOption[] = categories.data.map((c) => {
    const parent = c.parent_category_id ? categoryNames.get(c.parent_category_id) : undefined;
    return { id: c.id, kind: c.kind, label: parent ? `${parent} › ${c.name}` : c.name };
  });

  return { accounts: accounts.data, categories: categoryOptions, tags: tags.data };
}
