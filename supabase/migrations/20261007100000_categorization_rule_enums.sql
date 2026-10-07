-- =====================================================================
--  20261007100000_categorization_rule_enums.sql
--
--  Neue Werte für Kategorisierungsregeln. Eigene Migration, weil neue
--  Enum-Werte erst nach dem Commit verwendet werden dürfen; die Regeln
--  selbst folgen in 20261007100100_categorization_layers.sql.
--
--  rule_match_field
--    transaction_type   – Transaktionstyp/Buchungsart (z. B. „Zinszahlung“)
--    counterparty_iban  – IBAN des Gegenkontos
--    description        – Beschreibung (nur bei Dateien, die sie zusätzlich
--                         zum Verwendungszweck liefern)
--    any_text           – Empfänger, Verwendungszweck, Beschreibung und
--                         Transaktionstyp
--  rule_match_type
--    word               – ganzes Wort bzw. ganze Wortfolge im normalisierten
--                         Text („aldi“ trifft „ALDI SUED“, aber nicht „Waldi“)
-- =====================================================================

begin;

alter type public.rule_match_field add value if not exists 'transaction_type';
alter type public.rule_match_field add value if not exists 'counterparty_iban';
alter type public.rule_match_field add value if not exists 'description';
alter type public.rule_match_field add value if not exists 'any_text';
alter type public.rule_match_type  add value if not exists 'word';

commit;
