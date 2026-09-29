-- =====================================================================
--  supabase/migrations/20261002130000_transactions_newest_first_index.sql
--  Transaktionsliste: bei gleichem Buchungsdatum die neueste Erfassung oben
--
--  Die Liste sortiert nach booking_date absteigend, created_at absteigend
--  und id aufsteigend (Tiebreaker für Zeilen aus derselben Transaktion,
--  deren created_at identisch ist). Der neue Index liefert genau diese
--  Reihenfolge, damit LIMIT/OFFSET ohne Sortierschritt auskommt.
--
--  Er ersetzt transactions_user_id_booking_date_idx (user_id,
--  booking_date desc, id): Sein Präfix (user_id, booking_date desc) deckt
--  alles ab, wofür der alte Index genutzt wurde; beide zu halten wäre
--  reiner Schreib-Overhead auf der größten Tabelle.
--
--  Hinweis: CREATE INDEX sperrt die Tabelle für Schreibzugriffe, bis der
--  Index gebaut ist (Migrationen laufen in einer Transaktion, CONCURRENTLY
--  ist dort nicht möglich). Bei großen Datenbeständen außerhalb der
--  Nutzungszeiten ausrollen.
--
--  Zeitstempel bewusst nach 20261002120000 (siehe PR #10).
-- =====================================================================

begin;

create index transactions_user_booking_created_idx
  on public.transactions (user_id, booking_date desc, created_at desc, id);

drop index public.transactions_user_id_booking_date_idx;

commit;
