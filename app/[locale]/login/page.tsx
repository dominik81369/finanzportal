/**
 * app/[locale]/login/page.tsx
 *
 * Anmeldung mit E-Mail und Passwort. Die eigentliche Anmeldung erfolgt in der
 * Server Action signIn() (lib/actions/auth.ts). `next` wird von middleware.ts
 * gesetzt, wenn ein geschützter Pfad ohne Session aufgerufen wurde.
 */
import type { Metadata } from 'next';
import { getTranslations } from 'next-intl/server';

import { toAppLocale } from '@/i18n/routing';
import { parseRedirectPath } from '@/lib/url';

import { LoginForm } from './login-form';

type LoginPageProps = {
  params: Promise<{ locale: string }>;
  searchParams: Promise<{ next?: string | string[] }>;
};

export async function generateMetadata({ params }: Pick<LoginPageProps, 'params'>): Promise<Metadata> {
  const t = await getTranslations({ locale: toAppLocale((await params).locale), namespace: 'Login' });
  return { title: t('metaTitle') };
}

export default async function LoginPage({ searchParams }: LoginPageProps) {
  const { next } = await searchParams;
  const t = await getTranslations('Login');

  return (
    <main className="auth-card">
      <h1>{t('heading')}</h1>
      <LoginForm next={parseRedirectPath(next)} />
    </main>
  );
}
