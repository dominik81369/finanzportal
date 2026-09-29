/**
 * app/[locale]/page.tsx
 *
 * Startseite: leitet je nach Rolle weiter (Berater → /advisor, sonst
 * /dashboard). Ohne Session leitet middleware.ts vorher nach /login.
 */
import { redirectLocalized } from '@/i18n/paths';
import { getCurrentUserRole, requireUser } from '@/lib/supabase/server';

export default async function HomePage() {
  await requireUser();
  const role = await getCurrentUserRole();
  return redirectLocalized(role === 'advisor' ? '/advisor' : '/dashboard');
}
