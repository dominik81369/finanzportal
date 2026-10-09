/**
 * app/[locale]/dashboard/budgets/new/page.tsx
 *
 * Einzelbudget anlegen: Höchstbetrag je Kategorie für Monat oder Jahr mit
 * Warnschwelle. Auswahllisten und Vorschläge werden gestreamt.
 */
import type { Metadata } from 'next';
import { getTranslations } from 'next-intl/server';
import { Suspense } from 'react';

import { Link } from '@/i18n/navigation';
import { toAppLocale } from '@/i18n/routing';
import { saveCategoryBudget } from '@/lib/actions/category-budgets';
import { requireOnboardedUser } from '@/lib/supabase/server';

import { BudgetSkeleton } from '../budget-skeleton';
import { CategoryBudgetForm } from '../category-budget-form';
import { loadCategoryBudgetFormData } from '../form-data';

type NewBudgetPageProps = { params: Promise<{ locale: string }> };

export async function generateMetadata({ params }: NewBudgetPageProps): Promise<Metadata> {
  const locale = toAppLocale((await params).locale);
  const t = await getTranslations({ locale, namespace: 'CategoryBudgets.form' });
  return { title: t('newTitle') };
}

export default async function NewBudgetPage() {
  const user = await requireOnboardedUser('/dashboard/budgets/new');
  const t = await getTranslations('CategoryBudgets');

  return (
    <section aria-labelledby="page-title" className="budgets-page">
      <p className="back-link">
        <Link href="/dashboard/budgets">← {t('form.back')}</Link>
      </p>
      <h1 id="page-title">{t('form.newTitle')}</h1>
      <p className="budgets-intro">{t('form.intro')}</p>
      <p className="hint">{t('variableHint')}</p>
      <Suspense key={crypto.randomUUID()} fallback={<BudgetSkeleton />}>
        <NewBudgetForm userId={user.id} />
      </Suspense>
    </section>
  );
}

/** Formular mit Auswahllisten und Vorschlägen (gestreamt). */
async function NewBudgetForm({ userId }: { userId: string }) {
  const t = await getTranslations('CategoryBudgets');
  const data = await loadCategoryBudgetFormData(userId, null);
  if (!data) {
    return (
      <p role="alert" className="form-error">
        {t('form.loadError')}
      </p>
    );
  }
  return (
    <CategoryBudgetForm
      mode="create"
      action={saveCategoryBudget.bind(null, null)}
      categories={data.categories}
      suggestions={data.suggestions}
      windows={data.windows}
    />
  );
}
