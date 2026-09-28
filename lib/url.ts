/**
 * lib/url.ts
 *
 * Öffentliche Origin der App und sichere Weiterleitungsziele.
 *
 * getAppOrigin(): Hinter einem Reverse Proxy (Vercel, nginx, Traefik …) sieht
 * Next.js intern oft nur den internen Host (z. B. localhost:3000). Maßgeblich
 * für Redirects und E-Mail-Links ist der Host, den der Browser verwendet hat –
 * also x-forwarded-host. Nur so landen Redirects auf der Domain, für die die
 * Session-Cookies gesetzt wurden.
 *
 * x-forwarded-host ist aber ein Request-Header: Ohne Proxy, der ihn
 * überschreibt, kann ihn jeder Client setzen (Host-Header-Injection → Redirects
 * oder Einladungslinks auf fremde Domains). Ist SITE_URL gesetzt, wird nur
 * dieser Host akzeptiert. In Produktion SITE_URL daher immer setzen.
 */

export const DEFAULT_REDIRECT_PATH = '/dashboard';

/** Hostname bzw. IPv6-Literal, optional mit Port. */
const HOST_PATTERN = /^(?:\[[0-9a-f:.]+\]|[a-z0-9](?:[a-z0-9.-]{0,251}[a-z0-9])?)(?::\d{1,5})?$/i;

const REDIRECT_BASE = 'http://redirect.invalid';

/** Mehrere Proxies hängen Werte kommagetrennt an; der erste stammt vom Client-nächsten Proxy. */
function firstHeaderValue(headers: Headers, name: string): string | null {
  const value = headers.get(name)?.split(',')[0]?.trim();
  return value ? value : null;
}

function isLoopbackHost(host: string): boolean {
  const hostname = host
    .replace(/:\d+$/, '')
    .replace(/^\[|\]$/g, '')
    .toLowerCase();
  return hostname === 'localhost' || hostname === '::1' || hostname.startsWith('127.');
}

function getConfiguredSiteUrl(): URL | null {
  const value = process.env.SITE_URL;
  if (!value) {
    return null;
  }

  let url: URL;
  try {
    url = new URL(value);
  } catch {
    throw new Error('SITE_URL ist keine gültige URL (erwartet z. B. https://portal.example.de).');
  }
  if (url.protocol !== 'https:' && url.protocol !== 'http:') {
    throw new Error('SITE_URL muss mit http:// oder https:// beginnen.');
  }
  return url;
}

function resolveProtocol(headers: Headers, host: string, requestUrl?: URL): 'http' | 'https' {
  // Öffentliche Produktionshosts laufen immer hinter TLS. Das schützt vor
  // Proxies, die x-forwarded-host, aber kein x-forwarded-proto setzen – dann
  // würde Next.js selbst "http" eintragen.
  if (process.env.NODE_ENV === 'production' && !isLoopbackHost(host)) {
    return 'https';
  }

  const forwardedProto = firstHeaderValue(headers, 'x-forwarded-proto')?.toLowerCase();
  if (forwardedProto === 'http' || forwardedProto === 'https') {
    return forwardedProto;
  }
  return requestUrl?.protocol === 'https:' ? 'https' : 'http';
}

/**
 * Öffentliche Origin (ohne abschließenden Slash), z. B. "https://portal.example.de".
 *
 * @param headers    Request-Header (Route Handler: request.headers, Server Action: await headers())
 * @param requestUrl Request-URL als Fallback, falls weder x-forwarded-host noch Host gesetzt sind
 */
export function getAppOrigin(headers: Headers, requestUrl?: URL): string {
  const siteUrl = getConfiguredSiteUrl();

  const host = (
    firstHeaderValue(headers, 'x-forwarded-host') ??
    firstHeaderValue(headers, 'host') ??
    requestUrl?.host ??
    ''
  ).toLowerCase();

  if (host && HOST_PATTERN.test(host)) {
    if (!siteUrl) {
      return `${resolveProtocol(headers, host, requestUrl)}://${host}`;
    }
    if (host === siteUrl.host) {
      return siteUrl.origin;
    }
    // Unbekannter Host trotz konfigurierter SITE_URL → nicht vertrauen.
  }

  if (siteUrl) {
    return siteUrl.origin;
  }
  if (requestUrl) {
    return requestUrl.origin;
  }
  throw new Error('Origin der Anwendung nicht ermittelbar (kein Host-Header). Bitte SITE_URL setzen.');
}

/**
 * Liefert einen lokalen Pfad (inkl. Query/Hash) oder null.
 * Schutz vor Open Redirects: "//evil.example" und "/\evil.example" würden
 * Browser als Verweis auf eine fremde Domain interpretieren.
 */
export function parseRedirectPath(value: unknown): string | null {
  if (typeof value !== 'string' || value.length === 0 || value.length > 2048) {
    return null;
  }
  if (!value.startsWith('/') || value.startsWith('//') || value.includes('\\')) {
    return null;
  }

  try {
    const url = new URL(value, REDIRECT_BASE);
    // Der URL-Parser entfernt Tabs/Zeilenumbrüche ("/\t/evil.example") –
    // deshalb das normalisierte Ergebnis erneut prüfen.
    if (url.origin !== REDIRECT_BASE || url.pathname.startsWith('//')) {
      return null;
    }
    return `${url.pathname}${url.search}${url.hash}`;
  } catch {
    return null;
  }
}

/** Wie parseRedirectPath(), aber mit Fallback statt null. */
export function safeRedirectPath(value: unknown, fallback: string = DEFAULT_REDIRECT_PATH): string {
  return parseRedirectPath(value) ?? fallback;
}
