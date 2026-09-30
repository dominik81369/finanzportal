/**
 * app/[locale]/dashboard/transactions/rules/page.tsx
 *
 * Kategorisierungsregeln: „Empfänger oder Verwendungszweck enthält … →
 * Kategorie“. Angezeigt in der Reihenfolge, in der sie geprüft werden
 * (lib/import/rules.ts, wie private.match_category_rule); der erste Treffer
 * gewinnt. Neue Regeln legt der Nutzer hier an oder sie entstehen aus
 * Kategorie-Korrekturen (origin = learned).
 */
import type { Metadata } from 'next';
import { getTranslations } from 'next-intl/server';

import { Link } from '@/i18n/navigation';
import { toAppLocale } from '@/i18n/routing';
import { deleteRule, moveRule } from '@/lib/actions/categorization-rules';
import { categoryDisplayName } from '@/lib/categories';
import { sortRules } from '@/lib/import/rules';
import { requireOnboardedUser, createClient } from '@/lib/supabase/server';

import { loadTransactionFormOptions } from '../form-options';
import { RuleForm } from './rule-form';

type RulesPageProps = { params: Promise<{ locale: string }> };

export async function generateMetadata({ params }: RulesPageProps): Promise<Metadata> {
  const locale = toAppLocale((await params).locale);
  const t = await getTranslations({ locale, namespace: 'Rules' });
  return { title: t('metaTitle') };
}

export default async function RulesPage() {
  const user = await requireOnboardedUser('/dashboard/transactions/rules');
  const t = await getTranslations('Rules');
  const tCategories = await getTranslations('DefaultCategories');

  const supabase = await createClient();
  const [rules, options] = await Promise.all([
    supabase
      .from('categorization_rules')
      .select(
        `id, pattern, priority, created_at, origin, match_type, is_active,
         category:categories!categorization_rules_category_fkey ( name, default_key, color )`,
      )
      .eq('user_id', user.id),
    loadTransactionFormOptions(user.id),
  ]);
  if (rules.error) {
    console.error('[rules] Laden fehlgeschlagen', { code: rules.error.code });
  }
  const sorted = sortRules(rules.data ?? []);
  const categoryOptions = options?.categories ?? [];

  return (
    <section aria-labelledby="page-title" className="rules-page">
      <p className="back-link">
        <Link href="/dashboard/transactions">← {t('back')}</Link>
      </p>
      <h1 id="page-title">{t('heading')}</h1>
      <p>{t('intro')}</p>

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
        ) : sorted.length === 0 ? (
          <p className="empty-state">{t('empty')}</p>
        ) : (
          <ol className="link-list rule-list">
            {sorted.map((rule, index) => (
              <li key={rule.id} className="link-item">
                <div className="link-item-text">
                  <strong>
                    <span className="rule-position">{index + 1}.</span> „{rule.pattern}“ →{' '}
                    {rule.category ? categoryDisplayName(rule.category, tCategories) : '–'}
                  </strong>
                  <span className="cell-note">
                    {rule.origin === 'learned' ? (
                      <span className="badge">{t('learned')}</span>
                    ) : (
                      <span className="badge badge-muted">{t('manual')}</span>
                    )}
                    {rule.match_type !== 'contains' ? ` · ${t(`matchTypes.${rule.match_type}`)}` : null}
                    {rule.is_active ? null : ` · ${t('inactive')}`}
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
                      disabled={index === sorted.length - 1}
                      aria-label={t('moveDownLabel', { pattern: rule.pattern })}
                    >
                      ↓
                    </button>
                  </form>
                  <form action={deleteRule.bind(null, rule.id)}>
                    <button
                      type="submit"
                      className="button button-danger-outline button-small"
                      aria-label={t('deleteLabel', { pattern: rule.pattern })}
                    >
                      {t('delete')}
                    </button>
                  </form>
                </div>
              </li>
            ))}
          </ol>
        )}
      </section>
    </section>
  );
}
