/**
 * middleware.ts
 *
 * 1. Erneuert die Supabase-Session (Token-Refresh) bei jedem Request.
 * 2. Leitet nicht angemeldete Nutzer nach /login um (mit ?next=…).
 * 3. Schützt /advisor/** – nur für profiles.role = 'advisor'.
 *
 * Authentifizierung ausschließlich über `supabase.auth.getUser()`.
 *
 * Die Middleware ist die ERSTE Schutzschicht, nicht die einzige: Layouts und
 * Server Actions prüfen zusätzlich mit requireUser()/requireAdvisor(), und RLS
 * erzwingt die Datentrennung in der Datenbank.
 *
 * Next.js 16: Datei in `proxy.ts` umbenennen und die Funktion als
 * `export async function proxy(request)` exportieren – die Logik bleibt gleich.
 */
import { createServerClient } from '@supabase/ssr';
import { NextResponse, type NextRequest } from 'next/server';

import { getSupabasePublicEnv } from '@/lib/supabase/env';
import type { Database } from '@/types/database';

const LOGIN_PATH = '/login';
const CLIENT_HOME = '/dashboard';
const ADVISOR_HOME = '/advisor';
const ADVISOR_PREFIX = '/advisor';
const API_PREFIX = '/api';

/** Ohne Anmeldung erreichbar (inkl. Pflichtseiten nach TMG/DSGVO). */
const PUBLIC_PREFIXES = [
  '/login',
  '/signup',
  '/auth',
  '/invite',
  '/impressum',
  '/datenschutz',
] as const;

/** Für angemeldete Nutzer sinnlos → Weiterleitung ins passende Cockpit. */
const AUTH_PAGES = ['/login', '/signup'] as const;

function matchesPrefix(pathname: string, prefix: string): boolean {
  return pathname === prefix || pathname.startsWith(`${prefix}/`);
}

export async function middleware(request: NextRequest) {
  let response = NextResponse.next({ request });

  const { url, anonKey } = getSupabasePublicEnv();
  const supabase = createServerClient<Database>(url, anonKey, {
    cookies: {
      getAll() {
        return request.cookies.getAll();
      },
      setAll(cookiesToSet, headers) {
        for (const { name, value } of cookiesToSet) {
          request.cookies.set(name, value);
        }
        response = NextResponse.next({ request });
        for (const { name, value, options } of cookiesToSet) {
          response.cookies.set(name, value, options);
        }
        // Verhindert, dass CDNs/Proxies Antworten mit Session-Cookies cachen
        // und so das Token eines Nutzers an einen anderen ausliefern.
        for (const [key, value] of Object.entries(headers)) {
          response.headers.set(key, value);
        }
      },
    },
  });

  // Zwischen createServerClient() und getUser() darf keine weitere Logik
  // stehen, sonst kann der Token-Refresh zu zufälligen Logouts führen.
  const {
    data: { user },
  } = await supabase.auth.getUser();

  const { pathname, search } = request.nextUrl;

  /** Redirect, der aktualisierte Session-Cookies und Cache-Header übernimmt. */
  const redirectTo = (target: string, params?: Record<string, string>) => {
    const redirectUrl = request.nextUrl.clone();
    redirectUrl.pathname = target;
    redirectUrl.search = '';
    if (params) {
      for (const [key, value] of Object.entries(params)) {
        redirectUrl.searchParams.set(key, value);
      }
    }

    const redirectResponse = NextResponse.redirect(redirectUrl);
    for (const cookie of response.cookies.getAll()) {
      redirectResponse.cookies.set(cookie);
    }
    for (const [key, value] of response.headers.entries()) {
      if (key.toLowerCase() !== 'set-cookie' && !key.toLowerCase().startsWith('x-middleware')) {
        redirectResponse.headers.set(key, value);
      }
    }
    return redirectResponse;
  };

  /** JSON-Fehler für API-Routen statt HTML-Redirect. */
  const apiError = (status: 401 | 403) => {
    const errorResponse = NextResponse.json(
      { error: status === 401 ? 'unauthorized' : 'forbidden' },
      { status },
    );
    for (const cookie of response.cookies.getAll()) {
      errorResponse.cookies.set(cookie);
    }
    return errorResponse;
  };

  const isApiRoute = matchesPrefix(pathname, API_PREFIX);
  const isPublicRoute = PUBLIC_PREFIXES.some((prefix) => matchesPrefix(pathname, prefix));
  const isAuthPage = AUTH_PAGES.some((prefix) => matchesPrefix(pathname, prefix));
  const isAdvisorRoute =
    matchesPrefix(pathname, ADVISOR_PREFIX) || matchesPrefix(pathname, `${API_PREFIX}${ADVISOR_PREFIX}`);

  // --- Nicht angemeldet --------------------------------------------------
  if (!user) {
    if (isPublicRoute) {
      return response;
    }
    if (isApiRoute) {
      return apiError(401);
    }
    return redirectTo(LOGIN_PATH, { next: `${pathname}${search}` });
  }

  // --- Angemeldet: Rolle nur laden, wo sie gebraucht wird ----------------
  if (!isAdvisorRoute && !isAuthPage) {
    return response;
  }

  const { data: profile } = await supabase
    .from('profiles')
    .select('role')
    .eq('user_id', user.id)
    .maybeSingle();

  const isAdvisor = profile?.role === 'advisor';

  if (isAuthPage) {
    return redirectTo(isAdvisor ? ADVISOR_HOME : CLIENT_HOME);
  }

  if (isAdvisorRoute && !isAdvisor) {
    return isApiRoute ? apiError(403) : redirectTo(CLIENT_HOME);
  }

  return response;
}

export const config = {
  matcher: [
    // Alle Pfade außer statischen Assets und Bildoptimierung
    '/((?!_next/static|_next/image|favicon.ico|robots.txt|sitemap.xml|.*\\.(?:svg|png|jpg|jpeg|gif|webp|ico|woff2?)$).*)',
  ],
};
