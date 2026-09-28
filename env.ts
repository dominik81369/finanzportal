/**
 * lib/supabase/env.ts
 *
 * Öffentliche Supabase-Konfiguration für Browser, Server und Middleware.
 * Enthält bewusst KEINE geheimen Werte – der service_role Key wird
 * ausschließlich in lib/supabase/admin.ts gelesen.
 *
 * Die Variablen müssen statisch als `process.env.NEXT_PUBLIC_…` referenziert
 * werden, damit Next.js sie zur Build-Zeit ins Client-Bundle einsetzt.
 */

export type SupabasePublicEnv = {
  url: string;
  anonKey: string;
};

export function getSupabasePublicEnv(): SupabasePublicEnv {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const anonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;

  if (!url || !anonKey) {
    throw new Error(
      'Supabase-Konfiguration fehlt: NEXT_PUBLIC_SUPABASE_URL und NEXT_PUBLIC_SUPABASE_ANON_KEY müssen gesetzt sein.',
    );
  }

  return { url, anonKey };
}
