/**
 * app/invite/[token]/page.tsx
 *
 * Zielseite des Einladungslinks. Das Annehmen (RPC accept_advisor_invitation)
 * erfolgt per Klick in der Server Action lib/actions/accept-invitation.ts,
 * nicht schon beim Seitenaufruf – siehe Begründung dort.
 *
 * - Ohne Session: Anmelden oder registrieren, danach zurück hierher (?next=).
 * - Mit Session: Einwilligungstext und Button; bei Erfolg → /dashboard,
 *   bei ungültigem/abgelaufenem Token eine Fehlermeldung.
 *
 * Die URL enthält das Klartext-Token: kein Referrer, keine Indexierung.
 * Die Datenbank ist auch ohne diese Vorsichtsmaßnahmen geschützt, weil die
 * RPC das Token an die bestätigte E-Mail-Adresse des Eingeladenen bindet.
 */
import type { Metadata } from 'next';
import Link from 'next/link';

import { signOut } from '@/lib/actions/auth';
import { invitePath, isWellFormedInviteToken } from '@/lib/invite-token';
import { getSessionUser } from '@/lib/supabase/server';

import { AcceptInvitationForm } from './accept-invitation-form';

export const metadata: Metadata = {
  title: 'Einladung annehmen',
  referrer: 'no-referrer',
  robots: { index: false, follow: false },
};

type InvitePageProps = {
  params: Promise<{ token: string }>;
};

export default async function InvitePage({ params }: InvitePageProps) {
  const { token } = await params;

  if (!isWellFormedInviteToken(token)) {
    return (
      <main className="auth-card">
        <h1>Einladung ungültig</h1>
        <p role="alert">
          Dieser Einladungslink ist unvollständig oder ungültig. Bitte öffnen Sie den Link direkt
          aus der E-Mail oder bitten Sie Ihren Berater, die Einladung erneut zu senden.
        </p>
      </main>
    );
  }

  const path = invitePath(token);
  const user = await getSessionUser();

  if (!user) {
    const next = encodeURIComponent(path);
    return (
      <main className="auth-card">
        <h1>Einladung von Ihrem Berater</h1>
        <p>
          Ihr Finanzberater hat Sie eingeladen, das Finanzportal gemeinsam zu nutzen. Bitte melden
          Sie sich an oder erstellen Sie ein Konto – mit der E-Mail-Adresse, an die die Einladung
          gesendet wurde.
        </p>
        <div className="actions">
          <Link className="button" href={`/login?next=${next}`}>
            Anmelden
          </Link>
          <Link className="button button-secondary" href={`/signup?next=${next}`}>
            Konto erstellen
          </Link>
        </div>
      </main>
    );
  }

  return (
    <main className="auth-card">
      <h1>Einladung annehmen</h1>
      <p>
        Angemeldet als <strong>{user.email}</strong>
      </p>
      <p>
        Mit der Annahme erhält Ihr Berater <strong>Lesezugriff</strong> auf Ihre Finanzdaten im
        Portal: Konten, Umsätze, Kategorien, Depots und Immobilien. Ändern kann er diese Daten
        nicht. Die Verbindung kann jederzeit widerrufen werden.
      </p>

      <AcceptInvitationForm token={token} />

      <form action={signOut} className="secondary-action">
        <input type="hidden" name="next" value={path} />
        <p className="hint">
          Nicht Ihr Konto? Die Einladung gilt nur für die eingeladene E-Mail-Adresse.
        </p>
        <button type="submit" className="link-button">
          Mit einem anderen Konto anmelden
        </button>
      </form>
    </main>
  );
}
