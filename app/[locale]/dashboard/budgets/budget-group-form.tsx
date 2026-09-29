'use client';

/**
 * Zuordnung der Ausgaben- und Transferkategorien zu Needs / Wants / Savings
 * (oder „nicht gezählt“). Ein Formular, ein Speichern-Knopf; gespeichert
 * wird in einem Schritt (lib/actions/budget-groups.ts).
 */
import { useTranslations } from 'next-intl';
import { startTransition, useActionState, type FormEvent } from 'react';

import { saveBudgetGroups, type BudgetGroupsState } from '@/lib/actions/budget-groups';
import { BUDGET_GROUPS, EXCLUDED, type BudgetGroupKey } from '@/lib/budget-rule';

export type BudgetGroupFormCategory = {
  id: string;
  label: string;
  /** Unterkategorie (eingerückt). */
  isChild: boolean;
  group: BudgetGroupKey | null;
};

const initialState: BudgetGroupsState = { status: 'idle' };

export function BudgetGroupForm({ categories }: { categories: BudgetGroupFormCategory[] }) {
  const t = useTranslations('Budgets');
  const [state, formAction, isPending] = useActionState(saveBudgetGroups, initialState);

  // Selbst absenden: React würde das Formular sonst nach der Action
  // zurücksetzen und die gewählten Werte verwerfen.
  const handleSubmit = (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    const formData = new FormData(event.currentTarget);
    startTransition(() => formAction(formData));
  };

  return (
    <form action={formAction} onSubmit={handleSubmit} className="form budget-group-form">
      {state.status === 'error' && state.message ? (
        <p role="alert" className="form-error">
          {state.message}
        </p>
      ) : null}
      {state.status === 'success' && state.message ? (
        <p role="status" className="form-success">
          {state.message}
        </p>
      ) : null}

      <ul className="link-list">
        {categories.map((category) => {
          const fieldId = `budget-group-${category.id}`;
          return (
            <li key={category.id} className={`link-item${category.isChild ? ' link-item-child' : ''}`}>
              <label htmlFor={fieldId}>{category.label}</label>
              <select id={fieldId} name={`group:${category.id}`} defaultValue={category.group ?? EXCLUDED}>
                {BUDGET_GROUPS.map((group) => (
                  <option key={group} value={group}>
                    {t(`groups.${group}`)}
                  </option>
                ))}
                <option value={EXCLUDED}>{t('assignment.excluded')}</option>
              </select>
            </li>
          );
        })}
      </ul>

      <button type="submit" disabled={isPending}>
        {isPending ? t('assignment.saving') : t('assignment.save')}
      </button>
    </form>
  );
}
