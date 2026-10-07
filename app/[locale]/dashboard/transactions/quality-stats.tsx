/**
 * Dauerhafte Kennzahlen der automatischen Kategorisierung
 * (public.categorization_quality):
 *  - Automatisierungsquote: Anteil der Buchungen, die automatisch eine
 *    Kategorie bekommen haben,
 *  - Treffsicherheit: Anteil davon ohne spätere Korrektur.
 */
import { getFormatter, getTranslations } from 'next-intl/server';

import { createClient } from '@/lib/supabase/server';

type Quality = {
  total: number;
  automated: number;
  accurate: number;
  automation_rate: number | null;
  accuracy: number | null;
};

export async function QualityStats() {
  const t = await getTranslations('Quality');
  const format = await getFormatter();
  const supabase = await createClient();
  const { data, error } = await supabase.rpc('categorization_quality');
  if (error) {
    console.error('[quality] Kennzahlen fehlgeschlagen', { code: error.code });
    return null;
  }
  const quality = data as Quality | null;
  if (!quality || quality.total === 0) {
    return null;
  }
  const percent = (value: number | null) =>
    value === null ? '–' : format.number(value, { style: 'percent', maximumFractionDigits: 0 });

  return (
    <dl className="quality-stats" aria-label={t('label')}>
      <div>
        <dt>{t('automationRate')}</dt>
        <dd>
          {percent(quality.automation_rate)}
          <span className="cell-note">{t('automationDetail', { automated: quality.automated, total: quality.total })}</span>
        </dd>
      </div>
      <div>
        <dt>{t('accuracy')}</dt>
        <dd>
          {percent(quality.accuracy)}
          <span className="cell-note">
            {quality.automated === 0
              ? t('accuracyNone')
              : t('accuracyDetail', { accurate: quality.accurate, automated: quality.automated })}
          </span>
        </dd>
      </div>
    </dl>
  );
}
