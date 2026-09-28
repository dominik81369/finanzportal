-- =====================================================================
--  supabase/tests/finance_model.test.sql
--  Phase 3 · Erweitertes Datenmodell (Migration 20260929000000)
--  Ausführen: supabase test db   (setzt 00000-test-helpers.sql voraus)
--
--  Identitäten
--    fm_alice – Mandantin A
--    fm_bob   – Mandant B
--    fm_carol – Beraterin, aktiv mit Alice verbunden
--
--  Feste Test-IDs (Präfix a1… Alice, b2… Bob)
--    …01 Konto   …02 Kategorie   …03 Transaktion   …04 Tag
--    …05 Budget  …06 Vertrag     …07 Regel
-- =====================================================================

begin;

select plan(39);

select tests.create_supabase_user('fm_alice', 'fm-alice@example.test');
select tests.create_supabase_user('fm_bob',   'fm-bob@example.test');
select tests.create_supabase_user('fm_carol', 'fm-carol@example.test');

-- ---------------------------------------------------------------------
-- Testdaten als service_role
-- ---------------------------------------------------------------------
select tests.authenticate_as_service_role();

update public.profiles set role = 'advisor' where user_id = tests.get_supabase_uid('fm_carol');

insert into public.advisor_clients (advisor_id, user_id, status, invited_email, accepted_at) values
  (tests.get_supabase_uid('fm_carol'), tests.get_supabase_uid('fm_alice'), 'active', 'fm-alice@example.test', now());

insert into public.accounts (id, user_id, name, type) values
  ('a1f00000-0000-4000-8000-000000000001', tests.get_supabase_uid('fm_alice'), 'Alice Giro', 'checking'),
  ('b2f00000-0000-4000-8000-000000000001', tests.get_supabase_uid('fm_bob'),   'Bob Giro',   'checking');

insert into public.categories (id, user_id, name, kind) values
  ('a1f00000-0000-4000-8000-000000000002', tests.get_supabase_uid('fm_alice'), 'Alice Haushalt', 'expense'),
  ('b2f00000-0000-4000-8000-000000000002', tests.get_supabase_uid('fm_bob'),   'Bob Haushalt',   'expense');

insert into public.transactions (id, user_id, account_id, booking_date, amount, counterparty_name) values
  ('a1f00000-0000-4000-8000-000000000003', tests.get_supabase_uid('fm_alice'),
   'a1f00000-0000-4000-8000-000000000001', date '2026-09-01', -12.99, 'Streaming GmbH'),
  ('b2f00000-0000-4000-8000-000000000003', tests.get_supabase_uid('fm_bob'),
   'b2f00000-0000-4000-8000-000000000001', date '2026-09-01', -30.00, 'Fitnessstudio');

insert into public.tags (id, user_id, name) values
  ('a1f00000-0000-4000-8000-000000000004', tests.get_supabase_uid('fm_alice'), 'Urlaub');

-- ---------------------------------------------------------------------
-- 1. Schema-Grundlagen (1–7)
-- ---------------------------------------------------------------------
select tests.rls_enabled('public', 'tags');
select tests.rls_enabled('public', 'transaction_tags');
select tests.rls_enabled('public', 'budgets');
select tests.rls_enabled('public', 'recurring_contracts');
select tests.rls_enabled('public', 'categorization_rules');
select has_column('public', 'categories', 'parent_category_id', 'categories.parent_category_id vorhanden');
select is(
  (select source::text from public.transactions where id = 'a1f00000-0000-4000-8000-000000000003'),
  'manual',
  'transactions.source ist standardmäßig manual'
);

-- ---------------------------------------------------------------------
-- 2. anon (8)
-- ---------------------------------------------------------------------
select tests.clear_authentication();
select throws_ok('select 1 from public.tags', '42501', null, 'anon hat keinen Zugriff auf tags');

-- ---------------------------------------------------------------------
-- 3. Alice legt ihre Daten an (9–19)
-- ---------------------------------------------------------------------
select tests.authenticate_as('fm_alice');

select throws_ok(
  $$ insert into public.tags (name) values ('urlaub') $$,
  '23505', null,
  'Tag-Namen sind je Mandant eindeutig (ohne Groß-/Kleinschreibung)'
);

