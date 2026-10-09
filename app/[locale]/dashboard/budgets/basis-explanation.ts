/**
 * Erklärtext zur Bezugsgröße („Zielbeträge = Prozentanteil …“) – für die
 * Budgetseite und die Leseansicht des Beraters. Bei „Einkommen“ mit dem
 * Hinweis auf Nettoeinkommen und Steuern in Needs.
 */
import 'server-only';

import { getFormatter, getTranslations } from 'next-intl/server';

import type { BudgetBasis, BudgetSettings } from '@/lib/budget-rule';

export async function basisExplanation(basis: BudgetBasis, months: number, settings: BudgetSettings): Promise<string> {
  const t = await getTranslations('Budgets.basis.explain');
  const tBudgets = await getTranslations('Budgets');
  const format = await getFormatter();
  const range = months > 1;
  switch (basis) {
    case 'expenses_avg3':
      return range ? t('expenses_avg3Range', { count: months }) : t('expenses_avg3');
    case 'fixed': {
      if (settings.fixedAmount === null) {
        return t('fixedMissing');
      }
      const amount = format.number(settings.fixedAmount, { style: 'currency', currency: settings.fixedCurrency });
      return range ? t('fixedRange', { amount, count: months }) : t('fixed', { amount });
    }
    case 'income':
      return `${range ? t('incomeRange') : t('income')} ${tBudgets('netIncomeHint')}`;
    default:
      return range ? t('expensesRange') : t('expenses');
  }
}
