/**
 * lib/contract-labels.ts
 *
 * Beschriftungen für Verträge (Rhythmus, Typ, Status, Sicherheit) in der
 * Sprache der Seite – für die eigenen Vertragsseiten und die Leseansicht
 * des Beraters.
 */
import 'server-only';

import { getTranslations } from 'next-intl/server';

import {
  confidenceLevel,
  rhythmKey,
  type ContractRhythm,
  type ContractStatus,
  type ContractType,
} from '@/lib/contracts';

export async function getContractLabels() {
  const t = await getTranslations('Contracts');
  return {
    rhythm(rhythm: ContractRhythm, intervalCount: number): string {
      const key = rhythmKey(rhythm, intervalCount);
      return key ? t(`rhythms.${key}`) : t('rhythms.custom', { rhythm: t(`rhythms.${rhythm}`), count: intervalCount });
    },
    type(type: ContractType): string {
      return t(`types.${type}`);
    },
    status(status: ContractStatus): string {
      return t(`status.${status}`);
    },
    confidence(confidence: number | null): string {
      return t(`confidenceLevels.${confidenceLevel(confidence)}`);
    },
  };
}

export type ContractLabels = Awaited<ReturnType<typeof getContractLabels>>;
