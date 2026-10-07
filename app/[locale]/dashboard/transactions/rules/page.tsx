/**
 * app/[locale]/dashboard/transactions/rules/page.tsx
 *
 * Kategorisierung in Schichten (supabase/migrations/20261007100100_…):
 *   1. manuelle Zuordnungen bleiben immer,
 *   2. eigene Regeln (angelegt oder aus Korrekturen gelernt),
 *   3. eigene Konten (Name/IBAN → Umbuchung),
 *   4. Standardregeln (REWE, MVG, Zinszahlung … – per Knopf geladen).
 * Oben Kennzahlen und Massenaktionen (anwenden, zurücksetzen), darunter die
 * eigenen Regeln in Prüfreihenfolge (lib/import/rules.ts) und eingeklappt
 * die Standardregeln.
 */
import type { Metadata } from 'next';
import { getLocale, getTranslations } from 'next-intl/server';

import { Link } from '@/i18n/navigation';
import { toAppLocale } from '@/i18n/routing';
import {
  applyRules,
  deleteRule,
  loadStandardRules,
  moveRule,
  resetMachineCategorization,
} from '@/lib/actions/categorization-rules';
import { categoryDisplayName } from '@/lib/categories';
import { ruleDirection, sortRules } from '@/lib/import/rules';
import { requireOnboardedUser, createClient } from '@/lib/supabase/server';

import { loadTransactionFormOptions } from '../form-options';
import { OwnAccountForm } from './own-account-form';
import { RuleForm } from './rule-form';

type RulesPageProps = {
  params: Promise<{ locale: string }>;
  searchParams: Promise<Record<string, string | string[] | undefined>>;
};

type Stats = { total: number; manual: number; rule: number; standard: number; uncategorized: number };

export async function generateMetadata({ params }: Pick<RulesPageProps, 'params'>): Promise<Metadata> {
  const locale = toAppLocale((await params).locale);
  const t = await getTranslations({ locale, namespace: 'Rules' });
  return { title: t('metaTitle') };
}

/** Zahl aus einem Query-Parameter der Massenaktionen; sonst null. */
function countParam(value: string | string[] | undefined): number | null {
  return typeof value === 'string' && /^\d{1,6}$/.test(value) ? Number(value) : null;
}

function percent(part: number, total: number): number {
  return total === 0 ? 0 : Math.round((part / total) * 100);
}

