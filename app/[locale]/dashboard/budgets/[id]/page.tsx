/**
 * app/[locale]/dashboard/budgets/[id]/page.tsx
 *
 * Einzelbudget bearbeiten oder löschen. Nur eigene Kategoriebudgets
 * (user_id = eigener Nutzer); für Berater und fremde IDs ist die Seite ein
 * 404. Die RPC und RLS prüfen Eigentum zusätzlich selbst.
 */
import type { Metadata } from 'next';
import { notFound } from 'next/navigation';
import { getLocale, getTranslations } from 'next-intl/server';
import { Suspense } from 'react';

import { Link } from '@/i18n/navigation';
import { toAppLocale } from '@/i18n/routing';
import { deleteCategoryBudget, saveCategoryBudget } from '@/lib/actions/category-budgets';
import type { CategoryBudgetFormValues } from '@/lib/category-budgets';
import { createClient, requireOnboardedUser } from '@/lib/supabase/server';
import { formatAmountInput, isUuid } from '@/lib/transactions';

import { ActionForm } from '../../action-form';
import { BudgetSkeleton } from '../budget-skeleton';
import { CategoryBudgetForm } from '../category-budget-form';
import { loadCategoryBudgetFormData } from '../form-data';

type BudgetPageProps = {
  params: Promise<{ locale: string; id: string }>;
  searchParams: Promise<Record<string, string | string[] | undefined>>;
};

export async function generateMetadata({ params }: Pick<BudgetPageProps, 'params'>): Promise<Metadata> {
  const locale = toAppLocale((await params).locale);
  const t = await getTranslations({ locale, namespace: 'CategoryBudgets.form' });
  return { title: t('editTitle') };
}

export default async function BudgetPage({ params, searchParams }: BudgetPageProps) {
  const { id } = await params;
  if (!isUuid(id)) {
    notFound();
  }
  const user = await requireOnboardedUser(`/dashboard/budgets/${id}`);
  const query = await searchParams;
  const t = await getTranslations('CategoryBudgets');
  const locale = toAppLocale(await getLocale());

  const supabase = await createClient();
  const { data: budget, error } = await supabase
    .from('budgets')
    .select('id, category_id, period, amount, currency, alert_threshold_pct')
    .eq('id', id)
    .eq('user_id', user.id)
    .not('category_id', 'is', null)
    .maybeSingle();
  if (error) {
    console.error('[budgets] Einzelbudget nicht ladbar', { code: error.code });
  } else if (!budget) {
    notFound();
  }

  const header = (
    <>
      <p className="back-link">
        <Link href="/dashboard/budgets">← {t('form.back')}</Link>
      </p>
      <h1 id="page-title">{t('form.editTitle')}</h1>
    </>
  );
  if (!budget) {
    return (
      <section aria-labelledby="page-title" className="budgets-page">
        {header}
        <p role="alert" className="form-error">
          {t('form.loadError')}
        </p>
      </section>
    );
  }

  const initialValues: CategoryBudgetFormValues = {
    categoryId: budget.category_id ?? '',
    period: budget.period,
    amount: formatAmountInput(Number(budget.amount), locale),
    currency: budget.currency,
    threshold: String(budget.alert_threshold_pct),
  };

  return (
    <section aria-labelledby="page-title" className="budgets-page">
      {header}
      {typeof query.error === 'string' ? (
        <p role="alert" className="form-error">
          {t('form.errors.generic')}
        </p>
      ) : null}
      <p className="hint">{t('variableHint')}</p>
      <Suspense key={crypto.randomUUID()} fallback={<BudgetSkeleton />}>
        <EditBudgetForm userId={user.id} budgetId={budget.id} initialValues={initialValues} />
      </Suspense>

      <details className="budget-danger">
        <summary>{t('form.delete')}</summary>
        <p>{t('form.deleteConfirm')}</p>
        <ActionForm action={deleteCategoryBudget.bind(null, budget.id)}>
          <button type="submit" className="button button-danger button-small">
            {t('form.deleteButton')}
          </button>
        </ActionForm>
      </details>
    </section>
  );
}

async function EditBudgetForm({
  userId,
  budgetId,
  initialValues,
}: {
  userId: string;
  budgetId: string;
  initialValues: CategoryBudgetFormValues;
}) {
  const t = await getTranslations('CategoryBudgets');
  const data = await loadCategoryBudgetFormData(userId, budgetId);
  if (!data) {
    return (
      <p role="alert" className="form-error">
        {t('form.loadError')}
      </p>
    );
  }
  return (
    <CategoryBudgetForm
      mode="edit"
      action={saveCategoryBudget.bind(null, budgetId)}
      categories={data.categories}
      suggestions={data.suggestions}
      windows={data.windows}
      initialValues={initialValues}
    />
  );
}
