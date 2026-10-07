-- =====================================================================
--  20261007120000_categorization_a2_enums.sql
--
--  Neuer Vergleich für Kategorisierungsregeln. Eigene Migration, weil
--  neue Enum-Werte erst nach dem Commit verwendet werden dürfen; die
--  Regeln selbst folgen in 20261007120100_categorization_a2.sql.
--
--  rule_match_type
--    all_words – alle Wörter des Musters kommen als ganze Wörter vor, in
--                beliebiger Reihenfolge („dominik mustermann“ trifft
--                „MUSTERMANN, DOMINIK MAXIMILIAN“)
-- =====================================================================

begin;

alter type public.rule_match_type add value if not exists 'all_words';

commit;
