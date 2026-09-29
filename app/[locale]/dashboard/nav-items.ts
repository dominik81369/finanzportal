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

export type DashboardNavItem = {
  href: string;
  labelKey: 'overview' | 'transactions' | 'budgets' | 'contracts' | 'netWorth' | 'advisors';
  /** Nur bei exakt diesem Pfad aktiv (sonst auch für Unterseiten). */
  exact?: boolean;
};

export const DASHBOARD_NAV_ITEMS: readonly DashboardNavItem[] = [
  { href: '/dashboard', labelKey: 'overview', exact: true },
  { href: '/dashboard/transactions', labelKey: 'transactions' },
  { href: '/dashboard/budgets', labelKey: 'budgets' },
  { href: '/dashboard/contracts', labelKey: 'contracts' },
  { href: '/dashboard/net-worth', labelKey: 'netWorth' },
  { href: '/dashboard/advisors', labelKey: 'advisors' },
];

/** pathname ohne Sprachpräfix (usePathname aus i18n/navigation.ts). */
export function isNavItemActive(item: DashboardNavItem, pathname: string): boolean {
  if (item.exact) {
    return pathname === item.href;
  }
  return pathname === item.href || pathname.startsWith(`${item.href}/`);
}
