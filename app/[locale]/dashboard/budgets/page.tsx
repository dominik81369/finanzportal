/**
 * app/[locale]/dashboard/budgets/page.tsx
 *
 * „Budget“ öffnet die Ausgaben; die 50/30/20-Ansicht liegt unter
 * ./50-30-20. Alte Links mit Zeitraum (?from=&to=) führen dorthin.
 */
import { getLocale } from 'next-intl/server';

import { redirect } from '@/i18n/navigation';

type BudgetsPageProps = {
  searchParams: Promise<Record<string, string | string[] | undefined>>;
};

export default async function BudgetsPage({ searchParams }: BudgetsPageProps) {
  const query = await searchParams;
  const locale = await getLocale();
  const from = typeof query.from === 'string' ? query.from : null;
  const to = typeof query.to === 'string' ? query.to : null;
  if (from || to) {
    const params = new URLSearchParams();
    if (from) params.set('from', from);
    if (to) params.set('to', to);
    redirect({ href: `/dashboard/budgets/50-30-20?${params.toString()}`, locale });
  }
  redirect({ href: '/dashboard/budgets/spending', locale });
}
