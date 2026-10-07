-- =====================================================================
--  20261008100000_categorization_b1_enums.sql
--
--  Neue Herkunft einer Kategorie. Eigene Migration, weil neue Enum-Werte
--  erst nach dem Commit verwendet werden dürfen; der Rest folgt in
--  20261008100100_categorization_b1.sql.
--
--  categorization_source
--    learned – gelernt (Gegenpartei-Gedächtnis; später auch Bayes), nie
--              Trainingsgrundlage für weiteres Lernen
-- =====================================================================

begin;

alter type public.categorization_source add value if not exists 'learned';

commit;
