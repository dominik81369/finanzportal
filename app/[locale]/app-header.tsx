/**
 * Kopfzeile der angemeldeten Bereiche (Mandanten-Dashboard und
 * Beraterbereich): Marke, optionaler Wechsel-Link, E-Mail, Abmelden.
 */
import { getTranslations } from 'next-intl/server';

import { Link } from '@/i18n/navigation';
import { signOut } from '@/lib/actions/auth';

type AppHeaderProps = {
  email: string | undefined;
  /** z. B. Berater: Link zu den eigenen Finanzen bzw. zurück zum Beraterbereich. */
  switchLink?: { href: string; label: string };
};

export async function AppHeader({ email, switchLink }: AppHeaderProps) {
  const t = await getTranslations('Dashboard');
  const tMeta = await getTranslations('Metadata');

  return (
    <header className="dashboard-header">
      <span className="dashboard-brand">{tMeta('appName')}</span>
      <div className="dashboard-account">
        {switchLink ? (
          <Link className="header-switch" href={switchLink.href}>
            {switchLink.label}
          </Link>
        ) : null}
        <span className="dashboard-user">{email}</span>
        <form action={signOut}>
          <button type="submit" className="link-button">
            {t('signOut')}
          </button>
        </form>
      </div>
    </header>
  );
}
