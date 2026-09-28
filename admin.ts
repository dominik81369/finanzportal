/**
 * lib/supabase/admin.ts
 *
 * Service-Role-Client: umgeht RLS vollständig.
 * `import 'server-only'` bricht den Build ab, sobald diese Datei (direkt oder
 * transitiv) in eine Client Component importiert wird.
 *
 * Zulässige Einsatzzwecke (abschließend):
 *   - Berater-Rolle vergeben (profiles.role)
 *   - Einladungs-E-Mails versenden (auth.admin.inviteUserByEmail / generateLink)
 *   - Konto-Löschung nach Art. 17 DSGVO (auth.admin.deleteUser → Cascade)
 * Jeder Aufruf muss vorher die Berechtigung des Aufrufers selbst prüfen,
 * da RLS hier nicht greift.
 *
 * Bewusst KEIN Modul-Singleton: Eine versehentlich gesetzte Session (z. B. durch
 * einen signIn-Aufruf) würde sonst zwischen Requests verschiedener Nutzer geteilt.
 */
import 'server-only';

import { createClient } from '@supabase/supabase-js';

import type { Database } from '@/types/database';

export function createAdminClient() {
  if (typeof window !== 'undefined') {
    throw new Error('createAdminClient() darf ausschließlich serverseitig aufgerufen werden.');
  }

  const url = process.env.SUPABASE_URL ?? process.env.NEXT_PUBLIC_SUPABASE_URL;
  const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;

  if (!url || !serviceRoleKey) {
    throw new Error(
      'Supabase-Admin-Konfiguration fehlt: SUPABASE_URL (oder NEXT_PUBLIC_SUPABASE_URL) und SUPABASE_SERVICE_ROLE_KEY müssen gesetzt sein.',
    );
  }

  return createClient<Database>(url, serviceRoleKey, {
    auth: {
      persistSession: false,
      autoRefreshToken: false,
      detectSessionInUrl: false,
    },
  });
}
