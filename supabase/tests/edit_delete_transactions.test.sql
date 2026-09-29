-- =====================================================================
--  supabase/tests/edit_delete_transactions.test.sql
--  Manuelle Buchungen bearbeiten und löschen (Migration 20261002000000)
--  Ausführen: supabase test db   (setzt 00000-test-helpers.sql voraus)
--
--  Identitäten
--    ed_alice – Mandantin
--    ed_bob   – anderer Mandant
--    ed_carol – Beraterin, aktiv mit Alice verbunden
--
--  Feste Test-IDs (Präfix e1… Alice)
--    …01 Konto EUR   …02 Ausgaben-Kategorie   …03 Einnahmen-Kategorie
--    …04 Tag „Alt“   …05 Tag „Bleibt“   …06 importierte Buchung
-- =====================================================================

begin;

select plan(28);

select tests.create_supabase_user('ed_alice', 'ed-alice@example.test');
select tests.create_supabase_user('ed_bob',   'ed-bob@example.test');
select tests.create_supabase_user('ed_carol', 'ed-carol@example.test');

select tests.authenticate_as_service_role();

update public.profiles set role = 'advisor' where user_id = tests.get_supabase_uid('ed_carol');
insert into public.advisor_clients (advisor_id, user_id, status, invited_email, accepted_at) values
  (tests.get_supabase_uid('ed_carol'), tests.get_supabase_uid('ed_alice'), 'active', 'ed-alice@example.test', now());

insert into public.accounts (id, user_id, name, type) values
  ('e1e00000-0000-4000-8000-000000000001', tests.get_supabase_uid('ed_alice'), 'Giro', 'checking');
insert into public.categories (id, user_id, name, kind) values
  ('e1e00000-0000-4000-8000-000000000002', tests.get_supabase_uid('ed_alice'), 'Haushalt', 'expense'),
  ('e1e00000-0000-4000-8000-000000000003', tests.get_supabase_uid('ed_alice'), 'Bonus',    'income');
insert into public.tags (id, user_id, name) values
  ('e1e00000-0000-4000-8000-000000000004', tests.get_supabase_uid('ed_alice'), 'Alt'),
  ('e1e00000-0000-4000-8000-000000000005', tests.get_supabase_uid('ed_alice'), 'Bleibt');
insert into public.transactions (id, user_id, account_id, booking_date, amount, counterparty_name, source, import_hash) values
  ('e1e00000-0000-4000-8000-000000000006', tests.get_supabase_uid('ed_alice'),
   'e1e00000-0000-4000-8000-000000000001', date '2026-09-01', -99, 'Importiert', 'csv_import', repeat('a', 64));

-- ---------------------------------------------------------------------
-- 1. Rechte (1–5)
-- ---------------------------------------------------------------------
select function_privs_are('public', 'update_manual_transaction',
  array['uuid', 'date', 'numeric', 'text', 'text', 'uuid', 'uuid', 'uuid[]', 'text[]', 'text'],
  'authenticated', array['EXECUTE'], 'authenticated darf update_manual_transaction ausführen');
select function_privs_are('public', 'update_manual_transaction',
  array['uuid', 'date', 'numeric', 'text', 'text', 'uuid', 'uuid', 'uuid[]', 'text[]', 'text'],
  'anon', array[]::text[], 'anon darf update_manual_transaction nicht ausführen');
select function_privs_are('public', 'delete_manual_transaction', array['uuid'],
  'authenticated', array['EXECUTE'], 'authenticated darf delete_manual_transaction ausführen');
select function_privs_are('public', 'delete_manual_transaction', array['uuid'],
  'anon', array[]::text[], 'anon darf delete_manual_transaction nicht ausführen');
select is(
  (select bool_and(not prosecdef) from pg_proc
    where proname in ('save_manual_transaction', 'create_manual_transaction',
                      'update_manual_transaction', 'delete_manual_transaction')),
  true,
  'Alle Funktionen laufen als SECURITY INVOKER (RLS gilt)'
);

