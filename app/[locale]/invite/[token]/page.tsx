/**
 * app/[locale]/invite/[token]/page.tsx
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
import { getTranslations } from 'next-intl/server';
import type { ReactNode } from 'react';

import { Link } from '@/i18n/navigation';
import { localizedPath } from '@/i18n/paths';
import { toAppLocale } from '@/i18n/routing';
import { signOut } from '@/lib/actions/auth';
import { invitePath, isWellFormedInviteToken } from '@/lib/invite-token';
import { getSessionUser } from '@/lib/supabase/server';

import { AcceptInvitationForm } from './accept-invitation-form';

type InvitePageProps = {
  params: Promise<{ locale: string; token: string }>;
};

export async function generateMetadata({ params }: InvitePageProps): Promise<Metadata> {
  const t = await getTranslations({ locale: toAppLocale((await params).locale), namespace: 'Invite' });
  return {
    title: t('metaTitle'),
    referrer: 'no-referrer',
    robots: { index: false, follow: false },
  };
}

export default async function InvitePage({ params }: InvitePageProps) {
  const { token } = await params;
  const t = await getTranslations('Invite');

  if (!isWellFormedInviteToken(token)) {
    return (
      <main className="auth-card">
        <h1>{t('invalidHeading')}</h1>
        <p role="alert">{t('invalidText')}</p>
      </main>
    );
  }

  // Rückweg nach Anmeldung/Registrierung – in der Sprache dieser Seite.
  const path = await localizedPath(invitePath(token));
  const user = await getSessionUser();

  if (!user) {
    return (
      <main className="auth-card">
        <h1>{t('guestHeading')}</h1>
        <p>{t('guestText')}</p>
        <div className="actions">
          <Link className="button" href={{ pathname: '/login', query: { next: path } }}>
            {t('login')}
          </Link>
          <Link
            className="button button-secondary"
            href={{ pathname: '/signup', query: { next: path } }}
          >
            {t('signup')}
          </Link>
        </div>
      </main>
    );
  }

  const strong = (chunks: ReactNode) => <strong>{chunks}</strong>;

  return (
    <main className="auth-card">
      <h1>{t('heading')}</h1>
      <p>{t.rich('signedInAs', { email: user.email ?? '', strong })}</p>
      <p>{t.rich('consent', { strong })}</p>

      <AcceptInvitationForm token={token} />

      <form action={signOut} className="secondary-action">
        <input type="hidden" name="next" value={path} />
        <p className="hint">{t('notYourAccount')}</p>
        <button type="submit" className="link-button">
          {t('switchAccount')}
        </button>
      </form>
    </main>
  );
}
