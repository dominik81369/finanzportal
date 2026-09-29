/**
 * app/[locale]/advisor/page.tsx
 *
 * Beraterbereich: Mandanten einladen, verbundene Mandanten und offene
 * Einladungen verwalten (erneut senden, zurückziehen, Zugriff beenden).
 *
 * Die Abfrage filtert ausdrücklich auf advisor_id = eigener Nutzer; RLS
 * (advisor_clients_select_participant) würde einem Berater, der selbst
 * Mandant eines anderen Beraters ist, sonst auch diese Verbindung zeigen.
 * Namen der Mandanten aus profiles – lesbar nur für aktive Verbindungen.
 */
import { getFormatter, getTranslations } from 'next-intl/server';

import { revokeClientLink } from '@/lib/actions/advisor-links';
import { INVITE_TTL_DAYS } from '@/lib/invite-token';
import { createClient, requireAdvisor } from '@/lib/supabase/server';

import { ConfirmAction } from '../confirm-action';
import { InviteForm } from './invite-form';
import { ResendInvitation } from './resend-invitation';

type AdvisorPageProps = {
  searchParams: Promise<{ ended?: string | string[] }>;
};

function fullName(profile: { first_name: string | null; last_name: string | null } | null) {
  return [profile?.first_name, profile?.last_name].filter(Boolean).join(' ');
}

export default async function AdvisorPage({ searchParams }: AdvisorPageProps) {
  const advisor = await requireAdvisor();
  const { ended } = await searchParams;
  const t = await getTranslations('Advisor');
  const format = await getFormatter();

  const supabase = await createClient();
  const { data: links, error } = await supabase
    .from('advisor_clients')
    .select(
      `id, status, invited_email, invited_at, invite_expires_at, accepted_at,
       client:profiles!advisor_clients_user_id_fkey ( first_name, last_name )`,
    )
    .eq('advisor_id', advisor.id)
    .in('status', ['active', 'invited'])
    .order('invited_at', { ascending: false });

  if (error) {
    console.error('[advisor] Verbindungen nicht ladbar', { code: error.code });
  }

  const clients = (links ?? []).filter((link) => link.status === 'active');
  const invitations = (links ?? []).filter((link) => link.status === 'invited');
  const now = Date.now();
  const date = (value: string) => format.dateTime(new Date(value), { dateStyle: 'medium' });

  const endClientLabels = {
    button: t('clients.end'),
    question: t('clients.endQuestion'),
    confirm: t('clients.endConfirm'),
    cancel: t('cancel'),
    pending: t('clients.ending'),
  };
  const withdrawLabels = {
    button: t('pending.withdraw'),
    question: t('pending.withdrawQuestion'),
    confirm: t('pending.withdrawConfirm'),
    cancel: t('cancel'),
    pending: t('pending.withdrawing'),
  };

  return (
    <div className="advisor-page">
      <h1>{t('heading')}</h1>
      <p>{t('intro')}</p>

      {ended === 'client' || ended === 'invitation' ? (
        <p role="status" className="form-success">
          {t(ended === 'client' ? 'clients.ended' : 'pending.withdrawn')}
        </p>
      ) : null}

      {error ? (
        <p role="alert" className="form-error">
          {t('loadError')}
        </p>
      ) : null}

      <section className="advisor-section" aria-labelledby="invite-heading">
        <h2 id="invite-heading">{t('invite.heading')}</h2>
        <InviteForm validDays={INVITE_TTL_DAYS} />
      </section>

      <section className="advisor-section" aria-labelledby="clients-heading">
        <h2 id="clients-heading">{t('clients.heading')}</h2>
        {clients.length === 0 ? (
          <p className="empty-state">{t('clients.empty')}</p>
        ) : (
          <ul className="link-list">
            {clients.map((link) => {
              const name = fullName(link.client) || t('clients.noName');
              return (
                <li key={link.id} className="link-item">
                  <div className="link-item-text">
                    <strong>{name}</strong>
                    <span className="cell-note">{link.invited_email}</span>
                    {link.accepted_at ? (
                      <span className="cell-note">
                        {t('clients.since', { date: date(link.accepted_at) })}
                      </span>
                    ) : null}
                  </div>
                  <ConfirmAction
                    action={revokeClientLink.bind(null, link.id, 'client')}
                    labels={endClientLabels}
                    buttonLabel={t('clients.endLabel', { name })}
                  />
                </li>
              );
            })}
          </ul>
        )}
      </section>

      <section className="advisor-section" aria-labelledby="pending-heading">
        <h2 id="pending-heading">{t('pending.heading')}</h2>
        {invitations.length === 0 ? (
          <p className="empty-state">{t('pending.empty')}</p>
        ) : (
          <ul className="link-list">
            {invitations.map((link) => {
              const expired =
                link.invite_expires_at !== null && new Date(link.invite_expires_at).getTime() < now;
              return (
                // Schlüssel = E-Mail, nicht id: „Erneut senden“ ersetzt die Zeile
                // durch eine neue (neue id). So bleibt die Rückmeldung sichtbar.
                // Offene Einladungen sind je Berater und Adresse eindeutig
                // (advisor_clients_open_invite_key).
                <li key={link.invited_email} className="link-item">
                  <div className="link-item-text">
                    <strong>{link.invited_email}</strong>
                    <span className="cell-note">
                      {t('pending.invitedOn', { date: date(link.invited_at) })}
                      {' · '}
                      {expired ? (
                        <span className="badge badge-muted">{t('pending.expired')}</span>
                      ) : link.invite_expires_at ? (
                        t('pending.validUntil', { date: date(link.invite_expires_at) })
                      ) : null}
                    </span>
                  </div>
                  <div className="link-item-actions">
                    <ResendInvitation email={link.invited_email} />
                    <ConfirmAction
                      action={revokeClientLink.bind(null, link.id, 'invitation')}
                      labels={withdrawLabels}
                      buttonLabel={t('pending.withdrawLabel', { email: link.invited_email })}
                    />
                  </div>
                </li>
              );
            })}
          </ul>
        )}
      </section>
    </div>
  );
}
