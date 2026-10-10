'use client';

import { useTranslations } from 'next-intl';
import { useEffect, useRef } from 'react';

import { Link, usePathname } from '@/i18n/navigation';

import { DASHBOARD_NAV_ITEMS, isNavItemActive } from './nav-items';

export function DashboardNav() {
  const t = useTranslations('Dashboard');
  const pathname = usePathname();
  const navRef = useRef<HTMLElement>(null);

  // Auf schmalen Bildschirmen scrollt die Navigation horizontal: den aktiven
  // Bereich sichtbar halten, sonst ist er am rechten Rand abgeschnitten.
  useEffect(() => {
    const nav = navRef.current;
    // Mobil sind Unterpunkte ausgeblendet: dann zählt der Bereich (aria-current="true").
    const active =
      nav?.querySelector<HTMLElement>(':scope > ul > li > a[aria-current="true"]') ??
      nav?.querySelector<HTMLElement>('[aria-current="page"]');
    if (!nav || !active || nav.scrollWidth <= nav.clientWidth) {
      return;
    }
    const target = active.offsetLeft - (nav.clientWidth - active.offsetWidth) / 2;
    nav.scrollTo({ left: Math.max(0, target) });
  }, [pathname]);

  return (
    <nav ref={navRef} aria-label={t('navLabel')} className="dashboard-nav">
      <ul>
        {DASHBOARD_NAV_ITEMS.map((item) => {
          const active = isNavItemActive(item, pathname);
          const activeChild = item.children?.find((child) => isNavItemActive(child, pathname));
          return (
            <li key={item.href}>
              {/* Mit aktivem Unterpunkt ist der Bereich „aktuell“ (true), die Seite der Unterpunkt. */}
              <Link href={item.href} aria-current={activeChild ? 'true' : active ? 'page' : undefined}>
                {t(`nav.${item.labelKey}`)}
              </Link>
              {item.children ? (
                <ul className="dashboard-subnav">
                  {item.children.map((child) => (
                    <li key={child.href}>
                      <Link href={child.href} aria-current={child === activeChild ? 'page' : undefined}>
                        {t(`nav.${child.labelKey}`)}
                      </Link>
                    </li>
                  ))}
                </ul>
              ) : null}
            </li>
          );
        })}
      </ul>
    </nav>
  );
}
