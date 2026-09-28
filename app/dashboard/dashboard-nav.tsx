'use client';

import Link from 'next/link';
import { usePathname } from 'next/navigation';
import { useEffect, useRef } from 'react';

import { DASHBOARD_NAV_ITEMS, isNavItemActive } from './nav-items';

export function DashboardNav() {
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
    <nav ref={navRef} aria-label="Bereiche" className="dashboard-nav">
      <ul>
        {DASHBOARD_NAV_ITEMS.map((item) => {
          const active = isNavItemActive(item, pathname);
          return (
            <li key={item.href}>
              <Link href={item.href} aria-current={active ? 'page' : undefined}>
                {item.label}
              </Link>
            </li>
          );
        })}
      </ul>
    </nav>
  );
}
