-- =====================================================================
--  supabase/tests/00000-test-helpers.sql
--  Globales Test-Setup · läuft als erste Datei (alphabetische Reihenfolge)
--
--  Installiert pgTAP, dbdev (über pg_tle) und basejump-supabase_test_helpers.
--  Die Extensions bleiben in der LOKALEN Testdatenbank bestehen, damit alle
--  folgenden Testdateien sie nutzen können.
--
--  ACHTUNG: Nur lokal ausführen (`supabase test db`). Niemals mit `--linked`
--  gegen die Produktionsdatenbank – dort würden Test-Helper dauerhaft
--  installiert, die Rollen- und JWT-Kontext beliebig umschalten können.
--
--  Quelle Installationsblock: supabase.com/docs/guides/local-development/testing/pgtap-extended
-- =====================================================================

-- 1) Extensions in exakt dieser Reihenfolge
create extension if not exists pgtap with schema extensions;
create extension if not exists http with schema extensions;
create extension if not exists pg_tle;

-- 2) dbdev-Client via pg_tle aus database.dev installieren
--    Der apiKey ist der öffentliche Anon-Key von database.dev (kein Geheimnis).
drop extension if exists "supabase-dbdev";
select pgtle.uninstall_extension_if_exists('supabase-dbdev');

select
  pgtle.install_extension(
    'supabase-dbdev',
    resp.contents ->> 'version',
    'PostgreSQL package manager',
    resp.contents ->> 'sql'
  )
from extensions.http(
  (
    'GET',
    'https://api.database.dev/rest/v1/'
    || 'package_versions?select=sql,version'
    || '&package_name=eq.supabase-dbdev'
    || '&order=version.desc'
    || '&limit=1',
    array[
      (
        'apiKey',
        'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InhtdXB0cHBsZnZpaWZyYndtbXR2Iiwicm9sZSI6ImFub24iLCJpYXQiOjE2ODAxMDczNzIsImV4cCI6MTk5NTY4MzM3Mn0.z2CN0mvO2No8wSi46Gw59DFGCTJrzM0AQKsu_5k134s'
      )::extensions.http_header
    ],
    null,
    null
  )
) x,
lateral (
  select ((row_to_json(x) -> 'content') #>> '{}')::json -> 0
) resp(contents);

create extension "supabase-dbdev";
select dbdev.install('supabase-dbdev');

-- Neu anlegen, damit die zuvor per dbdev aktualisierte Version aktiv ist
drop extension if exists "supabase-dbdev";
create extension "supabase-dbdev";

-- 3) basejump-supabase_test_helpers installieren (Version gepinnt)
select dbdev.install('basejump-supabase_test_helpers');
create extension if not exists "basejump-supabase_test_helpers" version '0.0.6';

-- 4) Basis-Test: verifiziert, dass Setup und pgTAP verfügbar sind
begin;

select plan(1);
select ok(true, 'Setup erfolgreich');
select * from finish();

rollback;
