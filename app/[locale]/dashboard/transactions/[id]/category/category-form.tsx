'use client';

import { useTranslations } from 'next-intl';
import { startTransition, useActionState, type FormEvent } from 'react';

import { setTransactionCategory, type CategoryFormState } from '@/lib/actions/categorization-rules';

import { CategorySelect } from '../../category-select';
import type { CategoryOption } from '../../transaction-form';

const initialState: CategoryFormState = { status: 'idle' };

type CategoryFormProps = {
  transactionId: string;
  categories: CategoryOption[];
  current: string | null;
};

export function CategoryForm({ transactionId, categories, current }: CategoryFormProps) {
  const t = useTranslations('TransactionCategory');
  const [state, formAction, isPending] = useActionState(
    setTransactionCategory.bind(null, transactionId),
    initialState,
  );

  const handleSubmit = (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    const formData = new FormData(event.currentTarget);
    startTransition(() => formAction(formData));
  };

  return (
    <form action={formAction} onSubmit={handleSubmit} className="form">
      {state.status === 'error' && state.message ? (
        <p role="alert" className="form-error">
          {state.message}
        </p>
      ) : null}
      <label htmlFor="transaction-category">{t('category')}</label>
      <CategorySelect
        id="transaction-category"
        name="category"
        categories={categories}
        defaultValue={current ?? ''}
        emptyLabel={t('uncategorized')}
      />
      <button type="submit" disabled={isPending}>
        {isPending ? t('saving') : t('save')}
      </button>
    </form>
  );
}
