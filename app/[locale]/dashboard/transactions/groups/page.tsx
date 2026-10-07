/**
 * app/[locale]/dashboard/transactions/groups/page.tsx
 *
 * Buchungen ohne Kategorie nach Gegenpartei gruppiert (Anzahl absteigend,
 * public.uncategorized_groups). Ein Klick ordnet die ganze Gruppe manuell
 * zu (public.categorize_group); daraus lernt das Gegenpartei-Gedächtnis,
 * künftige Buchungen derselben Gegenpartei automatisch zuzuordnen.
 * Vorschläge (eigenes Konto per Name, Gedächtnis, Namensvariante) sind nur
 * vorausgewählt, nie automatisch übernommen.
 */
import type { Metadata } from 'next';
import { getFormatter, getTranslations } from 'next-intl/server';

import { Link } from '@/i18n/navigation';
import { toAppLocale } from '@/i18n/routing';
import { categorizeGroup } from '@/lib/actions/categorization-rules';
import { createClient, requireOnboardedUser } from '@/lib/supabase/server';

import { CategorySelect } from '../category-select';
import { loadTransactionFormOptions } from '../form-options';
import { QualityStats } from '../quality-stats';

type GroupsPageProps = {
  params: Promise<{ locale: string }>;
  searchParams: Promise<Record<string, string | string[] | undefined>>;
};

const RECURRENCES = ['weekly', 'monthly', 'quarterly', 'semiannual', 'yearly'] as const;
type Recurrence = (typeof RECURRENCES)[number];
const isRecurrence = (value: string | null): value is Recurrence =>
  value !== null && (RECURRENCES as readonly string[]).includes(value);

export async function generateMetadata({ params }: Pick<GroupsPageProps, 'params'>): Promise<Metadata> {
  const locale = toAppLocale((await params).locale);
  const t = await getTranslations({ locale, namespace: 'Groups' });
  return { title: t('metaTitle') };
}

export default async function GroupsPage({ searchParams }: GroupsPageProps) {
  const user = await requireOnboardedUser('/dashboard/transactions/groups');
  const query = await searchParams;
  const t = await getTranslations('Groups');
  const tRecurrence = await getTranslations('Recurrence');
  const format = await getFormatter();

  const supabase = await createClient();
  const [groups, options] = await Promise.all([
    supabase.rpc('uncategorized_groups', { p_limit: 200 }),
    loadTransactionFormOptions(user.id),
  ]);
  if (groups.error) {
    console.error('[groups] Laden fehlgeschlagen', { code: groups.error.code });
  }
  const rows = groups.data ?? [];
  const categories = options?.categories ?? [];
  const categoryLabel = (id: string | null) => categories.find((c) => c.id === id)?.label ?? null;

  const assigned = typeof query.assigned === 'string' && /^\d{1,6}$/.test(query.assigned) ? Number(query.assigned) : null;
  const failed = query.error === '1' ? 'generic' : query.error === 'category' ? 'category' : null;
  const date = (value: string) =>
    format.dateTime(new Date(`${value}T00:00:00Z`), { dateStyle: 'medium', timeZone: 'UTC' });

  return (
    <section aria-labelledby="page-title" className="groups-page">
      <p className="back-link">
        <Link href="/dashboard/transactions">← {t('back')}</Link>
      </p>
      <h1 id="page-title">{t('heading')}</h1>
      <p>{t('intro')}</p>
      <QualityStats />

      {failed ? (
        <p role="alert" className="form-error">
          {t(`errors.${failed}`)}
        </p>
      ) : assigned !== null ? (
        <p role="status" className="form-success">
          {t('assigned', { count: assigned })}
        </p>
      ) : null}

      {groups.error ? (
        <p role="alert" className="form-error">
          {t('loadError')}
        </p>
      ) : rows.length === 0 ? (
        <p className="empty-state">{t('empty')}</p>
      ) : (
        <>
          <p className="result-count">{t('summary', { groups: rows.length, count: rows.reduce((n, g) => n + g.tx_count, 0) })}</p>
          <ol className="group-list">
            {rows.map((group, index) => {
              const id = `group-${index}`;
              const suggestion = categoryLabel(group.suggestion_category_id);
              return (
                // Schlüssel mit Vorschlag: sonst behielte die Auswahl nach dem
                // Neuladen ihre alte Vorbelegung (defaultValue).
                <li
                  key={`${group.group_key}|${group.suggestion_category_id ?? ''}`}
                  className="group-item"
                  aria-labelledby={`${id}-label`}
                >
                  <div className="group-text">
                    <h2 id={`${id}-label`} className="group-label">
                      {group.label ?? t('unknown')}
                    </h2>
                    <p className="group-meta">
                      {t('count', { count: group.tx_count })} ·{' '}
                      <span className={group.total < 0 ? 'amount-negative' : 'amount-positive'}>
                        {format.number(group.total, { style: 'currency', currency: group.currency })}
                      </span>{' '}
                      · {group.first_date === group.last_date ? date(group.first_date) : `${date(group.first_date)} – ${date(group.last_date)}`}
                      {isRecurrence(group.recurrence) ? (
                        <>
                          {' '}
                          <span className="badge badge-recurring">{tRecurrence(group.recurrence)}</span>
                        </>
                      ) : null}
                      {group.group_key.startsWith('i:') ? (
                        <>
                          {' '}
                          <span className="badge badge-muted">{t('byIban')}</span>
                        </>
                      ) : null}
                    </p>
                    {group.samples && group.samples.length > 0 ? (
                      <p className="cell-note">{group.samples.join(' · ')}</p>
                    ) : null}
                    {suggestion && group.suggestion_source ? (
                      <p className="group-suggestion">
                        {t(`suggestion.${group.suggestion_source}`, {
                          category: suggestion,
                          detail: group.suggestion_detail ?? '',
                        })}
                      </p>
                    ) : null}
                  </div>
                  <form action={categorizeGroup.bind(null, group.group_key)} className="group-form">
                    <label htmlFor={`${id}-category`} className="sr-only">
                      {t('categoryFor', { label: group.label ?? '' })}
                    </label>
                    <CategorySelect
                      id={`${id}-category`}
                      name="category"
                      categories={categories}
                      defaultValue={group.suggestion_category_id ?? ''}
                      emptyLabel={t('choose')}
                      required
                    />
                    <button type="submit" className="button button-small">
                      {t('assign', { count: group.tx_count })}
                    </button>
                  </form>
                </li>
              );
            })}
          </ol>
        </>
      )}
    </section>
  );
}
