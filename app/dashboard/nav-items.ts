/**
 * app/dashboard/nav-items.ts
 *
 * Einzige Quelle für die Bereiche des Mandanten-Dashboards. Navigation und
 * Tests lesen diese Liste; neue Bereiche nur hier ergänzen.
 */

export type DashboardNavItem = {
  href: string;
  label: string;
  /** Nur bei exakt diesem Pfad aktiv (sonst auch für Unterseiten). */
  exact?: boolean;
};

export const DASHBOARD_NAV_ITEMS: readonly DashboardNavItem[] = [
  { href: '/dashboard', label: 'Übersicht', exact: true },
  { href: '/dashboard/transactions', label: 'Transaktionen' },
  { href: '/dashboard/budgets', label: 'Budgets' },
  { href: '/dashboard/contracts', label: 'Verträge' },
  { href: '/dashboard/net-worth', label: 'Net Worth' },
];

export function isNavItemActive(item: DashboardNavItem, pathname: string): boolean {
  if (item.exact) {
    return pathname === item.href;
  }
  return pathname === item.href || pathname.startsWith(`${item.href}/`);
}
