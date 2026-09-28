/**
 * app/signup/page.tsx
 *
 * Registrierung mit E-Mail und Passwort. Die Registrierung erfolgt in der
 * Server Action signUp() (lib/actions/auth.ts). Der Bestätigungslink führt
 * über app/auth/callback (PKCE) zu `next`, Standard /dashboard.
 */
import type { Metadata } from 'next';

import { parseRedirectPath } from '@/lib/url';

import { SignupForm } from './signup-form';

export const metadata: Metadata = {
  title: 'Registrieren',
};

type SignupPageProps = {
  searchParams: Promise<{ next?: string | string[] }>;
};

export default async function SignupPage({ searchParams }: SignupPageProps) {
  const { next } = await searchParams;

  return (
    <main className="auth-card">
      <h1>Konto erstellen</h1>
      <SignupForm next={parseRedirectPath(next)} />
    </main>
  );
}
