import { getTranslations } from 'next-intl/server';

import { Link } from '@/i18n/navigation';

export async function generateMetadata() {
  const t = await getTranslations('NotFound');
  return { title: t('metaTitle'), robots: { index: false, follow: false } };
}

export default async function NotFoundPage() {
  const t = await getTranslations('NotFound');

  return (
    <main className="auth-card">
      <h1>{t('heading')}</h1>
      <p>{t('text')}</p>
      <Link className="button" href="/dashboard">
        {t('toPortal')}
      </Link>
    </main>
  );
}
