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
    const active = nav?.querySelector<HTMLElement>('[aria-current="page"]');
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
          return (
            <li key={item.href}>
              <Link href={item.href} aria-current={active ? 'page' : undefined}>
                {t(`nav.${item.labelKey}`)}
              </Link>
            </li>
          );
        })}
      </ul>
    </nav>
  );
}
