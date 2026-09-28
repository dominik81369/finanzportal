/**
 * app/login/page.tsx
 *
 * Anmeldung mit E-Mail und Passwort. Die eigentliche Anmeldung erfolgt in der
 * Server Action signIn() (lib/actions/auth.ts). `next` wird von middleware.ts
 * gesetzt, wenn ein geschützter Pfad ohne Session aufgerufen wurde.
 */
import type { Metadata } from 'next';

import { parseRedirectPath } from '@/lib/url';

import { LoginForm } from './login-form';

export const metadata: Metadata = {
  title: 'Anmelden',
};

type LoginPageProps = {
  searchParams: Promise<{ next?: string | string[] }>;
};

export default async function LoginPage({ searchParams }: LoginPageProps) {
  const { next } = await searchParams;

  return (
    <main className="auth-card">
      <h1>Anmelden</h1>
      <LoginForm next={parseRedirectPath(next)} />
    </main>
  );
}
