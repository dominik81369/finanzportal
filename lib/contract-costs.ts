/**
 * lib/contract-costs.ts
 *
 * Jahreskosten der Verträge (V2a): erwarteter Betrag × Abbuchungen pro Jahr
 * (wöchentlich 52, 14-tägig 26, monatlich 12, zweimonatlich 6,
 * vierteljährlich 4, halbjährlich 2, jährlich 1), je Währung und
 * Vertragstyp, dazu „tatsächlich“: verknüpfte Abbuchungen minus
 * Gegenbuchungen (Erstattung, Rücklastschrift) der letzten 12 vollen Monate
 * aus public.contract_actuals(). Gezählt werden aktive Verträge und solche
 * mit vorgemerkter Kündigung. Gerechnet wird in Cent (Ganzzahlen); Beträge
 * verschiedener Währungen werden nie addiert.
 */
import { addMonths, type MonthKey, type MonthRange } from '@/lib/budget-rule';
import { CONTRACT_TYPES, type ContractRhythm, type ContractStatus, type ContractType } from '@/lib/contracts';
import { SUPPORTED_CURRENCIES } from '@/lib/currency';

const PER_YEAR: Record<ContractRhythm, number> = {
  weekly: 52,
  monthly: 12,
  quarterly: 4,
  semiannual: 2,
  yearly: 1,
};

/** Statuswerte, die in den Jahreskosten zählen. */
export const COSTED_STATUSES: readonly ContractStatus[] = ['active', 'cancellation_pending'];

/** Abbuchungen pro Jahr (14-tägig = wöchentlich ×2 → 26). */
export function paymentsPerYear(rhythm: ContractRhythm, intervalCount: number): number {
  return PER_YEAR[rhythm] / Math.max(intervalCount, 1);
}

function toCents(value: number | string): number {
  return Math.round(Number(value) * 100);
}

/** Jahreskosten in Cent; null ohne erwarteten Betrag. */
export function annualCents(
  expectedAmount: number | string | null,
  rhythm: ContractRhythm,
  intervalCount: number,
): number | null {
  if (expectedAmount === null) {
    return null;
  }
  return Math.round(Math.abs(toCents(expectedAmount)) * paymentsPerYear(rhythm, intervalCount));
}

/** Die letzten 12 vollen Monate vor dem laufenden Monat. */
export function actualsWindow(currentMonth: MonthKey): MonthRange {
  return { from: addMonths(currentMonth, -12), to: addMonths(currentMonth, -1) };
}

export type CostContract = {
  id: string;
  contractType: ContractType;
  status: ContractStatus;
  rhythm: ContractRhythm;
  intervalCount: number;
  expectedAmount: number | string | null;
  currency: string;
};

/** Eine Zeile aus public.contract_actuals(). */
export type ContractActualRow = {
  contract_id: string;
  currency: string;
  debit_count: number;
  debits: number | string;
  credit_count: number;
  credits: number | string;
};

export type ContractActual = { debitCount: number; creditCount: number; netCents: number };

/** Tatsächliche Kosten je Vertrag (nur in der Währung des Vertrags). */
export function actualsByContract(
  contracts: Pick<CostContract, 'id' | 'currency'>[],
  rows: ContractActualRow[],
): Map<string, ContractActual> {
  const currencies = new Map(contracts.map((contract) => [contract.id, contract.currency]));
  const result = new Map<string, ContractActual>();
  for (const row of rows) {
    if (currencies.get(row.contract_id) !== row.currency) {
      continue;
    }
    const current = result.get(row.contract_id) ?? { debitCount: 0, creditCount: 0, netCents: 0 };
    result.set(row.contract_id, {
      debitCount: current.debitCount + Number(row.debit_count),
      creditCount: current.creditCount + Number(row.credit_count),
      netCents: current.netCents + toCents(row.debits) - toCents(row.credits),
    });
  }
  return result;
}

export type CostFigures = {
  /** Verträge (mit und ohne Betrag). */
  count: number;
  annualCents: number;
  /** Jahreskosten / 12, gerundet. */
  monthlyCents: number;
  /** Abbuchungen minus Gegenbuchungen der letzten 12 vollen Monate. */
  actualCents: number;
};

export type CurrencyCosts = {
  currency: string;
  /** Je Vertragstyp in der Reihenfolge von CONTRACT_TYPES, nur Typen mit Verträgen. */
  types: (CostFigures & { type: ContractType })[];
  total: CostFigures;
  /** Verträge ohne erwarteten Betrag (zählen nicht in die Jahreskosten). */
  withoutAmount: number;
};

function emptyFigures(): CostFigures {
  return { count: 0, annualCents: 0, monthlyCents: 0, actualCents: 0 };
}

/** Jahreskosten je Währung und Vertragstyp (nur aktive und gekündigt vorgemerkte Verträge). */
export function summarizeContractCosts(contracts: CostContract[], actuals: ContractActualRow[]): CurrencyCosts[] {
  const costed = contracts.filter((contract) => COSTED_STATUSES.includes(contract.status));
  const actual = actualsByContract(costed, actuals);
  const byCurrency = new Map<string, { types: Map<ContractType, CostFigures>; withoutAmount: number }>();

  for (const contract of costed) {
    const entry = byCurrency.get(contract.currency) ?? { types: new Map(), withoutAmount: 0 };
    const figures = entry.types.get(contract.contractType) ?? emptyFigures();
    const annual = annualCents(contract.expectedAmount, contract.rhythm, contract.intervalCount);
    figures.count += 1;
    figures.annualCents += annual ?? 0;
    figures.actualCents += actual.get(contract.id)?.netCents ?? 0;
    if (annual === null) {
      entry.withoutAmount += 1;
    }
    entry.types.set(contract.contractType, figures);
    byCurrency.set(contract.currency, entry);
  }

  const currencyOrder = (currency: string) => {
    const index = (SUPPORTED_CURRENCIES as readonly string[]).indexOf(currency);
    return index === -1 ? SUPPORTED_CURRENCIES.length : index;
  };

  return [...byCurrency.entries()]
    .sort(([a], [b]) => currencyOrder(a) - currencyOrder(b) || a.localeCompare(b))
    .map(([currency, entry]) => {
      const types = CONTRACT_TYPES.filter((type) => entry.types.has(type)).map((type) => {
        const figures = entry.types.get(type)!;
        return { type, ...figures, monthlyCents: Math.round(figures.annualCents / 12) };
      });
      const total = types.reduce<CostFigures>(
        (sum, row) => ({
          count: sum.count + row.count,
          annualCents: sum.annualCents + row.annualCents,
          monthlyCents: 0,
          actualCents: sum.actualCents + row.actualCents,
        }),
        emptyFigures(),
      );
      total.monthlyCents = Math.round(total.annualCents / 12);
      return { currency, types, total, withoutAmount: entry.withoutAmount };
    });
}
