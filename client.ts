/**
 * lib/supabase/client.ts
 *
 * Supabase-Client für Client Components. Nutzt ausschließlich den öffentlichen
 * Anon-Key; alle Datenzugriffe sind durch RLS abgesichert.
 * `createBrowserClient` hält im Browser intern eine Singleton-Instanz.
 *
 * Für Autorisierungsentscheidungen niemals den Browser-Zustand verwenden –
 * diese fallen serverseitig (lib/supabase/server.ts, middleware.ts, RLS).
 */
import { createBrowserClient } from '@supabase/ssr';

import type { Database } from '@/types/database';

import { getSupabasePublicEnv } from './env';

export function createClient() {
  const { url, anonKey } = getSupabasePublicEnv();
  return createBrowserClient<Database>(url, anonKey);
}
