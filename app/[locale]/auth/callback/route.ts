/**
 * app/[locale]/auth/callback/route.ts
 *
 * Ziel aller Links aus Supabase-Auth-E-Mails. Liegt unter [locale], damit
 * Fehlerseite und Standardziel in der Sprache des Links erscheinen
 * (/auth/callback → Deutsch, /en/auth/callback → Englisch).
 *
 * 1. `?code=…` (PKCE): z. B. Bestätigung der Registrierung. Der Code wird per
 *    exchangeCodeForSession() mit dem code_verifier aus dem Cookie gegen eine
 *    Session getauscht. Das klappt nur im Browser, in dem der Flow begann.
 * 2. `?token_hash=…&type=…`: vom Server ausgelöste E-Mails (Berater-Einladung,
 *    Anmeldelink für bestehende Konten). Im Browser des Empfängers existiert
 *    kein code_verifier, PKCE ist hier also nicht möglich; stattdessen
 *    verifyOtp(). Die Links erzeugen die Templates in supabase/templates/.
 *
 * Erfolg → `next` (nur lokale Pfade, bereits lokalisiert; Standard /dashboard)
 * Fehler → /auth/auth-code-error?reason=… (in der Sprache des Links)
 *
 * Redirects gehen auf die öffentliche Origin (x-forwarded-host hinter einem
 * Reverse Proxy, abgesichert über SITE_URL – siehe lib/url.ts), damit sie auf
 * der Domain landen, für die die Session-Cookies gesetzt wurden.
 */
import type { EmailOtpType } from '@supabase/supabase-js';
import { NextResponse, type NextRequest } from 'next/server';
import { hasLocale } from 'next-intl';

import { getPathname } from '@/i18n/navigation';
import { routing } from '@/i18n/routing';
import { createClient } from '@/lib/supabase/server';
import { DEFAULT_REDIRECT_PATH, getAppOrigin, safeRedirectPath } from '@/lib/url';

const ERROR_PATH = '/auth/auth-code-error';

/** Nur die OTP-Typen, für die es Templates gibt (invite, magic_link → email). */
const ALLOWED_OTP_TYPES = ['invite', 'email'] as const satisfies readonly EmailOtpType[];
type AllowedOtpType = (typeof ALLOWED_OTP_TYPES)[number];

/** Muss zu REASONS in app/[locale]/auth/auth-code-error/page.tsx passen. */
type AuthCallbackFailure = 'expired' | 'other_browser' | 'invalid';

function isAllowedOtpType(value: string | null): value is AllowedOtpType {
  return (ALLOWED_OTP_TYPES as readonly string[]).includes(value ?? '');
}

function classifyFailure(errorCode: string | undefined): AuthCallbackFailure {
  switch (errorCode) {
    case 'otp_expired':
    case 'flow_state_expired':
    case 'flow_state_not_found': // Code bereits eingelöst
      return 'expired';
    case 'pkce_code_verifier_not_found':
    case 'bad_code_verifier':
      return 'other_browser';
    default:
      return 'invalid';
  }
}

/** Redirect, der nie gecacht wird – die Antwort setzt Session-Cookies. */
function redirectNoStore(url: string | URL): NextResponse {
  const response = NextResponse.redirect(url);
  response.headers.set('Cache-Control', 'private, no-cache, no-store, must-revalidate, max-age=0');
  return response;
}

type CallbackContext = { params: Promise<{ locale: string }> };

export async function GET(request: NextRequest, { params }: CallbackContext) {
  const { locale: requestedLocale } = await params;
  const locale = hasLocale(routing.locales, requestedLocale) ? requestedLocale : routing.defaultLocale;

  const { searchParams } = request.nextUrl;
  const origin = getAppOrigin(request.headers, request.nextUrl);
  const next = safeRedirectPath(
    searchParams.get('next'),
    getPathname({ href: DEFAULT_REDIRECT_PATH, locale }),
  );

  // Supabase meldet Fehler (z. B. abgelaufener Link) als Query-Parameter.
  let errorCode: string | undefined =
    searchParams.get('error_code') ?? (searchParams.has('error') ? 'provider_error' : undefined);

  if (!errorCode) {
    const code = searchParams.get('code');
    const tokenHash = searchParams.get('token_hash');
    const type = searchParams.get('type');

    if (code) {
      const supabase = await createClient();
      // Neuere auth-js-Versionen hängen bei mehreren parallelen Flows eine
      // Flow-ID an; serverseitig muss sie explizit übergeben werden.
      const flowId = searchParams.get('sb_flow_id');
      const { error } = await supabase.auth.exchangeCodeForSession(
        code,
        flowId ? { flowId } : undefined,
      );
      if (!error) {
        return redirectNoStore(`${origin}${next}`);
      }
      errorCode = error.code ?? 'exchange_failed';
    } else if (tokenHash && isAllowedOtpType(type)) {
      const supabase = await createClient();
      const { error } = await supabase.auth.verifyOtp({ type, token_hash: tokenHash });
      if (!error) {
        return redirectNoStore(`${origin}${next}`);
      }
      errorCode = error.code ?? 'verify_failed';
    } else {
      errorCode = 'missing_params';
    }
  }

  const errorUrl = new URL(getPathname({ href: ERROR_PATH, locale }), origin);
  errorUrl.searchParams.set('reason', classifyFailure(errorCode));
  return redirectNoStore(errorUrl);
}