select lives_ok(
  $$ insert into public.transaction_tags (transaction_id, tag_id)
     values ('a1f00000-0000-4000-8000-000000000003', 'a1f00000-0000-4000-8000-000000000004') $$,
  'Eigene Transaktion mit eigenem Tag verknüpfen'
);

select throws_ok(
  $$ update public.transaction_tags set created_at = now() $$,
  '42501', null,
  'transaction_tags ist nicht änderbar (nur anlegen/löschen)'
);

select lives_ok(
  $$ insert into public.categories (name, kind, parent_category_id)
     values ('Streaming', 'expense', 'a1f00000-0000-4000-8000-000000000002') $$,
  'Unterkategorie unter eigener Oberkategorie'
);

select lives_ok(
  $$ insert into public.budgets (id, name, category_id, amount)
     values ('a1f00000-0000-4000-8000-000000000005', 'Haushalt', 'a1f00000-0000-4000-8000-000000000002', 400) $$,
  'Budget für eigene Kategorie'
);

select throws_ok(
  $$ insert into public.budgets (name, category_id, tag_id, amount)
     values ('Doppelt', 'a1f00000-0000-4000-8000-000000000002', 'a1f00000-0000-4000-8000-000000000004', 100) $$,
  '23514', null,
  'Budget mit zwei Bezugsgrößen wird abgelehnt'
);

select throws_ok(
  $$ insert into public.budgets (name, amount) values ('Ohne Bezug', 100) $$,
  '23514', null,
  'Budget ohne Bezugsgröße wird abgelehnt'
);

select throws_ok(
  $$ insert into public.budgets (name, tag_id, amount)
     values ('Negativ', 'a1f00000-0000-4000-8000-000000000004', -5) $$,
  '23514', null,
  'Budget-Obergrenze muss positiv sein'
);

select lives_ok(
  $$ insert into public.recurring_contracts
       (id, name, counterparty_name, account_id, expected_amount, notice_period_days, term_end_date, status)
     values ('a1f00000-0000-4000-8000-000000000006', 'Streaming-Abo', 'Streaming GmbH',
             'a1f00000-0000-4000-8000-000000000001', -12.99, 30, date '2027-01-31', 'active') $$,
  'Vertrag anlegen'
);

select is(
  (select cancellation_deadline from public.recurring_contracts where id = 'a1f00000-0000-4000-8000-000000000006'),
  date '2027-01-01',
  'cancellation_deadline = term_end_date − notice_period_days'
);

select throws_ok(
  $$ insert into public.recurring_contracts (name, detection_source, detection_confidence)
     values ('Manuell mit Konfidenz', 'manual', 0.9) $$,
  '23514', null,
  'detection_confidence nur bei automatisch erkannten Verträgen'
);

-- ---------------------------------------------------------------------
-- 4. Transaktionsgruppe eines Vertrags (20–21)
-- ---------------------------------------------------------------------
update public.transactions
   set recurring_contract_id = 'a1f00000-0000-4000-8000-000000000006'
 where id = 'a1f00000-0000-4000-8000-000000000003';

select is(
  (select count(*)::int from public.transactions
    where recurring_contract_id = 'a1f00000-0000-4000-8000-000000000006'),
  1,
  'Transaktion gehört zur Gruppe des Vertrags'
);

-- ---------------------------------------------------------------------
-- 5. Kategorisierungsregeln (21–23)
-- ---------------------------------------------------------------------
select lives_ok(
  $$ insert into public.categorization_rules (id, category_id, match_field, match_type, pattern)
     values ('a1f00000-0000-4000-8000-000000000007', 'a1f00000-0000-4000-8000-000000000002',
             'counterparty', 'regex', '^(REWE|EDEKA)\b') $$,
  'Regel mit gültigem regulären Ausdruck'
);

select throws_ok(
  $$ insert into public.categorization_rules (category_id, match_type, pattern)
     values ('a1f00000-0000-4000-8000-000000000002', 'regex', '(unbalanciert') $$,
  '22023', null,
  'Ungültiger regulärer Ausdruck wird abgelehnt'
);

