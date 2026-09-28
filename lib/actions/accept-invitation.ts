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

import { invitePath, isWellFormedInviteToken } from '@/lib/invite-token';
import { createClient, getSessionUser } from '@/lib/supabase/server';
import { DEFAULT_REDIRECT_PATH } from '@/lib/url';

export type AcceptInvitationState = {
  status: 'idle' | 'error';
  message?: string;
};

const INVALID_OR_EXPIRED =
  'Diese Einladung ist ungültig oder abgelaufen. Bitte prüfen Sie, ob Sie mit der E-Mail-Adresse angemeldet sind, an die die Einladung ging – oder bitten Sie Ihren Berater, die Einladung erneut zu senden.';

function acceptErrorMessage(error: PostgrestError): string {
  // Die RPC meldet fachliche Fehler über die Exception-Message.
  switch (error.message) {
    case 'invalid_or_expired_invitation':
      return INVALID_OR_EXPIRED;
    case 'email_not_confirmed':
      return 'Bitte bestätigen Sie zuerst Ihre E-Mail-Adresse über den Link in unserer E-Mail und versuchen Sie es dann erneut.';
  }

  // advisor_clients_active_pair_key: bereits aktive Verbindung zu diesem Berater
  if (error.code === '23505') {
    return 'Sie sind mit diesem Berater bereits verbunden.';
  }

  console.error('[accept-invitation] RPC fehlgeschlagen', { code: error.code });
  return 'Die Einladung konnte nicht angenommen werden. Bitte versuchen Sie es später erneut.';
}

export async function acceptInvitation(
  _prevState: AcceptInvitationState,
  formData: FormData,
): Promise<AcceptInvitationState> {
  const token = formData.get('token');
  if (!isWellFormedInviteToken(token)) {
    return { status: 'error', message: INVALID_OR_EXPIRED };
  }

  const loginPath = `/login?next=${encodeURIComponent(invitePath(token))}`;
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
    return { status: 'error', message: acceptErrorMessage(error) };
  }

  revalidatePath('/', 'layout');
  redirect(DEFAULT_REDIRECT_PATH);
}
