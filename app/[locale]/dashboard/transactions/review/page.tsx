/**
 * app/[locale]/dashboard/transactions/review/page.tsx
 *
 * Prüfliste: Vorschläge des Lernverfahrens (public.refresh_suggestions)
 * für Buchungen ohne Kategorie, die unsichersten zuerst. Hohe Beträge (ab
 * der Prüfgrenze) landen immer hier, auch bei sicherem Treffer. Übernehmen
 * oder Ändern zählt als manuelle Zuordnung und trainiert das Modell.
 */
import type { Metadata } from 'next';
import { getFormatter, getTranslations } from 'next-intl/server';

import { Link } from '@/i18n/navigation';
import { toAppLocale } from '@/i18n/routing';
import { confirmAllSuggestions, reviewAssign } from '@/lib/actions/categorization-rules';
import { categoryDisplayName } from '@/lib/categories';
import { createClient, requireOnboardedUser } from '@/lib/supabase/server';

import { CategorySelect } from '../category-select';
import { loadTransactionFormOptions } from '../form-options';
import { QualityStats } from '../quality-stats';

type ReviewPageProps = {
  params: Promise<{ locale: string }>;
  searchParams: Promise<Record<string, string | string[] | undefined>>;
};

const LIMIT = 200;

export async function generateMetadata({ params }: Pick<ReviewPageProps, 'params'>): Promise<Metadata> {
  const locale = toAppLocale((await params).locale);
  const t = await getTranslations({ locale, namespace: 'Review' });
  return { title: t('metaTitle') };
}

export default async function ReviewPage({ searchParams }: ReviewPageProps) {
  const user = await requireOnboardedUser('/dashboard/transactions/review');
  const query = await searchParams;
  const t = await getTranslations('Review');
  const tCategories = await getTranslations('DefaultCategories');
  const format = await getFormatter();

  const supabase = await createClient();
  // Vorschläge mit dem aktuellen Stand der Zuordnungen neu berechnen
  // (ordnet nichts zu).
  const refreshed = await supabase.rpc('refresh_suggestions');
  if (refreshed.error) {
    console.error('[review] Vorschläge berechnen fehlgeschlagen', { code: refreshed.error.code });
  }

  const [list, options, settings, open] = await Promise.all([
    supabase
      .from('transactions')
      .select(
        `id, booking_date, amount, currency, counterparty_name, purpose, suggestion_confidence,
         suggested:categories!transactions_suggested_category_fkey ( id, name, default_key )`,
      )
      .eq('user_id', user.id)
      .is('category_id', null)
      .not('suggested_category_id', 'is', null)
      .order('suggestion_confidence', { ascending: true })
      .order('booking_date', { ascending: false })
      .limit(LIMIT),
    loadTransactionFormOptions(user.id),
    supabase.from('categorization_settings').select('bayes_threshold, review_amount_limit').eq('user_id', user.id).maybeSingle(),
    supabase.from('transactions').select('id', { count: 'exact', head: true }).eq('user_id', user.id).is('category_id', null),
  ]);
  if (list.error) {
    console.error('[review] Laden fehlgeschlagen', { code: list.error.code });
  }
  const rows = list.data ?? [];
  const categories = options?.categories ?? [];
  const limit = Number(settings.data?.review_amount_limit ?? 1000);
  const withoutSuggestion = Math.max(0, (open.count ?? 0) - rows.length);

  const confirmed = typeof query.confirmed === 'string' && /^\d{1,6}$/.test(query.confirmed) ? Number(query.confirmed) : null;
  const done = query.done === '1';
  const failed = query.error === '1' ? 'generic' : query.error === 'category' ? 'category' : null;
  const percent = (value: number | null) =>
    value === null ? '–' : format.number(value, { style: 'percent', maximumFractionDigits: 0 });

  return (
    <section aria-labelledby="page-title" className="review-page">
      <p className="back-link">
        <Link href="/dashboard/transactions">← {t('back')}</Link>
      </p>
      <h1 id="page-title">{t('heading')}</h1>
      <p>{t('intro', { limit: format.number(limit, { style: 'currency', currency: 'EUR', maximumFractionDigits: 0 }) })}</p>
      <QualityStats />

      {failed ? (
        <p role="alert" className="form-error">
          {t(`errors.${failed}`)}
        </p>
      ) : confirmed !== null ? (
        <p role="status" className="form-success">
          {t('confirmed', { count: confirmed })}
        </p>
      ) : done ? (
        <p role="status" className="form-success">
          {t('done')}
        </p>
      ) : null}

      {list.error ? (
        <p role="alert" className="form-error">
          {t('loadError')}
        </p>
      ) : rows.length === 0 ? (
        <p className="empty-state">{t('empty')}</p>
      ) : (
        <>
          <div className="review-toolbar">
            <p className="result-count">{t('count', { count: rows.length })}</p>
            <form action={confirmAllSuggestions}>
              {rows.map((row) => (
                <input key={row.id} type="hidden" name="id" value={row.id} />
              ))}
              <button type="submit" className="button button-secondary button-small">
                {t('confirmAll', { count: rows.length })}
              </button>
            </form>
          </div>
          <ol className="group-list review-list">
            {rows.map((row, index) => {
              const id = `review-${index}`;
              const highAmount = Math.abs(row.amount) >= limit;
              const date = format.dateTime(new Date(`${row.booking_date}T00:00:00Z`), {
                dateStyle: 'medium',
                timeZone: 'UTC',
              });
              return (
                // Schlüssel mit Vorschlag: neue Vorbelegung nach dem Neuladen.
                <li key={`${row.id}|${row.suggested?.id ?? ''}`} className="group-item" aria-labelledby={`${id}-label`}>
                  <div className="group-text">
                    <h2 id={`${id}-label`} className="group-label">
                      {row.counterparty_name ?? row.purpose ?? t('unknown')}
                    </h2>
                    <p className="group-meta">
                      {date} ·{' '}
                      <span className={row.amount < 0 ? 'amount-negative' : 'amount-positive'}>
                        {format.number(row.amount, { style: 'currency', currency: row.currency })}
                      </span>
                      {highAmount ? (
                        <>
                          {' '}
                          <span className="badge badge-warning">{t('highAmount')}</span>
                        </>
                      ) : null}
                    </p>
                    {row.purpose && row.counterparty_name ? <p className="cell-note">{row.purpose}</p> : null}
                    {row.suggested ? (
                      <p className="group-suggestion">
                        {t('suggestion', {
                          category: categoryDisplayName(row.suggested, tCategories),
                          confidence: percent(row.suggestion_confidence),
                        })}
                      </p>
                    ) : null}
                  </div>
                  <form action={reviewAssign.bind(null, row.id)} className="group-form">
                    <label htmlFor={`${id}-category`} className="sr-only">
                      {t('categoryFor', { label: row.counterparty_name ?? row.purpose ?? '' })}
                    </label>
                    <CategorySelect
                      id={`${id}-category`}
                      name="category"
                      categories={categories}
                      defaultValue={row.suggested?.id ?? ''}
                      emptyLabel={t('choose')}
                      required
                    />
                    <button type="submit" className="button button-small">
                      {t('assign')}
                    </button>
                  </form>
                </li>
              );
            })}
          </ol>
        </>
      )}

      {withoutSuggestion > 0 ? (
        <p className="hint">
          {t('withoutSuggestion', { count: withoutSuggestion })}{' '}
          <Link href="/dashboard/transactions/groups">{t('toGroups')}</Link>
        </p>
      ) : null}
    </section>
  );
}