select throws_ok(
  $$ update public.categorization_rules set pattern = '[kaputt'
      where id = 'a1f00000-0000-4000-8000-000000000007' $$,
  '22023', null,
  'Auch beim Ändern wird der reguläre Ausdruck geprüft'
);

-- ---------------------------------------------------------------------
-- 6. Mandantentrennung: Bob (24–33)
-- ---------------------------------------------------------------------
select tests.authenticate_as('fm_bob');

select is_empty($$ select 1 from public.tags $$,                 'Bob sieht keine fremden Tags');
select is_empty($$ select 1 from public.transaction_tags $$,     'Bob sieht keine fremden Tag-Zuordnungen');
select is_empty($$ select 1 from public.budgets $$,              'Bob sieht keine fremden Budgets');
select is_empty($$ select 1 from public.recurring_contracts $$,  'Bob sieht keine fremden Verträge');
select is_empty($$ select 1 from public.categorization_rules $$, 'Bob sieht keine fremden Regeln');

select throws_ok(
  $$ insert into public.transaction_tags (transaction_id, tag_id)
     values ('b2f00000-0000-4000-8000-000000000003', 'a1f00000-0000-4000-8000-000000000004') $$,
  '23503', null,
  'Eigene Transaktion mit fremdem Tag verknüpfen scheitert am zusammengesetzten FK'
);

select throws_ok(
  $$ insert into public.budgets (name, category_id, amount)
     values ('Fremd', 'a1f00000-0000-4000-8000-000000000002', 100) $$,
  '23503', null,
  'Budget auf fremde Kategorie scheitert am zusammengesetzten FK'
);

select throws_ok(
  $$ insert into public.categories (name, kind, parent_category_id)
     values ('Fremd-Unterkategorie', 'expense', 'a1f00000-0000-4000-8000-000000000002') $$,
  '23503', null,
  'Unterkategorie unter fremder Oberkategorie scheitert'
);

select throws_ok(
  $$ update public.transactions set recurring_contract_id = 'a1f00000-0000-4000-8000-000000000006'
      where id = 'b2f00000-0000-4000-8000-000000000003' $$,
  '23503', null,
  'Eigene Transaktion einem fremden Vertrag zuordnen scheitert'
);

select throws_ok(
  format(
    $$ insert into public.tags (user_id, name) values (%L, 'Untergeschoben') $$,
    tests.get_supabase_uid('fm_alice')
  ),
  '42501', null,
  'Tag im Namen eines anderen Mandanten anlegen verstößt gegen RLS'
);

-- ---------------------------------------------------------------------
-- 7. Beraterin: nur lesen (34–37)
-- ---------------------------------------------------------------------
select tests.authenticate_as('fm_carol');

select isnt_empty($$ select 1 from public.budgets $$,             'Beraterin sieht Budgets ihrer Mandantin');
select isnt_empty($$ select 1 from public.recurring_contracts $$, 'Beraterin sieht Verträge ihrer Mandantin');

with changed as (
  update public.budgets set amount = 1
   where id = 'a1f00000-0000-4000-8000-000000000005'
  returning 1
)
select is(count(*)::int, 0, 'Beraterin kann Budgets der Mandantin nicht ändern') from changed;

select throws_ok(
  format(
    $$ insert into public.tags (user_id, name) values (%L, 'Vom Berater') $$,
    tests.get_supabase_uid('fm_alice')
  ),
  '42501', null,
  'Beraterin kann keine Tags für die Mandantin anlegen'
);

-- ---------------------------------------------------------------------
-- 8. Löschverhalten (38–39)
-- ---------------------------------------------------------------------
select tests.authenticate_as('fm_alice');

delete from public.recurring_contracts where id = 'a1f00000-0000-4000-8000-000000000006';
select is(
  (select recurring_contract_id from public.transactions where id = 'a1f00000-0000-4000-8000-000000000003'),
  null,
  'Vertrag löschen: Transaktion bleibt, Zuordnung wird entfernt'
);

delete from public.tags where id = 'a1f00000-0000-4000-8000-000000000004';
select is_empty(
  $$ select 1 from public.transaction_tags where tag_id = 'a1f00000-0000-4000-8000-000000000004' $$,
  'Tag löschen entfernt seine Zuordnungen'
);

select * from finish();

rollback;
