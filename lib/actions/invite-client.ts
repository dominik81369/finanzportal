'use server';

/**
 * lib/actions/invite-client.ts
 *
 * Server Action: Berater lädt einen Mandanten per E-Mail ein.
 *
 * Ablauf
 *   1. requireAdvisor() – nur Berater (RLS prüft beim INSERT zusätzlich
 *      private.is_advisor(), Defense in Depth).
 *   2. Token aus 32 Byte crypto.randomBytes; in advisor_clients landet
 *      ausschließlich SHA-256(token) als Hex (lib/invite-token.ts).
 *   3. INSERT über den normalen Server-Client (RLS aktiv) – der Admin-Client
 *      wird nur für den E-Mail-Versand verwendet.
 *   4. Versand über den Admin-Client mit dem Klartext-Token im Link:
 *      {origin}/auth/callback?next=/invite/<token>
 *      Die Templates in supabase/templates/ hängen token_hash und type an.
 *
 * Eine noch offene Einladung an dieselbe Adresse wird ersetzt ("erneut
 * senden"): Der alte Link wird ungültig, weil der Trigger beim Widerruf den
 * Token-Hash löscht.
 *
 * Der Link zeigt bewusst auf die deutsche Fassung (ohne Sprachpräfix): Die
 * Sprache des Eingeladenen ist unbekannt, und die E-Mail-Templates in
 * supabase/templates/ sind deutsch.
 */
import type { AuthError } from '@supabase/supabase-js';
import { revalidatePath } from 'next/cache';
import { headers } from 'next/headers';
import { getTranslations } from 'next-intl/server';

import {
  INVITE_TTL_DAYS,
  generateInviteToken,
  hashInviteToken,
  invitePath,
} from '@/lib/invite-token';
import { createAdminClient } from '@/lib/supabase/admin';
import { createClient, requireAdvisor } from '@/lib/supabase/server';
import { getAppOrigin } from '@/lib/url';
import { parseEmail } from '@/lib/validation';
import type { AdvisorInvitationInsert, AdvisorLinkRevoke } from '@/types/domain';

const DAY_MS = 24 * 60 * 60 * 1000;

export type InviteClientState = {
  status: 'idle' | 'error' | 'success';
  message?: string;
  values?: { email?: string };
};

type AdminClient = ReturnType<typeof createAdminClient>;
type InviteClientTranslator = Awaited<ReturnType<typeof getTranslations<'InviteClient'>>>;

function sendErrorMessage(error: AuthError, t: InviteClientTranslator): string {
  if (error.code === 'over_email_send_rate_limit' || error.status === 429) {
    return t('rateLimited');
  }
  console.error('[invite-client] E-Mail-Versand fehlgeschlagen', {
    code: error.code,
    status: error.status,
  });
  return t('sendFailed');
}

/**
 * Versendet die Einladung über Supabase Auth.
 *
 * - Neue Adresse: inviteUserByEmail() legt das Auth-Konto an und verschickt
 *   das Template "Invite user".
 * - Bereits registrierte Adresse: inviteUserByEmail() scheitert mit
 *   email_exists. Dann stattdessen ein Anmeldelink (Template "Magic Link"),
 *   ohne ein Konto anzulegen.
 *
 * Beide Templates führen über {{ .RedirectTo }} zu /invite/<token>.
 */
async function sendInvitationEmail(
  admin: AdminClient,
  email: string,
  redirectTo: string,
): Promise<AuthError | null> {
  const { error: inviteError } = await admin.auth.admin.inviteUserByEmail(email, { redirectTo });
  if (!inviteError) {
    return null;
  }
  if (inviteError.code !== 'email_exists') {
    return inviteError;
  }

  const { error: otpError } = await admin.auth.signInWithOtp({
    email,
    options: { shouldCreateUser: false, emailRedirectTo: redirectTo },
  });
  return otpError;
}

