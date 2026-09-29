/**
 * app/[locale]/auth/auth-code-error/page.tsx
 *
 * Fehlerseite für app/[locale]/auth/callback. `reason` ist ein fester
 * Schlüssel aus der Callback-Route – es werden nie Texte aus der URL angezeigt.
 */
import type { Metadata } from 'next';
import { getTranslations } from 'next-intl/server';

import { Link } from '@/i18n/navigation';
import { toAppLocale } from '@/i18n/routing';

/** Muss zu AuthCallbackFailure in app/[locale]/auth/callback/route.ts passen. */
const REASONS = ['expired', 'other_browser', 'invalid'] as const;
type Reason = (typeof REASONS)[number];

type AuthCodeErrorPageProps = {
  params: Promise<{ locale: string }>;
  searchParams: Promise<{ reason?: string | string[] }>;
};

export async function generateMetadata({
  params,
}: Pick<AuthCodeErrorPageProps, 'params'>): Promise<Metadata> {
  const t = await getTranslations({ locale: toAppLocale((await params).locale), namespace: 'AuthCodeError' });
  return { title: t('metaTitle'), robots: { index: false, follow: false } };
}

function isReason(value: unknown): value is Reason {
  return typeof value === 'string' && (REASONS as readonly string[]).includes(value);
}

export default async function AuthCodeErrorPage({ searchParams }: AuthCodeErrorPageProps) {
  const { reason } = await searchParams;
  const key: Reason = isReason(reason) ? reason : 'invalid';
  const t = await getTranslations('AuthCodeError');

  return (
    <main className="auth-card">
      <h1>{t(`reasons.${key}.title`)}</h1>
      <p>{t(`reasons.${key}.text`)}</p>
      <div className="actions">
        <Link className="button" href="/login">
          {t('toLogin')}
        </Link>
        <Link className="button button-secondary" href="/signup">
          {t('signup')}
        </Link>
      </div>
    </main>
  );
}
