/**
 * app/[locale]/dashboard/budgets/page.tsx
 *
 * Budget nach der 50/30/20-Regel: Ist je Gruppe (Needs / Wants / Sparen &
 * Schulden) gegen Zielbeträge = Prozentziel × Bezugsgröße. Bezugsgröße
 * standardmäßig die Gesamtausgaben des Zeitraums; umschaltbar nur für diese
 * Ansicht (?basis=), Voreinstellung und Prozentziele in den Einstellungen
 * (public.budget_settings). Zeitraum ?from=YYYY-MM&to=YYYY-MM.
 *
 * Kopf, Zeitraum und Formulare sofort; die Auswertung wird gestreamt
 * (budget-overview.tsx, Ladezustand budget-skeleton.tsx). Die Suspense-
 * Grenze trägt je Render einen neuen Schlüssel: Nach dem Speichern
 * (revalidatePath) wird sie neu eingehängt, statt auf den gestreamten
 * Inhalt zu warten (Next.js 15, siehe app/[locale]/dashboard/action-form.tsx).
 *
 * Abfragen filtern ausdrücklich auf den eigenen Nutzer: RLS gibt Beratern
 * zusätzlich die Daten ihrer Mandanten frei.
 */
import type { Metadata } from 'next';
import { getFormatter, getMessages, getTranslations } from 'next-intl/server';
import { Suspense } from 'react';

import { Link } from '@/i18n/navigation';
import { toAppLocale } from '@/i18n/routing';
import {
  BUDGET_BASES,
  addMonths,
  monthCount,
  parseBasis,
  parseMonthRange,
  type BudgetBasis,
  type MonthKey,
  type MonthRange,
} from '@/lib/budget-rule';
import { toBudgetSettings } from '@/lib/budget-settings';
import { categoryDisplayName } from '@/lib/categories';
import { createClient, requireOnboardedUser } from '@/lib/supabase/server';
import { todayInGermany } from '@/lib/transactions';

import { basisExplanation } from './basis-explanation';
import { BudgetGroupForm, type BudgetGroupFormCategory } from './budget-group-form';
import { BudgetOverview } from './budget-overview';
import { BudgetSettingsForm } from './budget-settings-form';
import { BudgetSkeleton } from './budget-skeleton';

type BudgetsPageProps = {
  params: Promise<{ locale: string }>;
  searchParams: Promise<Record<string, string | string[] | undefined>>;
};

export async function generateMetadata({
  params,
}: Pick<BudgetsPageProps, 'params'>): Promise<Metadata> {
  const locale = toAppLocale((await params).locale);
  const t = await getTranslations({ locale, namespace: 'Dashboard' });
  return { title: t('budgets.title') };
}

/** Link auf einen Zeitraum; eine in der Ansicht gewählte Bezugsgröße bleibt. */
const rangeHref = (range: MonthRange, basis: BudgetBasis | null) =>
  `/dashboard/budgets?from=${range.from}&to=${range.to}${basis ? `&basis=${basis}` : ''}`;