export default async function RulesPage({ searchParams }: RulesPageProps) {
  const user = await requireOnboardedUser('/dashboard/transactions/rules');
  const query = await searchParams;
  const t = await getTranslations('Rules');
  const tCategories = await getTranslations('DefaultCategories');

  const supabase = await createClient();
  const [rules, options, statsResult, profile] = await Promise.all([
    supabase
      .from('categorization_rules')
      .select(
        `id, pattern, priority, created_at, origin, match_type, match_field, amount_min, amount_max, is_active,
         category:categories!categorization_rules_category_fkey ( name, default_key, color )`,
      )
      .eq('user_id', user.id),
    loadTransactionFormOptions(user.id),
    supabase.rpc('categorization_stats'),
    supabase.from('profiles').select('first_name, last_name').eq('user_id', user.id).maybeSingle(),
  ]);
  if (rules.error) {
    console.error('[rules] Laden fehlgeschlagen', { code: rules.error.code });
  }
  if (statsResult.error) {
    console.error('[rules] Kennzahlen fehlgeschlagen', { code: statsResult.error.code });
  }
  const all = rules.data ?? [];
  const own = sortRules(all.filter((rule) => rule.origin === 'manual' || rule.origin === 'learned'));
  const ownAccounts = all
    .filter((rule) => rule.origin === 'own_account')
    .sort((a, b) => a.created_at.localeCompare(b.created_at));
  // Vorschlag für die Erkennung eigener Konten: Vor- und Nachname aus dem
  // Profil, solange noch keine Namensregel existiert.
  const profileName = [profile.data?.first_name, profile.data?.last_name]
    .map((part) => part?.trim() ?? '')
    .filter((part) => part !== '')
    .join(' ');
  const suggestedName =
    profileName.includes(' ') && !ownAccounts.some((rule) => rule.match_field === 'counterparty') ? profileName : '';
  // Standardregeln greifen untereinander nach Musterlänge; angezeigt nach
  // Kategorie und Muster, damit man sie leichter findet.
  const collator = new Intl.Collator(await getLocale());
  const standard = all
    .filter((rule) => rule.origin === 'standard')
    .map((rule) => ({ rule, category: rule.category ? categoryDisplayName(rule.category, tCategories) : '' }))
    .sort((a, b) => collator.compare(a.category, b.category) || collator.compare(a.rule.pattern, b.rule.pattern))
    .map(({ rule }) => rule);
  const categoryOptions = options?.categories ?? [];
  const stats = (statsResult.data as Stats | null) ?? null;

  const loaded = countParam(query.loaded);
  const removed = countParam(query.removed) ?? 0;
  const applied = countParam(query.applied);
  const reset = countParam(query.reset);
  const failed = query.error === '1';

  const describe = (rule: (typeof all)[number]) => {
    const parts: string[] = [];
    if (rule.match_field !== 'counterparty_or_purpose') {
      parts.push(t(`fields.${rule.match_field}`));
    }
    if (rule.match_type !== 'contains') {
      parts.push(t(`matchTypes.${rule.match_type}`));
    }
    const direction = ruleDirection(rule);
    if (direction !== '') {
      parts.push(t(`directions.${direction}`));
    }
    if (!rule.is_active) {
      parts.push(t('inactive'));
    }
    return parts.map((part) => ` · ${part}`).join('');
  };

  const ruleTitle = (rule: (typeof all)[number], position?: number) => (
    <strong>
      {position !== undefined ? <span className="rule-position">{position}.</span> : null} „{rule.pattern}“ →{' '}
      {rule.category ? categoryDisplayName(rule.category, tCategories) : '–'}
    </strong>
  );

  const deleteForm = (rule: (typeof all)[number]) => (
    <form action={deleteRule.bind(null, rule.id)}>
      <button
        type="submit"
        className="button button-danger-outline button-small"
        aria-label={t('deleteLabel', { pattern: rule.pattern })}
      >
        {t('delete')}
      </button>
    </form>
  );

  return (
    <section aria-labelledby="page-title" className="rules-page">
      <p className="back-link">
        <Link href="/dashboard/transactions">← {t('back')}</Link>
      </p>
      <h1 id="page-title">{t('heading')}</h1>
      <p>{t('intro')}</p>

      {failed ? (
        <p role="alert" className="form-error">
          {t('errors.generic')}
        </p>
      ) : loaded !== null ? (
        <p role="status" className="form-success">
          {t('notices.loaded', { count: loaded })} {removed > 0 ? `${t('notices.removed', { count: removed })} ` : ''}
          {t('notices.applied', { count: applied ?? 0 })}
        </p>
      ) : applied !== null ? (
        <p role="status" className="form-success">
          {t('notices.applied', { count: applied })}
        </p>
      ) : reset !== null ? (
        <p role="status" className="form-success">
          {t('notices.reset', { count: reset })}
        </p>
      ) : null}

      <section className="advisor-section" aria-labelledby="rule-auto-heading">
        <h2 id="rule-auto-heading">{t('autoHeading')}</h2>
        <p>{t('autoIntro')}</p>
        {stats && stats.total > 0 ? (
          <dl className="categorization-stats">
            <div>
              <dt>{t('stats.auto')}</dt>
              <dd>
                {t('stats.value', {
                  count: stats.rule + stats.standard,
                  percent: percent(stats.rule + stats.standard, stats.total),
                })}
                <span className="cell-note">
                  {t('stats.autoDetail', { rule: stats.rule, standard: stats.standard })}
                </span>
              </dd>
            </div>
            <div>
              <dt>{t('stats.manual')}</dt>
              <dd>{t('stats.value', { count: stats.manual, percent: percent(stats.manual, stats.total) })}</dd>
            </div>
            <div>
              <dt>{t('stats.uncategorized')}</dt>
              <dd>
                {t('stats.value', { count: stats.uncategorized, percent: percent(stats.uncategorized, stats.total) })}
              </dd>
            </div>
          </dl>
        ) : null}
        <div className="button-row">
          <form action={loadStandardRules}>
            <button type="submit" className="button button-secondary">
              {t('loadStandard')}
            </button>
          </form>
          <form action={applyRules}>
            <button type="submit" className="button">
              {t('applyAll')}
            </button>
          </form>
          <form action={resetMachineCategorization}>
            <button type="submit" className="button button-danger-outline">
              {t('resetAuto')}
            </button>
          </form>
        </div>
        <p className="hint">
          {t('resetHint')}{' '}
          <Link href={{ pathname: '/dashboard/transactions', query: { assigned: 'auto' } }}>{t('viewAuto')}</Link>
        </p>
      </section>

      <section className="advisor-section" aria-labelledby="rule-own-heading">
        <h2 id="rule-own-heading">{t('ownAccounts.heading')}</h2>
        <p>{t('ownAccounts.intro')}</p>
        {ownAccounts.length > 0 ? (
          <ul className="link-list rule-list own-account-list">
            {ownAccounts.map((rule) => (
              <li key={rule.id} className="link-item">
                <div className="link-item-text">
                  {ruleTitle(rule)}
                  <span className="cell-note">
                    <span className="badge badge-muted">{t('ownAccounts.badge')}</span>
                    {` · ${t(rule.match_field === 'counterparty_iban' ? 'ownAccounts.kinds.iban' : 'ownAccounts.kinds.name')}`}
                  </span>
                </div>
                <div className="link-item-actions">{deleteForm(rule)}</div>
              </li>
            ))}
          </ul>
        ) : null}
        <OwnAccountForm suggestedName={suggestedName} />
      </section>

      <section className="advisor-section" aria-labelledby="rule-new-heading">
        <h2 id="rule-new-heading">{t('newHeading')}</h2>
        <RuleForm categories={categoryOptions} />
      </section>

      <section className="advisor-section" aria-labelledby="rule-list-heading">
        <h2 id="rule-list-heading">{t('listHeading')}</h2>
        {rules.error ? (
          <p role="alert" className="form-error">
            {t('loadError')}
          </p>
        ) : own.length === 0 ? (
          <p className="empty-state">{t('empty')}</p>
        ) : (
          <ol className="link-list rule-list">
            {own.map((rule, index) => (
              <li key={rule.id} className="link-item">
                <div className="link-item-text">
                  {ruleTitle(rule, index + 1)}
                  <span className="cell-note">
                    {rule.origin === 'learned' ? (
                      <span className="badge">{t('learned')}</span>
                    ) : (
                      <span className="badge badge-muted">{t('manual')}</span>
                    )}
                    {describe(rule)}
                  </span>
                </div>
                <div className="link-item-actions">
                  <form action={moveRule.bind(null, rule.id, 'up')}>
                    <button
                      type="submit"
                      className="button button-secondary button-small"
                      disabled={index === 0}
                      aria-label={t('moveUpLabel', { pattern: rule.pattern })}
                    >
                      ↑
                    </button>
                  </form>
                  <form action={moveRule.bind(null, rule.id, 'down')}>
                    <button
                      type="submit"
                      className="button button-secondary button-small"
                      disabled={index === own.length - 1}
                      aria-label={t('moveDownLabel', { pattern: rule.pattern })}
                    >
                      ↓
                    </button>
                  </form>
                  {deleteForm(rule)}
                </div>
              </li>
            ))}
          </ol>
        )}
      </section>

      <section className="advisor-section" aria-labelledby="rule-standard-heading">
        <h2 id="rule-standard-heading">{t('standardHeading')}</h2>
        {standard.length === 0 ? (
          <p className="empty-state">{t('standardEmpty')}</p>
        ) : (
          <details className="rule-details">
            <summary>{t('standardSummary', { count: standard.length })}</summary>
            <ul className="link-list rule-list">
              {standard.map((rule) => (
                <li key={rule.id} className="link-item">
                  <div className="link-item-text">
                    {ruleTitle(rule)}
                    <span className="cell-note">
                      <span className="badge badge-muted">{t('standard')}</span>
                      {describe(rule)}
                    </span>
                  </div>
                  <div className="link-item-actions">{deleteForm(rule)}</div>
                </li>
              ))}
            </ul>
          </details>
        )}
      </section>
    </section>
  );
}
