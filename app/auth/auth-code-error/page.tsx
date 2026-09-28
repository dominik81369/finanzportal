/**
 * app/auth/auth-code-error/page.tsx
 *
 * Fehlerseite für app/auth/callback. `reason` ist ein fester Schlüssel aus
 * der Callback-Route – es werden nie Texte aus der URL angezeigt.
 */
import type { Metadata } from 'next';
import Link from 'next/link';

export const metadata: Metadata = {
  title: 'Link ungültig',
  robots: { index: false, follow: false },
};

const REASONS = {
  expired: {
    title: 'Link abgelaufen',
    text: 'Dieser Link ist abgelaufen oder wurde bereits verwendet. Falls Sie sich registriert haben, versuchen Sie, sich anzumelden. Für eine Einladung bitten Sie Ihren Berater, sie erneut zu senden.',
  },
  other_browser: {
    title: 'Bitte denselben Browser verwenden',
    text: 'Der Bestätigungslink muss in dem Browser geöffnet werden, in dem Sie sich registriert haben. Ihre E-Mail-Adresse ist möglicherweise trotzdem bereits bestätigt – versuchen Sie, sich anzumelden.',
  },
  invalid: {
    title: 'Anmeldung fehlgeschlagen',
    text: 'Der Link ist ungültig oder unvollständig. Bitte öffnen Sie ihn direkt aus der E-Mail oder fordern Sie einen neuen an.',
  },
} as const;

type AuthCodeErrorPageProps = {
  searchParams: Promise<{ reason?: string | string[] }>;
};

export default async function AuthCodeErrorPage({ searchParams }: AuthCodeErrorPageProps) {
  const { reason } = await searchParams;
  const { title, text } =
    typeof reason === 'string' && Object.hasOwn(REASONS, reason)
      ? REASONS[reason as keyof typeof REASONS]
      : REASONS.invalid;

  return (
    <main className="auth-card">
      <h1>{title}</h1>
      <p>{text}</p>
      <div className="actions">
        <Link className="button" href="/login">
          Zur Anmeldung
        </Link>
        <Link className="button button-secondary" href="/signup">
          Registrieren
        </Link>
      </div>
    </main>
  );
}
