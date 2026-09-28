/**
 * app/set-password/page.tsx
 *
 * Erstes Passwort für per Einladung angelegte Konten. Nur für angemeldete
 * Nutzer (middleware.ts + requireUser()). Konten mit Passwort werden direkt
 * zu `next` weitergeleitet – die Seite ist keine Passwortänderung.
 */
import type { Metadata } from 'next';
import { redirect } from 'next/navigation';

import { currentUserHasPassword, requireUser } from '@/lib/supabase/server';
import { safeRedirectPath } from '@/lib/url';

import { SetPasswordForm } from './set-password-form';

export const metadata: Metadata = {
  title: 'Passwort festlegen',
  robots: { index: false, follow: false },
};

type SetPasswordPageProps = {
  searchParams: Promise<{ next?: string | string[] }>;
};

export default async function SetPasswordPage({ searchParams }: SetPasswordPageProps) {
  const user = await requireUser();
  const next = safeRedirectPath((await searchParams).next);

  const hasPassword = await currentUserHasPassword();
  if (hasPassword) {
    redirect(next);
  }

  return (
    <main className="auth-card">
      <h1>Passwort festlegen</h1>
      <p>
        Willkommen im Finanzportal! Legen Sie ein Passwort fest, damit Sie sich künftig mit{' '}
        <strong>{user.email}</strong> anmelden können.
      </p>
      {hasPassword === null ? (
        <p role="alert" className="form-error">
          Ihr Konto konnte gerade nicht geprüft werden. Bitte laden Sie die Seite neu.
        </p>
      ) : (
        <SetPasswordForm next={next} />
      )}
    </main>
  );
}
