/**
 * lib/currency.ts
 *
 * Unterstützte Währungen. Muss zur Domain public.currency_code passen
 * (supabase/migrations/20261001000000_supported_currencies.sql); die
 * Datenbank weist andere Codes ohnehin ab.
 *
 * Beträge werden in ihrer Originalwährung gespeichert und angezeigt –
 * es gibt bewusst keine Umrechnung (kein base_amount, keine Wechselkurse).
 *
 * DESIGNREGEL für Summen über mehrere Konten oder Buchungen (Net Worth,
 * Budgets, Übersichten): Beträge unterschiedlicher Währungen NIE addieren.
 * Stattdessen je Währung eine eigene Summe ausweisen, z. B.
 * „1.234,00 € · 250,00 CHF“.
 */

export const SUPPORTED_CURRENCIES = ['EUR', 'USD', 'CHF'] as const;

export type SupportedCurrency = (typeof SUPPORTED_CURRENCIES)[number];

export function isSupportedCurrency(value: string): value is SupportedCurrency {
  return (SUPPORTED_CURRENCIES as readonly string[]).includes(value);
}
