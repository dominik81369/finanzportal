-- =====================================================================
--  20261016100000_pdf_import_enums.sql
--  PDF-Import (N26): neue Buchungsquelle. Eigene Migration, weil neue
--  Enum-Werte erst nach dem Commit verwendbar sind
--  (siehe 20261016100100_pdf_import.sql).
-- =====================================================================

alter type public.transaction_source add value if not exists 'pdf_import';
