/**
 * lib/spending-period.ts
 *
 * Zeitraum des Ausgaben-Dashboards aus der URL: Woche (Mo–So), Monat,
 * Quartal, Jahr oder frei gewählt; blättern; Vergleich mit der Vorperiode
 * (beim Monat und Quartal wahlweise mit dem Vorjahr). Reine Funktionen,
 * Datumswerte als 'YYYY-MM-DD' (Kalendertage, ohne Uhrzeit).
 *
 * Laufende Periode: ausgewertet wird bis heute, verglichen mit gleich
 * vielen Tagen ab Beginn der Vergleichsperiode (1.–9. Oktober gegen
 * 1.–9. September) – sonst sähe jeder Monatsanfang wie ein Einbruch aus.
 */
import { parseIsoDate } from '@/lib/transactions';

export const PERIOD_TYPES = ['week', 'month', 'quarter', 'year', 'custom'] as const;
export type PeriodType = (typeof PERIOD_TYPES)[number];

export type CompareMode = 'previous' | 'year';
export type Bucket = 'day' | 'week' | 'month';

/** Kalendertage, jeweils einschließlich. */
export type DateRange = { from: string; to: string };

export type SpendingPeriod = {
  type: PeriodType;
  /** Ganze Periode (bei „frei“ der gewählte Zeitraum). */
  range: DateRange;
  /** Ausgewerteter Teil: bei laufender Periode bis heute. */
  evaluated: DateRange;
  /** Die Periode enthält heute (und endet nicht vorher). */
  running: boolean;
  compareMode: CompareMode;
  /** Vergleichszeitraum, gleich lang wie evaluated. */
  compare: DateRange;
  bucket: Bucket;
};

/** Längster freier Zeitraum (Grenze der Datenbankfunktion: gut fünf Jahre). */
export const MAX_CUSTOM_DAYS = 5 * 366;

type SearchParams = Record<string, string | string[] | undefined>;

const DAY_MS = 86_400_000;

function single(value: string | string[] | undefined): string {
  return (Array.isArray(value) ? value[0] : value)?.trim() ?? '';
}

function toUtc(date: string): number {
  return Date.UTC(Number(date.slice(0, 4)), Number(date.slice(5, 7)) - 1, Number(date.slice(8, 10)));
}

function fromUtc(ms: number): string {
  return new Date(ms).toISOString().slice(0, 10);
}

export function addDays(date: string, days: number): string {
  return fromUtc(toUtc(date) + days * DAY_MS);
}

/** Tage von from bis to, einschließlich. */
export function dayCount(range: DateRange): number {
  return Math.round((toUtc(range.to) - toUtc(range.from)) / DAY_MS) + 1;
}

function monthStart(date: string, deltaMonths = 0): string {
  const year = Number(date.slice(0, 4));
  const month = Number(date.slice(5, 7)) - 1 + deltaMonths;
  return fromUtc(Date.UTC(year, month, 1));
}

function monthEnd(date: string): string {
  return addDays(monthStart(date, 1), -1);
}

function minDate(a: string, b: string): string {
  return a < b ? a : b;
}

/** Montag der Woche (ISO). */
export function weekStart(date: string): string {
  const weekday = (new Date(toUtc(date)).getUTCDay() + 6) % 7; // Mo = 0
  return addDays(date, -weekday);
}

/** Kalenderwoche nach ISO 8601 (Woche mit dem ersten Donnerstag ist KW 1). */
export function isoWeek(date: string): number {
  const thursday = addDays(weekStart(date), 3);
  const firstThursday = addDays(weekStart(`${thursday.slice(0, 4)}-01-04`), 3);
  return Math.round((toUtc(thursday) - toUtc(firstThursday)) / (7 * DAY_MS)) + 1;
}

/** Ganze Periode des Typs, die date enthält (nicht für custom). */
export function periodRange(type: Exclude<PeriodType, 'custom'>, date: string): DateRange {
  switch (type) {
    case 'week': {
      const from = weekStart(date);
      return { from, to: addDays(from, 6) };
    }
    case 'month':
      return { from: monthStart(date), to: monthEnd(date) };
    case 'quarter': {
      const quarterMonth = Math.floor((Number(date.slice(5, 7)) - 1) / 3) * 3;
      const from = fromUtc(Date.UTC(Number(date.slice(0, 4)), quarterMonth, 1));
      return { from, to: addDays(monthStart(from, 3), -1) };
    }
    case 'year':
      return { from: `${date.slice(0, 4)}-01-01`, to: `${date.slice(0, 4)}-12-31` };
  }
}

/** Gleiche Periode davor bzw. danach (delta = -1 / +1). */
export function shiftRange(type: PeriodType, range: DateRange, delta: number): DateRange {
  switch (type) {
    case 'week':
      return { from: addDays(range.from, 7 * delta), to: addDays(range.to, 7 * delta) };
    case 'month':
      return periodRange('month', monthStart(range.from, delta));
    case 'quarter':
      return periodRange('quarter', monthStart(range.from, 3 * delta));
    case 'year':
      return periodRange('year', monthStart(range.from, 12 * delta));
    case 'custom': {
      const days = dayCount(range);
      return { from: addDays(range.from, days * delta), to: addDays(range.to, days * delta) };
    }
  }
}

