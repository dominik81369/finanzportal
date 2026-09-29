/**
 * app/[locale]/dashboard/advisors/page.tsx
 *
 * Mandantensicht: verbundene Berater mit Lesezugriff und die Möglichkeit,
 * diesen Zugriff jederzeit zu widerrufen (revokeMyAdvisor).
 *
 * Abfrage ausdrücklich auf user_id = eigener Nutzer; Namen der Berater aus
 * profiles (lesbar über private.my_advisor_ids()).
 */
import type { Metadata } from 'next';
import { getFormatter, getTranslations } from 'next-intl/server';

import { toAppLocale } from '@/i18n/routing';
import { revokeMyAdvisor } from '@/lib/actions/advisor-links';
import { createClient, requireOnboardedUser } from '@/lib/supabase/server';

import { ConfirmAction } from '../../confirm-action';

type AdvisorsPageProps = {
  params: Promise<{ locale: string }>;
  searchParams: Promise<{ revoked?: string | string[] }>;
};

export async function generateMetadata({
  params,
}: Pick<AdvisorsPageProps, 'params'>): Promise<Metadata> {
  const locale = toAppLocale((await params).locale);
  const t = await getTranslations({ locale, namespace: 'Dashboard' });
  return { title: t('advisors.title') };
}

export default async function AdvisorsPage({ searchParams }: AdvisorsPageProps) {
  const user = await requireOnboardedUser('/dashboard/advisors');
  const { revoked } = await searchParams;
  const t = await getTranslations('Dashboard.advisors');
  const tAdvisor = await getTranslations('Advisor');
  const format = await getFormatter();

  const supabase = await createClient();
  const { data: links, error } = await supabase
    .from('advisor_clients')
    .select(
      `id, accepted_at,
       advisor:profiles!advisor_clients_advisor_id_fkey ( first_name, last_name )`,
    )
    .eq('user_id', user.id)
    .eq('status', 'active')
    .order('accepted_at', { ascending: false });

  if (error) {
    console.error('[dashboard/advisors] Verbindungen nicht ladbar', { code: error.code });
  }

  const labels = {
    button: t('revoke'),
    question: t('revokeQuestion'),
    confirm: t('revokeConfirm'),
    cancel: tAdvisor('cancel'),
    pending: t('revoking'),
  };

  return (
    <section className="page-narrow" aria-labelledby="page-title">
      <h1 id="page-title">{t('title')}</h1>
      <p>{t('description')}</p>

      {revoked === '1' ? (
        <p role="status" className="form-success">
          {t('revoked')}
        </p>
      ) : null}

      {error ? (
        <p role="alert" className="form-error">
          {t('loadError')}
        </p>
      ) : !links || links.length === 0 ? (
        <p className="empty-state">{t('empty')}</p>
      ) : (
        <ul className="link-list">
          {links.map((link) => {
            const name =
              [link.advisor?.first_name, link.advisor?.last_name].filter(Boolean).join(' ') ||
              t('noName');
            return (
              <li key={link.id} className="link-item">
                <div className="link-item-text">
                  <strong>{name}</strong>
                  <span className="cell-note">{t('access')}</span>
                  {link.accepted_at ? (
                    <span className="cell-note">
                      {t('since', {
                        date: format.dateTime(new Date(link.accepted_at), { dateStyle: 'medium' }),
                      })}
                    </span>
                  ) : null}
                </div>
                <ConfirmAction
                  action={revokeMyAdvisor.bind(null, link.id)}
                  labels={labels}
                  buttonLabel={t('revokeLabel', { name })}
                />
              </li>
            );
          })}
        </ul>
      )}
    </section>
  );
}
