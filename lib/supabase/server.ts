/**
 * lib/supabase/server.ts
 *
 * Supabase-Client für Server Components, Server Actions und Route Handlers.
 * Pro Request eine neue Instanz (Cookies sind request-gebunden).
 *
 * Authentifizierung ausschließlich über `auth.getUser()`: validiert das JWT
 * gegen den Supabase-Auth-Server. `getSession()` liest nur das Cookie und ist
 * serverseitig fälschbar.
 *
 * Die Guards `requireUser()` / `requireAdvisor()` gehören in jedes geschützte
 * Layout bzw. jede Server Action – die Middleware ist nur die erste Schicht.
 */
import 'server-only';

import { createServerClient } from '@supabase/ssr';
import type { User } from '@supabase/supabase-js';
import { cookies } from 'next/headers';
import { cache } from 'react';

import { localizedPath, redirectLocalized } from '@/i18n/paths';
import type { Database } from '@/types/database';
import type { UserRole } from '@/types/domain';

import { getSupabasePublicEnv } from './env';

export async function createClient() {
  const cookieStore = await cookies();
  const { url, anonKey } = getSupabasePublicEnv();

  return createServerClient<Database>(url, anonKey, {
    cookies: {
      getAll() {
        return cookieStore.getAll();
      },
      setAll(cookiesToSet) {
        try {
          for (const { name, value, options } of cookiesToSet) {
            cookieStore.set(name, value, options);
          }
        } catch {
          // Server Components dürfen keine Cookies schreiben. Der Token-Refresh
          // erfolgt in der Middleware, daher kann dieser Fall ignoriert werden.
        }
      },
    },
  });
}

/**
 * Liefert den verifizierten Nutzer oder null.
 * Per React `cache()` innerhalb eines Server-Render-Durchlaufs dedupliziert.
 */
export const getSessionUser = cache(async (): Promise<User | null> => {
  const supabase = await createClient();
  const { data, error } = await supabase.auth.getUser();

  if (error || !data.user) {
    return null;
  }
  return data.user;
});

/** Rolle des aktuellen Nutzers aus `profiles` (RLS: eigenes Profil lesbar). */
export const getCurrentUserRole = cache(async (): Promise<UserRole | null> => {
  const user = await getSessionUser();
  if (!user) {
    return null;
  }

  const supabase = await createClient();
  const { data, error } = await supabase
    .from('profiles')
    .select('role')
    .eq('user_id', user.id)
    .maybeSingle();

  if (error || !data) {
    return null;
  }
  return data.role;
});

/**
 * Erzwingt einen angemeldeten Nutzer, sonst Redirect nach /login.
 * Prüft bewusst NICHT, ob ein Passwort gesetzt ist – das nutzen /set-password
 * selbst und die Einladungsannahme. Für alle übrigen geschützten Bereiche
 * requireOnboardedUser() verwenden.
 */
export async function requireUser(): Promise<User> {
  const user = await getSessionUser();
  if (!user) {
    return redirectLocalized('/login');
  }
  return user;
}

/**
 * Zweite Verteidigungslinie zu middleware.ts: Konten ohne eigenes Passwort
 * (per Einladung angelegt) zuerst nach /set-password. Ist der Zustand nicht
 * ermittelbar, wird ebenfalls umgeleitet (fail closed) – /set-password zeigt
 * dann einen Hinweis statt des Formulars.
 *
 * @param nextPath Pfad ohne Sprachpräfix, z. B. /dashboard
 */
async function ensurePasswordSet(nextPath: string): Promise<void> {
  if ((await currentUserHasPassword()) !== true) {
    await redirectLocalized('/set-password', await localizedPath(nextPath));
  }
}

/**
 * Erzwingt einen angemeldeten Nutzer mit eigenem Passwort. Für Layouts und
 * Server Actions der Mandantenbereiche (z. B. app/[locale]/dashboard/layout.tsx).
 * nextPath ohne Sprachpräfix – er wird hier lokalisiert.
 */
export async function requireOnboardedUser(nextPath = '/dashboard'): Promise<User> {
  const user = await requireUser();
  await ensurePasswordSet(nextPath);
  return user;
}

/** Erzwingt die Rolle advisor mit eigenem Passwort, sonst Redirect. */
export async function requireAdvisor(): Promise<User> {
  const user = await requireUser();
  const role = await getCurrentUserRole();
  if (role !== 'advisor') {
    await redirectLocalized('/dashboard');
  }
  await ensurePasswordSet('/advisor');
  return user;
}

/**
 * Hat der angemeldete Nutzer selbst ein Passwort festgelegt? Per Einladung
 * angelegte Konten zunächst nicht (profiles.password_set_at, nur per Trigger
 * gepflegt – siehe Migration 20260928000000_profiles_password_set_at.sql).
 * null = konnte nicht ermittelt werden.
 */
export async function currentUserHasPassword(): Promise<boolean | null> {
  const user = await getSessionUser();
  if (!user) {
    return null;
  }

  const supabase = await createClient();
  const { data, error } = await supabase
    .from('profiles')
    .select('password_set_at')
    .eq('user_id', user.id)
    .maybeSingle();

  if (error || !data) {
    console.error('[auth] password_set_at nicht lesbar', { code: error?.code });
    return null;
  }
  return data.password_set_at !== null;
}