-- ---------------------------------------------------------------------
-- 2. Alice legt an und bearbeitet (6–13)
-- ---------------------------------------------------------------------
select tests.authenticate_as('ed_alice');

create temporary table tx (label text primary key, id uuid) on commit drop;
insert into tx
select 'main', public.create_manual_transaction(
  date '2026-09-10', -20, 'Markt', 'Einkauf', 'e1e00000-0000-4000-8000-000000000001',
  'e1e00000-0000-4000-8000-000000000002',
  array['e1e00000-0000-4000-8000-000000000004', 'e1e00000-0000-4000-8000-000000000005']::uuid[]);

select is(
  (select count(*)::int from public.transaction_tags where transaction_id = (select id from tx where label = 'main')),
  2, 'Ausgangslage: Buchung mit zwei Tags'
);

select is(
  public.update_manual_transaction(
    (select id from tx where label = 'main'),
    date '2026-09-12', 150.5, '  Arbeitgeber ', null, 'e1e00000-0000-4000-8000-000000000001',
    'e1e00000-0000-4000-8000-000000000003',
    array['e1e00000-0000-4000-8000-000000000005']::uuid[], array['Neu'], 'USD'),
  (select id from tx where label = 'main'),
  'update_manual_transaction liefert die ID der Buchung'
);

select results_eq(
  $$ select booking_date, amount, counterparty_name, purpose, category_id, currency::text,
            categorization_source::text, source::text
       from public.transactions where id = (select id from tx where label = 'main') $$,
  $$ values (date '2026-09-12', 150.50::numeric(14,2), 'Arbeitgeber', null::text,
             'e1e00000-0000-4000-8000-000000000003'::uuid, 'USD', 'manual', 'manual') $$,
  'Felder übernommen (Datum, Betrag, getrimmter Empfänger, leerer Zweck, Kategorie, Währung)'
);

select set_eq(
  $$ select tg.name from public.transaction_tags tt join public.tags tg on tg.id = tt.tag_id
      where tt.transaction_id = (select id from tx where label = 'main') $$,
  array['Bleibt', 'Neu'],
  'Tag-Auswahl ersetzt: „Alt“ gelöst, „Bleibt“ behalten, „Neu“ angelegt'
);

select is(
  (select count(*)::int from public.tags where name = 'Alt'),
  1,
  'Der gelöste Tag selbst bleibt bestehen'
);

select lives_ok(
  $$ select public.update_manual_transaction(
       (select id from tx where label = 'main'),
       date '2026-09-12', -5, 'Bäcker', null, null, null) $$,
  'Bearbeiten ohne Konto, Kategorie und Tags'
);

select results_eq(
  $$ select a.name, t.category_id, t.categorization_source::text,
            (select count(*)::int from public.transaction_tags tt where tt.transaction_id = t.id)
       from public.transactions t join public.accounts a on a.id = t.account_id
      where t.id = (select id from tx where label = 'main') $$,
  $$ values ('Bargeld', null::uuid, null::text, 0) $$,
  'Ohne Konto → Bargeld-Konto; Kategorie und Tags entfernt'
);

select throws_ok(
  $$ select public.update_manual_transaction(
       (select id from tx where label = 'main'),
       date '2026-09-12', 10, 'X', null, 'e1e00000-0000-4000-8000-000000000001',
       'e1e00000-0000-4000-8000-000000000002') $$,
  '22023', 'category_kind_mismatch', 'Prüfungen gelten auch beim Bearbeiten (Kategorieart)'
);