/** Teilzeiträume des Verlaufs. */
export function bucketFor(type: PeriodType, range: DateRange): Bucket {
  switch (type) {
    case 'week':
    case 'month':
      return 'day';
    case 'quarter':
      return 'week';
    case 'year':
      return 'month';
    case 'custom': {
      const days = dayCount(range);
      return days <= 62 ? 'day' : days <= 366 ? 'week' : 'month';
    }
  }
}

/** Beginn des Teilzeitraums, in dem date liegt (wie in public.spending_report). */
export function bucketStart(bucket: Bucket, date: string): string {
  return bucket === 'day' ? date : bucket === 'week' ? weekStart(date) : monthStart(date);
}

/** Alle Teilzeiträume eines Bereichs in Reihenfolge (Beginn, ggf. vor range.from). */
export function bucketStarts(bucket: Bucket, range: DateRange): string[] {
  const starts: string[] = [];
  let current = bucketStart(bucket, range.from);
  while (current <= range.to) {
    starts.push(current);
    current = bucket === 'day' ? addDays(current, 1) : bucket === 'week' ? addDays(current, 7) : monthStart(current, 1);
  }
  return starts;
}

/**
 * Vergleichszeitraum: Vorperiode bzw. Vorjahr; bei laufender Periode gleich
 * viele Tage ab deren Beginn, höchstens bis zu deren Ende. Frei gewählt:
 * gleich lang direkt davor.
 */
function compareRange(type: PeriodType, range: DateRange, evaluated: DateRange, mode: CompareMode): DateRange {
  if (type === 'custom') {
    const days = dayCount(evaluated);
    return { from: addDays(evaluated.from, -days), to: addDays(evaluated.from, -1) };
  }
  const full =
    mode === 'year'
      ? { from: monthStart(range.from, -12), to: monthEnd(monthStart(range.to, -12)) }
      : shiftRange(type, range, -1);
  // Abgeschlossene Periode: ganze Vergleichsperiode; laufende: gleich viele Tage.
  if (evaluated.to === range.to) {
    return full;
  }
  return { from: full.from, to: minDate(addDays(full.from, dayCount(evaluated) - 1), full.to) };
}

/**
 * Zeitraum aus ?period=week|month|quarter|year|custom, ?date=YYYY-MM-DD
 * (beliebiger Tag der Periode), ?from=&to= (frei), ?compare=year. Fehlt
 * oder ungültig: aktueller Monat. Zukünftige Perioden werden auf die
 * laufende begrenzt.
 */
export function parseSpendingPeriod(params: SearchParams, today: string): SpendingPeriod {
  const rawType = single(params.period);
  const type: PeriodType = (PERIOD_TYPES as readonly string[]).includes(rawType) ? (rawType as PeriodType) : 'month';

  let range: DateRange;
  if (type === 'custom') {
    let from = parseIsoDate(single(params.from)) ?? addDays(today, -29);
    let to = parseIsoDate(single(params.to)) ?? today;
    if (from > to) {
      [from, to] = [to, from];
    }
    if (from > today) {
      from = today;
    }
    to = minDate(to, today);
    if (dayCount({ from, to }) > MAX_CUSTOM_DAYS) {
      from = addDays(to, -(MAX_CUSTOM_DAYS - 1));
    }
    range = { from, to };
  } else {
    const date = parseIsoDate(single(params.date));
    range = periodRange(type, date && date <= today ? date : today);
  }

  const running = range.from <= today && today <= range.to;
  const evaluated = { from: range.from, to: minDate(range.to, today) };
  const compareMode: CompareMode =
    single(params.compare) === 'year' && (type === 'month' || type === 'quarter') ? 'year' : 'previous';

  return {
    type,
    range,
    evaluated,
    running,
    compareMode,
    compare: compareRange(type, range, evaluated, compareMode),
    bucket: bucketFor(type, range),
  };
}

/** Gibt es eine spätere Periode bis heute? (Knopf „›“) */
export function hasNext(period: SpendingPeriod, today: string): boolean {
  return period.range.to < today;
}

/**
 * Query-String einer Periode (ohne „?“). Feste Perioden über einen Tag der
 * Periode, frei über from/to; Vergleich mit dem Vorjahr und Währung bleiben.
 */
export function periodQuery(
  type: PeriodType,
  range: DateRange,
  options: { compare?: CompareMode; currency?: string | null } = {},
): string {
  const params = new URLSearchParams({ period: type });
  if (type === 'custom') {
    params.set('from', range.from);
    params.set('to', range.to);
  } else {
    params.set('date', range.from);
  }
  if (options.compare === 'year' && (type === 'month' || type === 'quarter')) {
    params.set('compare', 'year');
  }
  if (options.currency) {
    params.set('currency', options.currency);
  }
  return params.toString();
}
