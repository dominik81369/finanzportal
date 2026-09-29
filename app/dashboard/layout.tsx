/**
 * app/dashboard/layout.tsx
 *
 * Rahmen des Mandanten-Dashboards: Kopfzeile, Bereichsnavigation, Inhalt.
 *
 * Zugriff: middleware.ts leitet ohne Session nach /login und ohne eigenes
 * Passwort nach /set-password. requireOnboardedUser() prüft beides hier ein
 * zweites Mal. Layouts werden bei Navigation zwischen Unterseiten nicht neu
 * gerendert – Seiten, die Daten laden, verlassen sich deshalb zusätzlich auf
 * RLS (Server-Client aus lib/supabase/server.ts), nie auf dieses Layout allein.
 */
import type { Metadata } from 'next';
import type { ReactNode } from 'react';

import { signOut } from '@/lib/actions/auth';
import { requireOnboardedUser } from '@/lib/supabase/server';

import { DashboardNav } from './dashboard-nav';

export const metadata: Metadata = {
  title: {
    default: 'Übersicht',
    template: '%s · Finanzportal',
  },
  robots: { index: false, follow: false },
};

export default async function DashboardLayout({ children }: { children: ReactNode }) {
  const user = await requireOnboardedUser('/dashboard');

  return (
    <div className="dashboard">
      <a className="skip-link" href="#dashboard-content">
        Zum Inhalt springen
      </a>

      <header className="dashboard-header">
        <span className="dashboard-brand">Finanzportal</span>
        <div className="dashboard-account">
          <span className="dashboard-user">{user.email}</span>
          <form action={signOut}>
            <button type="submit" className="link-button">
              Abmelden
            </button>
          </form>
        </div>
      </header>

      <div className="dashboard-body">
        <DashboardNav />
        <main id="dashboard-content" className="dashboard-content" tabIndex={-1}>
          {children}
        </main>
      </div>
    </div>
  );
}
