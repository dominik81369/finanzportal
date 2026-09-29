/**
 * app/[locale]/set-password/page.tsx
 *
 * Erstes Passwort für per Einladung angelegte Konten. Nur für angemeldete
 * Nutzer (middleware.ts + requireUser()). Konten mit Passwort werden direkt
 * zu `next` weitergeleitet – die Seite ist keine Passwortänderung.
 */
import type { Metadata } from 'next';
import { redirect } from 'next/navigation';
import { getTranslations } from 'next-intl/server';

import { toAppLocale } from '@/i18n/routing';
import { localizedPath } from '@/i18n/paths';
import { currentUserHasPassword, requireUser } from '@/lib/supabase/server';
import { DEFAULT_REDIRECT_PATH, safeRedirectPath } from '@/lib/url';

import { SetPasswordForm } from './set-password-form';

type SetPasswordPageProps = {
  params: Promise<{ locale: string }>;
  searchParams: Promise<{ next?: string | string[] }>;
};

export async function generateMetadata({
  params,
}: Pick<SetPasswordPageProps, 'params'>): Promise<Metadata> {
  const t = await getTranslations({ locale: toAppLocale((await params).locale), namespace: 'SetPassword' });
  return { title: t('metaTitle'), robots: { index: false, follow: false } };
}

export default async function SetPasswordPage({ searchParams }: SetPasswordPageProps) {
  const user = await requireUser();
  const t = await getTranslations('SetPassword');
  // `next` ist bereits lokalisiert; nur der Standard braucht das Präfix.
  const next = safeRedirectPath((await searchParams).next, await localizedPath(DEFAULT_REDIRECT_PATH));

  const hasPassword = await currentUserHasPassword();
  if (hasPassword) {
    redirect(next);
  }

  return (
    <main className="auth-card">
      <h1>{t('heading')}</h1>
      <p>
        {t.rich('welcome', {
          email: user.email ?? '',
          strong: (chunks) => <strong>{chunks}</strong>,
        })}
      </p>
      {hasPassword === null ? (
        <p role="alert" className="form-error">
          {t('checkFailed')}
        </p>
      ) : (
        <SetPasswordForm next={next} />
      )}
    </main>
  );
}
