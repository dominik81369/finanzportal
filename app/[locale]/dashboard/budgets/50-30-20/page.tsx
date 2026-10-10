/**
 * app/[locale]/dashboard/budgets/50-30-20/page.tsx
 *
 * Budget nach der 50/30/20-Regel: Ist je Gruppe (Bedarf / Wünsche / Sparen &
 * Schulden) gegen feste Zielbeträge = 50/30/20 % der Gesamtausgaben des
 * Zeitraums. Zeitraum ?from=YYYY-MM&to=YYYY-MM. Darunter die Zuordnung der
 * Kategorien zu den Gruppen.
 *
 * Kopf, Zeitraum und Zuordnung sofort; die Auswertung wird gestreamt
 * (../budget-overview.tsx, Ladezustand ../budget-skeleton.tsx). Die
 * Suspense-Grenze trägt je Render einen neuen Schlüssel: Nach dem Speichern
 * (revalidatePath) wird sie neu eingehängt, statt auf den gestreamten
 * Inhalt zu warten (Next.js 15, siehe app/[locale]/dashboard/action-form.tsx).
 *
 * Abfragen filtern ausdrücklich auf den eigenen Nutzer: RLS gibt Beratern
 * zusätzlich die Daten ihrer Mandanten frei.
 */
import type { Metadata } from 'next';
import { getFormatter, getTranslations } from 'next-intl/server';
import { Suspense } from 'react';

import { Link } from '@/i18n/navigation';
import { toAppLocale } from '@/i18n/routing';
import { addMonths, monthCount, parseMonthRange, type MonthKey, type MonthRange } from '@/lib/budget-rule';
import { categoryDisplayName, orderCategoryTree } from '@/lib/categories';
import { createClient, requireOnboardedUser } from '@/lib/supabase/server';
import { todayInGermany } from '@/lib/transactions';

import { BudgetGroupForm, type BudgetGroupFormCategory } from '../budget-group-form';
import { BudgetOverview } from '../budget-overview';
import { BudgetSkeleton } from '../budget-skeleton';
import { BudgetTabs } from '../budget-tabs';

const RULE_PATH = '/dashboard/budgets/50-30-20';

type RulePageProps = {
  params: Promise<{ locale: string }>;
  searchParams: Promise<Record<string, string | string[] | undefined>>;
};

export async function generateMetadata({ params }: Pick<RulePageProps, 'params'>): Promise<Metadata> {
  const locale = toAppLocale((await params).locale);
  const t = await getTranslations({ locale, namespace: 'Dashboard' });
  return { title: t('rule.title') };
}

const rangeHref = (range: MonthRange) => `${RULE_PATH}?from=${range.from}&to=${range.to}`;

export default async function RulePage({ searchParams }: RulePageProps) {
  const user = await requireOnboardedUser(RULE_PATH);
  const t = await getTranslations('Budgets');
  const tDashboard = await getTranslations('Dashboard');
  const tCategories = await getTranslations('DefaultCategories');
  const format = await getFormatter();
  const query = await searchParams;

  const currentMonth = todayInGermany().slice(0, 7);
  const range = parseMonthRange(query, currentMonth);
  const monthLabel = (month: MonthKey) =>
    format.dateTime(new Date(`${month}-01T00:00:00Z`), { month: 'long', year: 'numeric', timeZone: 'UTC' });

  const supabase = await createClient();
  const categories = await supabase
    .from('categories')
    .select('id, name, default_key, kind, parent_category_id, sort_order, budget_group')
    .eq('user_id', user.id)
    .neq('kind', 'income')
    .order('sort_order')
    .order('name');
  if (categories.error) {
    console.error('[budgets] Kategorien nicht ladbar', { code: categories.error.code });
  }

  // Oberkategorien in Sortierung, Unterkategorien jeweils direkt darunter.
  const formCategories: BudgetGroupFormCategory[] = orderCategoryTree(categories.data ?? []).map(
    ({ category, depth }) => ({
      id: category.id,
      label: categoryDisplayName(category, tCategories),
      isChild: depth > 0,
      group: category.budget_group,
    }),
  );

  const presets: { key: 'thisMonth' | 'lastMonth' | 'last3Months' | 'thisYear'; range: MonthRange }[] = [
    { key: 'thisMonth', range: { from: currentMonth, to: currentMonth } },
    { key: 'lastMonth', range: { from: addMonths(currentMonth, -1), to: addMonths(currentMonth, -1) } },
    { key: 'last3Months', range: { from: addMonths(currentMonth, -2), to: currentMonth } },
    { key: 'thisYear', range: { from: `${currentMonth.slice(0, 4)}-01`, to: currentMonth } },
  ];

  return (
    <section aria-labelledby="page-title" className="budgets-page">
      <div className="page-header">
        <h1 id="page-title">{tDashboard('rule.title')}</h1>
        <BudgetTabs active="rule" />
      </div>
      <p className="budgets-intro">{tDashboard('rule.description')}</p>

      <form method="get" className="filters budget-period" aria-label={t('period.label')}>
        <div className="filter-field">
          <label htmlFor="budget-from">{t('period.from')}</label>
          <input id="budget-from" name="from" type="month" defaultValue={range.from} required />
        </div>
        <div className="filter-field">
          <label htmlFor="budget-to">{t('period.to')}</label>
          <input id="budget-to" name="to" type="month" defaultValue={range.to} required />
        </div>
        <div className="filter-actions">
          <button type="submit" className="button">
            {t('period.apply')}
          </button>
        </div>
        <ul className="budget-presets">
          {presets.map((preset) => {
            const active = preset.range.from === range.from && preset.range.to === range.to;
            return (
              <li key={preset.key}>
                <Link href={rangeHref(preset.range)} aria-current={active ? 'true' : undefined}>
                  {t(`period.presets.${preset.key}`)}
                </Link>
              </li>
            );
          })}
        </ul>
      </form>

      <p className="result-count" id="budget-range">
        {monthCount(range) === 1
          ? t('period.single', { month: monthLabel(range.from) })
          : t('period.range', { from: monthLabel(range.from), to: monthLabel(range.to), count: monthCount(range) })}
      </p>

      <Suspense key={crypto.randomUUID()} fallback={<BudgetSkeleton />}>
        <BudgetOverview userId={user.id} range={range} />
      </Suspense>

      <p className="hint budget-rules">{t('rules')}</p>

      <section className="budget-section" aria-labelledby="assignment-heading">
        <h2 id="assignment-heading">{t('assignment.heading')}</h2>
        <p>{t('assignment.intro')}</p>
        {categories.error ? (
          <p role="alert" className="form-error">
            {t('assignment.loadError')}
          </p>
        ) : (
          <BudgetGroupForm categories={formCategories} />
        )}
      </section>
    </section>
  );
}