export async function inviteClient(
  _prevState: InviteClientState,
  formData: FormData,
): Promise<InviteClientState> {
  // 1. Berechtigung – leitet Nicht-Berater um, bevor irgendetwas passiert.
  const advisor = await requireAdvisor();
  const t = await getTranslations('InviteClient');
  const genericError = t('generic');

  const rawEmail = formData.get('email');
  const values = { email: typeof rawEmail === 'string' ? rawEmail.trim() : '' };
  const email = parseEmail(rawEmail);

  if (!email) {
    const tValidation = await getTranslations('Validation');
    return { status: 'error', message: tValidation('emailInvalid'), values };
  }
  if (email === advisor.email?.toLowerCase()) {
    return { status: 'error', message: t('selfInvite'), values };
  }

  // Früh erzeugen: Fehlt die Admin-Konfiguration, scheitert die Action, bevor
  // eine Einladung ohne zugestellte E-Mail in der Datenbank steht.
  const admin = createAdminClient();
  const supabase = await createClient();

  // 2. Bestehende Verknüpfungen mit dieser Adresse
  const { data: existing, error: lookupError } = await supabase
    .from('advisor_clients')
    .select('id, status')
    .eq('advisor_id', advisor.id)
    .eq('invited_email', email)
    .in('status', ['invited', 'active']);

  if (lookupError) {
    console.error('[invite-client] Lookup fehlgeschlagen', { code: lookupError.code });
    return { status: 'error', message: genericError, values };
  }
  if (existing.some((link) => link.status === 'active')) {
    return { status: 'error', message: t('alreadyConnected'), values };
  }

  const openInvitationIds = existing
    .filter((link) => link.status === 'invited')
    .map((link) => link.id);
  if (openInvitationIds.length > 0) {
    const revoke: AdvisorLinkRevoke = { status: 'revoked' };
    const { error: revokeError } = await supabase
      .from('advisor_clients')
      .update(revoke)
      .in('id', openInvitationIds);

    if (revokeError) {
      console.error('[invite-client] Widerruf der offenen Einladung fehlgeschlagen', {
        code: revokeError.code,
      });
      return { status: 'error', message: genericError, values };
    }
  }

  // 3. Token erzeugen – der Klartext existiert danach nur noch im E-Mail-Link.
  const token = generateInviteToken();
  const invitation: AdvisorInvitationInsert = {
    invited_email: email,
    invite_token_hash: hashInviteToken(token),
    invite_expires_at: new Date(Date.now() + INVITE_TTL_DAYS * DAY_MS).toISOString(),
  };

  const { data: inserted, error: insertError } = await supabase
    .from('advisor_clients')
    .insert(invitation)
    .select('id')
    .single();

  if (insertError) {
    // 23505: parallele Einladung an dieselbe Adresse (advisor_clients_open_invite_key)
    if (insertError.code === '23505') {
      return { status: 'error', message: t('duplicateInvitation'), values };
    }
    console.error('[invite-client] Insert fehlgeschlagen', { code: insertError.code });
    return { status: 'error', message: genericError, values };
  }

  // 4. Versand
  const origin = getAppOrigin(await headers());
  const redirectTo = `${origin}/auth/callback?next=${encodeURIComponent(invitePath(token))}`;
  const sendError = await sendInvitationEmail(admin, email, redirectTo);

  if (sendError) {
    // Eine Einladung, deren Link niemand erhalten hat, wieder entfernen.
    const { error: cleanupError } = await supabase
      .from('advisor_clients')
      .delete()
      .eq('id', inserted.id);
    if (cleanupError) {
      console.error('[invite-client] Aufräumen fehlgeschlagen', { code: cleanupError.code });
    }
    return { status: 'error', message: sendErrorMessage(sendError, t), values };
  }

  revalidatePath('/advisor', 'layout');
  return { status: 'success', message: t('success', { email, days: INVITE_TTL_DAYS }) };
}
