/**
 * app/[locale]/signup/page.tsx
 *
 * Registrierung mit E-Mail und Passwort. Die Registrierung erfolgt in der
 * Server Action signUp() (lib/actions/auth.ts). Der Bestätigungslink führt
 * über app/auth/callback (PKCE) zu `next`, Standard /dashboard.
 */
import type { Metadata } from 'next';
import { getTranslations } from 'next-intl/server';

import { toAppLocale } from '@/i18n/routing';
import { parseRedirectPath } from '@/lib/url';

import { SignupForm } from './signup-form';

type SignupPageProps = {
  params: Promise<{ locale: string }>;
  searchParams: Promise<{ next?: string | string[] }>;
};

export async function generateMetadata({ params }: Pick<SignupPageProps, 'params'>): Promise<Metadata> {
  const t = await getTranslations({ locale: toAppLocale((await params).locale), namespace: 'Signup' });
  return { title: t('metaTitle') };
}

export default async function SignupPage({ searchParams }: SignupPageProps) {
  const { next } = await searchParams;
  const t = await getTranslations('Signup');

  return (
    <main className="auth-card">
      <h1>{t('heading')}</h1>
      <SignupForm next={parseRedirectPath(next)} />
    </main>
  );
}
