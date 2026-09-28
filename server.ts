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
import { redirect } from 'next/navigation';
import { cache } from 'react';

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

/** Erzwingt einen angemeldeten Nutzer, sonst Redirect nach /login. */
export async function requireUser(): Promise<User> {
  const user = await getSessionUser();
  if (!user) {
    redirect('/login');
  }
  return user;
}

/** Erzwingt die Rolle advisor, sonst Redirect ins Mandanten-Dashboard. */
export async function requireAdvisor(): Promise<User> {
  const user = await requireUser();
  const role = await getCurrentUserRole();
  if (role !== 'advisor') {
    redirect('/dashboard');
  }
  return user;
}
