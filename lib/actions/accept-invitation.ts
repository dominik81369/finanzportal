'use server';

/**
 * lib/actions/accept-invitation.ts
 *
 * Nimmt eine Berater-Einladung über die RPC accept_advisor_invitation() an.
 *
 * Bewusst eine Server Action (POST mit Origin-Prüfung durch Next.js) und kein
 * Aufruf beim Rendern von /invite/[token]: Mit der Annahme erhält der Berater
 * Lesezugriff auf sämtliche Finanzdaten des Mandanten. Das muss eine
 * ausdrückliche Handlung sein – ein bloßer GET (Link-Vorschau, Mail-Scanner,
 * ein untergeschobener Link bei bestehender Session) darf es nicht auslösen.
 */
import type { PostgrestError } from '@supabase/supabase-js';
import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import { getTranslations } from 'next-intl/server';

import { localizedPath, localizedPathWithNext } from '@/i18n/paths';
import { invitePath, isWellFormedInviteToken } from '@/lib/invite-token';
import { createClient, currentUserHasPassword, getSessionUser } from '@/lib/supabase/server';
import { DEFAULT_REDIRECT_PATH } from '@/lib/url';

export type AcceptInvitationState = {
  status: 'idle' | 'error';
  message?: string;
};

async function acceptErrorMessage(error: PostgrestError): Promise<string> {
  const t = await getTranslations('Invite.errors');

  // Die RPC meldet fachliche Fehler über die Exception-Message.
  switch (error.message) {
    case 'invalid_or_expired_invitation':
      return t('invalidOrExpired');
    case 'email_not_confirmed':
      return t('emailNotConfirmed');
  }

  // advisor_clients_active_pair_key: bereits aktive Verbindung zu diesem Berater
  if (error.code === '23505') {
    return t('alreadyConnected');
  }

  console.error('[accept-invitation] RPC fehlgeschlagen', { code: error.code });
  return t('generic');
}

export async function acceptInvitation(
  _prevState: AcceptInvitationState,
  formData: FormData,
): Promise<AcceptInvitationState> {
  const token = formData.get('token');
  if (!isWellFormedInviteToken(token)) {
    const t = await getTranslations('Invite.errors');
    return { status: 'error', message: t('invalidOrExpired') };
  }

  const loginPath = await localizedPathWithNext('/login', await localizedPath(invitePath(token)));
  const user = await getSessionUser();
  if (!user) {
    redirect(loginPath);
  }

  const supabase = await createClient();
  const { error } = await supabase.rpc('accept_advisor_invitation', { p_token: token });

  if (error) {
    if (error.message === 'not_authenticated') {
      redirect(loginPath);
    }
    return { status: 'error', message: await acceptErrorMessage(error) };
  }

  revalidatePath('/', 'layout');

  // Per Einladung neu angelegte Konten haben noch kein Passwort → zuerst
  // festlegen. Bestehende Konten (Anmeldelink) direkt ins Dashboard. Ist der
  // Zustand unbekannt (null), prüft /set-password selbst erneut.
  const hasPassword = await currentUserHasPassword();
  const dashboardPath = await localizedPath(DEFAULT_REDIRECT_PATH);
  redirect(hasPassword ? dashboardPath : await localizedPathWithNext('/set-password', dashboardPath));
}