-- ---------------------------------------------------------------------
-- 3. Nicht bearbeitbar / nicht vorhanden (14–17)
-- ---------------------------------------------------------------------
select throws_ok(
  $$ select public.update_manual_transaction('e1e00000-0000-4000-8000-000000000006',
       date '2026-09-01', -1, 'X') $$,
  '22023', 'transaction_not_editable', 'Importierte Buchung ist nicht bearbeitbar'
);
select throws_ok(
  $$ select public.delete_manual_transaction('e1e00000-0000-4000-8000-000000000006') $$,
  '22023', 'transaction_not_editable', 'Importierte Buchung ist nicht löschbar'
);
select throws_ok(
  $$ select public.update_manual_transaction(null, date '2026-09-01', -1, 'X') $$,
  'P0002', 'transaction_not_found', 'update ohne ID → transaction_not_found'
);
select throws_ok(
  $$ select public.update_manual_transaction(gen_random_uuid(), date '2026-09-01', -1, 'X') $$,
  'P0002', 'transaction_not_found', 'Unbekannte ID → transaction_not_found'
);

-- ---------------------------------------------------------------------
-- 4. Bob und Beraterin Carol: keine Änderungen an Alices Buchung (18–23)
-- ---------------------------------------------------------------------
create temporary table main_id on commit drop as select id from tx where label = 'main';
grant select on main_id to authenticated;

select tests.authenticate_as('ed_bob');
select throws_ok(
  $$ select public.update_manual_transaction((select id from main_id), date '2026-09-01', -1, 'Bob') $$,
  'P0002', 'transaction_not_found', 'Bob kann Alices Buchung nicht bearbeiten'
);
select throws_ok(
  $$ select public.delete_manual_transaction((select id from main_id)) $$,
  'P0002', 'transaction_not_found', 'Bob kann Alices Buchung nicht löschen'
);

select tests.authenticate_as('ed_carol');
select is(
  (select counterparty_name from public.transactions where id = (select id from main_id)),
  'Bäcker',
  'Beraterin sieht die Buchung (Lesen erlaubt)'
);
select throws_ok(
  $$ select public.update_manual_transaction((select id from main_id), date '2026-09-01', -1, 'Carol') $$,
  'P0002', 'transaction_not_found', 'Beraterin kann Mandantenbuchung nicht bearbeiten'
);
select throws_ok(
  $$ select public.delete_manual_transaction((select id from main_id)) $$,
  'P0002', 'transaction_not_found', 'Beraterin kann Mandantenbuchung nicht löschen'
);

select tests.authenticate_as('ed_alice');
select results_eq(
  $$ select counterparty_name, amount from public.transactions where id = (select id from main_id) $$,
  $$ values ('Bäcker', -5.00::numeric(14,2)) $$,
  'Alices Buchung ist unverändert'
);

-- ---------------------------------------------------------------------
-- 5. Löschen (24–26)
-- ---------------------------------------------------------------------
select public.update_manual_transaction((select id from main_id), date '2026-09-12', -5, 'Bäcker',
  null, null, null, array['e1e00000-0000-4000-8000-000000000005']::uuid[]);

select lives_ok(
  $$ select public.delete_manual_transaction((select id from main_id)) $$,
  'Alice löscht ihre manuelle Buchung'
);
select is(
  (select count(*)::int from public.transactions where id = (select id from main_id))
  + (select count(*)::int from public.transaction_tags where transaction_id = (select id from main_id)),
  0,
  'Buchung und Tag-Zuordnungen sind weg'
);
select throws_ok(
  $$ select public.delete_manual_transaction((select id from main_id)) $$,
  'P0002', 'transaction_not_found', 'Zweites Löschen → transaction_not_found'
);

-- ---------------------------------------------------------------------
-- 6. anon (27–28)
-- ---------------------------------------------------------------------
select tests.clear_authentication();
select throws_ok(
  $$ select public.delete_manual_transaction(gen_random_uuid()) $$,
  '42501', null, 'anon: kein Ausführungsrecht für delete'
);
reset role;
select throws_ok(
  $$ select public.delete_manual_transaction(gen_random_uuid()) $$,
  '42501', 'not_authenticated', 'Ohne angemeldeten Nutzer bricht delete ab'
);

select * from finish();
rollback;
