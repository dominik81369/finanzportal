/**
 * Reiter „Ausgaben“ und „50/30/20“ im Kopf der Budgetseiten. In der
 * Seitenleiste stehen dieselben Unterpunkte eingerückt; mobil sind sie dort
 * ausgeblendet und nur hier sichtbar.
 */
import { getTranslations } from 'next-intl/server';

import { Link } from '@/i18n/navigation';

import { BUDGET_NAV_ITEMS, type DashboardNavSubItem } from '../nav-items';

export async function BudgetTabs({ active }: { active: DashboardNavSubItem['labelKey'] }) {
  const t = await getTranslations('Dashboard');
  return (
    <nav aria-label={t('budgets.tabsLabel')} className="budget-tabs">
      <ul>
        {BUDGET_NAV_ITEMS.map((item) => (
          <li key={item.href}>
            <Link href={item.href} aria-current={item.labelKey === active ? 'page' : undefined}>
              {t(`nav.${item.labelKey}`)}
            </Link>
          </li>
        ))}
      </ul>
    </nav>
  );
}