export default async function BudgetsPage({ searchParams }: BudgetsPageProps) {
  const user = await requireOnboardedUser('/dashboard/budgets');
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
  const [settingsRow, categories] = await Promise.all([
    supabase
      .from('budget_settings')
      .select('basis, needs_pct, wants_pct, savings_pct, fixed_amount, fixed_currency')
      .eq('user_id', user.id)
      .maybeSingle(),
    supabase
      .from('categories')
      .select('id, name, default_key, kind, parent_category_id, sort_order, budget_group')
      .eq('user_id', user.id)
      .neq('kind', 'income')
      .order('sort_order')
      .order('name'),
  ]);
  if (settingsRow.error) {
    console.error('[budgets] Einstellungen nicht ladbar', { code: settingsRow.error.code });
  }
  if (categories.error) {
    console.error('[budgets] Kategorien nicht ladbar', { code: categories.error.code });
  }
  const settings = toBudgetSettings(settingsRow.data);
  const basis = parseBasis(query, settings.basis);
  const viewBasis = basis === settings.basis ? null : basis;

  // Oberkategorien in Sortierung, Unterkategorien jeweils direkt darunter.
  const formCategories: BudgetGroupFormCategory[] = [];
  const all = categories.data ?? [];
  const ids = new Set(all.map((c) => c.id));
  const toFormCategory = (c: (typeof all)[number], isChild: boolean) => ({
    id: c.id,
    label: categoryDisplayName(c, tCategories),
    isChild,
    group: c.budget_group,
  });
  for (const parent of all.filter((c) => !c.parent_category_id || !ids.has(c.parent_category_id))) {
    formCategories.push(toFormCategory(parent, false));
    for (const child of all.filter((c) => c.parent_category_id === parent.id)) {
      formCategories.push(toFormCategory(child, true));
    }
  }

  const presets: { key: 'thisMonth' | 'lastMonth' | 'last3Months' | 'thisYear'; range: MonthRange }[] = [
    { key: 'thisMonth', range: { from: currentMonth, to: currentMonth } },
    { key: 'lastMonth', range: { from: addMonths(currentMonth, -1), to: addMonths(currentMonth, -1) } },
    { key: 'last3Months', range: { from: addMonths(currentMonth, -2), to: currentMonth } },
    { key: 'thisYear', range: { from: `${currentMonth.slice(0, 4)}-01`, to: currentMonth } },
  ];
  const planned = Object.values((await getMessages()).Dashboard.budgets.planned);
  const explanation = await basisExplanation(basis, monthCount(range), settings);

  return (
    <section aria-labelledby="page-title" className="budgets-page">
      <h1 id="page-title">{tDashboard('budgets.title')}</h1>
      <p className="budgets-intro">{tDashboard('budgets.description')}</p>

      <form method="get" className="filters budget-period" aria-label={t('period.label')}>
        <div className="filter-field">
          <label htmlFor="budget-from">{t('period.from')}</label>
          <input id="budget-from" name="from" type="month" defaultValue={range.from} required />
        </div>
        <div className="filter-field">
          <label htmlFor="budget-to">{t('period.to')}</label>
          <input id="budget-to" name="to" type="month" defaultValue={range.to} required />
        </div>
        <div className="filter-field">
          <label htmlFor="budget-basis">{t('period.basis')}</label>
          <select id="budget-basis" name="basis" defaultValue={basis}>
            {BUDGET_BASES.map((option) => (
              <option key={option} value={option}>
                {t(`basis.options.${option}`)}
              </option>
            ))}
          </select>
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
                <Link href={rangeHref(preset.range, viewBasis)} aria-current={active ? 'true' : undefined}>
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
      <p className="budget-basis-note" id="budget-basis-note">
        {explanation}
        {viewBasis ? <span className="cell-note">{t('basis.viewOnly')}</span> : null}
      </p>

      <Suspense key={crypto.randomUUID()} fallback={<BudgetSkeleton />}>
        <BudgetOverview userId={user.id} range={range} basis={basis} settings={settings} />
      </Suspense>

      <p className="hint budget-rules">{t('rules')}</p>

      <section className="budget-section" id="budget-settings" aria-labelledby="settings-heading">
        <h2 id="settings-heading">{t('settings.heading')}</h2>
        <p>{t('settings.intro')}</p>
        {settingsRow.error ? (
          <p role="alert" className="form-error">
            {t('settings.loadError')}
          </p>
        ) : (
          <BudgetSettingsForm settings={settings} />
        )}
      </section>

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

      <div className="placeholder-box">
        <p className="placeholder-label">{tDashboard('placeholderLabel')}</p>
        <ul>
          {planned.map((item) => (
            <li key={item}>{item}</li>
          ))}
        </ul>
      </div>
    </section>
  );
}
