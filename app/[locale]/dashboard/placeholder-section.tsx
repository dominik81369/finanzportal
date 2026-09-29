/**
 * Platzhalter für Dashboard-Bereiche, deren Oberfläche noch folgt. Nennt,
 * was geplant ist, damit die Seite nicht wie ein Fehler wirkt.
 *
 * Texte aus messages/*.json unter Dashboard.<section> (title, description,
 * planned.*). Die Reihenfolge der geplanten Punkte folgt der JSON-Datei.
 */
import type { Metadata } from 'next';
import { getMessages, getTranslations } from 'next-intl/server';

import { toAppLocale } from '@/i18n/routing';

export type DashboardSection = 'overview' | 'transactions' | 'budgets' | 'contracts' | 'netWorth';

type LocaleParams = { params: Promise<{ locale: string }> };

/** generateMetadata für Platzhalterseiten: Titel aus Dashboard.<section>.title. */
export function placeholderMetadata(section: DashboardSection) {
  return async ({ params }: LocaleParams): Promise<Metadata> => {
    const t = await getTranslations({ locale: toAppLocale((await params).locale), namespace: 'Dashboard' });
    return { title: t(`${section}.title`) };
  };
}

export async function PlaceholderSection({ section }: { section: DashboardSection }) {
  const t = await getTranslations('Dashboard');
  const planned = Object.values((await getMessages()).Dashboard[section].planned);

  return (
    <section className="placeholder" aria-labelledby="page-title">
      <h1 id="page-title">{t(`${section}.title`)}</h1>
      <p>{t(`${section}.description`)}</p>
      <div className="placeholder-box">
        <p className="placeholder-label">{t('placeholderLabel')}</p>
        <ul>
          {planned.map((item) => (
            <li key={item}>{item}</li>
          ))}
        </ul>
      </div>
    </section>
  );
}
