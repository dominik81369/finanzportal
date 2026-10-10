/**
 * app/[locale]/dashboard/nav-items.ts
 *
 * Einzige Quelle für die Bereiche des Mandanten-Dashboards. Navigation und
 * Tests lesen diese Liste; neue Bereiche nur hier ergänzen (Beschriftung in
 * messages/*.json unter Dashboard.nav.<labelKey>).
 *
 * href ist der Pfad OHNE Sprachpräfix – Link und usePathname aus
 * i18n/navigation.ts ergänzen bzw. entfernen ihn.
 */

/** Unterpunkt eines Bereichs (Seitenleiste eingerückt, mobil als Reiter auf der Seite). */
export type DashboardNavSubItem = {
  href: string;
  labelKey: 'spending' | 'rule';
};

export type DashboardNavItem = {
  href: string;
  labelKey: 'overview' | 'transactions' | 'budgets' | 'contracts' | 'netWorth' | 'advisors';
  /** Nur bei exakt diesem Pfad aktiv (sonst auch für Unterseiten). */
  exact?: boolean;
  /** Pfad des Bereichs, wenn href auf eine seiner Unterseiten zeigt. */
  section?: string;
  children?: readonly DashboardNavSubItem[];
};

/** Unterpunkte von „Budget“; „Budget“ öffnet den ersten. */
export const BUDGET_NAV_ITEMS: readonly DashboardNavSubItem[] = [
  { href: '/dashboard/budgets/spending', labelKey: 'spending' },
  { href: '/dashboard/budgets/50-30-20', labelKey: 'rule' },
];

export const DASHBOARD_NAV_ITEMS: readonly DashboardNavItem[] = [
  { href: '/dashboard', labelKey: 'overview', exact: true },
  { href: '/dashboard/transactions', labelKey: 'transactions' },
  { href: '/dashboard/budgets/spending', section: '/dashboard/budgets', labelKey: 'budgets', children: BUDGET_NAV_ITEMS },
  { href: '/dashboard/contracts', labelKey: 'contracts' },
  { href: '/dashboard/net-worth', labelKey: 'netWorth' },
  { href: '/dashboard/advisors', labelKey: 'advisors' },
];

/** pathname ohne Sprachpräfix (usePathname aus i18n/navigation.ts). */
export function isNavItemActive(item: Pick<DashboardNavItem, 'href' | 'exact' | 'section'>, pathname: string): boolean {
  const base = item.section ?? item.href;
  if (item.exact) {
    return pathname === base;
  }
  return pathname === base || pathname.startsWith(`${base}/`);
}
