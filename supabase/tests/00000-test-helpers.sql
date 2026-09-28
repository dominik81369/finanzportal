-- =====================================================================
--  supabase/tests/00000-test-helpers.sql
--  Globales Test-Setup · läuft als erste Datei (alphabetische Reihenfolge)
--
--  Installiert pgTAP und die basejump-Test-Helper (Schema `tests`) aus der
--  im Repository abgelegten Kopie supabase/tests/vendor/ – ohne
--  Netzwerkzugriff. Die Objekte bleiben in der LOKALEN Testdatenbank
--  bestehen, damit alle folgenden Testdateien sie nutzen können.
--
--  Früher wurden die Helper zur Laufzeit per dbdev (http + pg_tle) von
--  api.database.dev geladen; ein Verbindungsabbruch ließ dann alle Tests
--  ohne eine einzige Assertion scheitern.
--
--  ACHTUNG: Nur lokal ausführen (`supabase test db`). Niemals mit `--linked`
--  gegen die Produktionsdatenbank – dort würden Test-Helper dauerhaft
--  installiert, die Rollen- und JWT-Kontext beliebig umschalten können.
-- =====================================================================

-- Abbruch beim ersten Fehler: Ohne Helper sind alle weiteren Tests wertlos.
\set ON_ERROR_STOP on

-- 1) pgTAP (wird von den Helpern vorausgesetzt)
create extension if not exists pgtap with schema extensions;

-- 2) Altbestand aus der früheren dbdev-Installation entfernen, falls die
--    lokale Datenbank noch nicht neu aufgesetzt wurde. Die Helper-Funktionen
--    gehörten dort zur Extension und würden sonst mit der Kopie kollidieren.
drop extension if exists "basejump-supabase_test_helpers";
drop extension if exists "supabase-dbdev";

-- 3) basejump-supabase_test_helpers 0.0.6 aus der lokalen Kopie
\ir vendor/basejump-supabase_test_helpers--0.0.6.psql

-- 4) Basis-Test: verifiziert, dass Setup und pgTAP verfügbar sind
begin;

select plan(1);
select ok(true, 'Setup erfolgreich');
select * from finish();

rollback;
