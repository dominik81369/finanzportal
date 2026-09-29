'use server';

/**
 * lib/actions/advisor-links.ts
 *
 * Server Actions: Verbindungen zwischen Berater und Mandant beenden.
 *
 * - revokeClientLink(): Berater beendet den Zugriff auf einen Mandanten
 *   bzw. zieht eine offene Einladung zurück.
 * - revokeMyAdvisor(): Mandant widerruft den Zugriff eines Beraters.
 *
 * Technisch beides ein UPDATE status = 'revoked' über den normalen
 * Server-Client (RLS aktiv). Die Datenbank sichert ab
 * (supabase/migrations/00000000000000_initial_schema.sql):
 * - nur Beteiligte dürfen die Zeile ändern (advisor_clients_update_participant),
 * - als Statuswechsel ist nur → 'revoked' erlaubt (advisor_clients_guard),
 *   der Trigger setzt revoked_at und löscht Token-Hash und Ablaufdatum,
 * - private.advisor_client_ids() liefert nur aktive Verbindungen – der
 *   Lesezugriff des Beraters endet also mit dem Widerruf.
 *
 * Die Link-ID wird per .bind() übergeben und ist wie alle Client-Daten nicht
 * vertrauenswürdig; die Abfragen filtern zusätzlich auf die eigene Rolle in
 * der Verbindung (advisor_id bzw. user_id = eigener Nutzer).
 */
import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import { getTranslations } from 'next-intl/server';

import { localizedPath } from '@/i18n/paths';
import { createClient, requireAdvisor, requireOnboardedUser } from '@/lib/supabase/server';
import { isUuid } from '@/lib/transactions';

export type RevokeState = { status: 'idle' | 'error'; message?: string };

/** Welche Art Verbindung der Berater beendet (steuert die Bestätigung). */
export type AdvisorRevokeKind = 'client' | 'invitation';

export async function revokeClientLink(
  linkId: string,
  kind: AdvisorRevokeKind,
  _prevState: RevokeState,
  _formData: FormData,
): Promise<RevokeState> {
  const advisor = await requireAdvisor();
  const t = await getTranslations('AdvisorLinks.errors');

  if (!isUuid(linkId)) {
    return { status: 'error', message: t('notFound') };
  }

  const supabase = await createClient();
  const { data, error } = await supabase
    .from('advisor_clients')
    .update({ status: 'revoked' })
    .eq('id', linkId)
    .eq('advisor_id', advisor.id)
    .eq('status', kind === 'client' ? 'active' : 'invited')
    .select('id');

  if (error) {
    console.error('[advisor-links] Widerruf durch Berater fehlgeschlagen', { code: error.code });
    return { status: 'error', message: t('generic') };
  }
  if (data.length === 0) {
    return { status: 'error', message: t('notFound') };
  }

  revalidatePath('/[locale]/advisor', 'page');
  redirect(`${await localizedPath('/advisor')}?ended=${kind}`);
}

export async function revokeMyAdvisor(
  linkId: string,
  _prevState: RevokeState,
  _formData: FormData,
): Promise<RevokeState> {
  const user = await requireOnboardedUser('/dashboard/advisors');
  const t = await getTranslations('AdvisorLinks.errors');

  if (!isUuid(linkId)) {
    return { status: 'error', message: t('notFound') };
  }

  const supabase = await createClient();
  const { data, error } = await supabase
    .from('advisor_clients')
    .update({ status: 'revoked' })
    .eq('id', linkId)
    .eq('user_id', user.id)
    .eq('status', 'active')
    .select('id');

  if (error) {
    console.error('[advisor-links] Widerruf durch Mandant fehlgeschlagen', { code: error.code });
    return { status: 'error', message: t('generic') };
  }
  if (data.length === 0) {
    return { status: 'error', message: t('notFound') };
  }

  revalidatePath('/[locale]/dashboard/advisors', 'page');
  redirect(`${await localizedPath('/dashboard/advisors')}?revoked=1`);
}
