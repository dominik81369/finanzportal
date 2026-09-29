-- =====================================================================
--  supabase/tests/manual_transactions.test.sql
--  Phase 3 · Manuelle Transaktionserfassung (Migration 20260930000000)
--  Ausführen: supabase test db   (setzt 00000-test-helpers.sql voraus)
--
--  Identitäten
--    mt_alice – Mandantin A
--    mt_bob   – Mandant B
--    mt_carol – Beraterin, aktiv mit Alice verbunden
--
--  Feste Test-IDs (Präfix a1… Alice, b2… Bob)
--    …01 Konto   …02 Ausgaben-Kategorie   …03 Einnahmen-Kategorie
--    …04 Umbuchungs-Kategorie   …05 Tag   …06 archiviertes Konto
-- =====================================================================

begin;

select plan(32);

select tests.create_supabase_user('mt_alice', 'mt-alice@example.test');
select tests.create_supabase_user('mt_bob',   'mt-bob@example.test');
select tests.create_supabase_user('mt_carol', 'mt-carol@example.test');

-- ---------------------------------------------------------------------
-- Testdaten als service_role
-- ---------------------------------------------------------------------
select tests.authenticate_as_service_role();

update public.profiles set role = 'advisor' where user_id = tests.get_supabase_uid('mt_carol');

insert into public.advisor_clients (advisor_id, user_id, status, invited_email, accepted_at) values
  (tests.get_supabase_uid('mt_carol'), tests.get_supabase_uid('mt_alice'), 'active', 'mt-alice@example.test', now());

insert into public.accounts (id, user_id, name, type, currency, archived_at) values
  ('a1e00000-0000-4000-8000-000000000001', tests.get_supabase_uid('mt_alice'), 'Alice Giro',  'checking', 'EUR', null),
  ('a1e00000-0000-4000-8000-000000000006', tests.get_supabase_uid('mt_alice'), 'Alice Alt',   'checking', 'EUR', now()),
  ('b2e00000-0000-4000-8000-000000000001', tests.get_supabase_uid('mt_bob'),   'Bob Giro',    'checking', 'EUR', null);

insert into public.categories (id, user_id, name, kind) values
  ('a1e00000-0000-4000-8000-000000000002', tests.get_supabase_uid('mt_alice'), 'Alice Haushalt', 'expense'),
  ('a1e00000-0000-4000-8000-000000000003', tests.get_supabase_uid('mt_alice'), 'Alice Bonus',    'income'),
  ('a1e00000-0000-4000-8000-000000000004', tests.get_supabase_uid('mt_alice'), 'Alice Umbuchen', 'transfer'),
  ('b2e00000-0000-4000-8000-000000000002', tests.get_supabase_uid('mt_bob'),   'Bob Haushalt',   'expense');

insert into public.tags (id, user_id, name) values
  ('a1e00000-0000-4000-8000-000000000005', tests.get_supabase_uid('mt_alice'), 'Urlaub'),
  ('b2e00000-0000-4000-8000-000000000005', tests.get_supabase_uid('mt_bob'),   'Bob-Tag');

-- ---------------------------------------------------------------------
-- 1. Rechte (1–3)
-- ---------------------------------------------------------------------
select function_privs_are(
  'public', 'create_manual_transaction',
  array['date', 'numeric', 'text', 'text', 'uuid', 'uuid', 'uuid[]', 'text[]', 'text'],
  'anon', array[]::text[],
  'anon darf create_manual_transaction nicht ausführen'
);
select function_privs_are(
  'public', 'create_manual_transaction',
  array['date', 'numeric', 'text', 'text', 'uuid', 'uuid', 'uuid[]', 'text[]', 'text'],
  'authenticated', array['EXECUTE'],
  'authenticated darf create_manual_transaction ausführen'
);
select is(
  (select prosecdef from pg_proc where proname = 'create_manual_transaction'),
  false,
  'create_manual_transaction läuft als SECURITY INVOKER (RLS gilt)'
);

-- ---------------------------------------------------------------------
-- 2. Alice: erfolgreiche Erfassung mit Kategorie und Tags (4–13)
-- ---------------------------------------------------------------------
select tests.authenticate_as('mt_alice');

create temporary table created (id uuid) on commit drop;
grant all on created to authenticated;

select lives_ok(
  $$ insert into created
     select public.create_manual_transaction(
       date '2026-09-15', -42.50, '  Supermarkt Müller ', 'Wocheneinkauf',
       'a1e00000-0000-4000-8000-000000000001', 'a1e00000-0000-4000-8000-000000000002',
       array['a1e00000-0000-4000-8000-000000000005']::uuid[],
       array['Familie', ' familie ', 'URLAUB', '']
     ) $$,
  'Ausgabe mit Kategorie, bestehendem und neuen Tags wird angelegt'
);

select results_eq(
  $$ select t.amount, t.booking_date, t.counterparty_name, t.purpose, t.source::text,
            t.categorization_source::text, t.category_id, t.account_id, t.currency::text
       from public.transactions t join created c on c.id = t.id $$,
  $$ values (-42.50::numeric(14,2), date '2026-09-15', 'Supermarkt Müller', 'Wocheneinkauf', 'manual',
            'manual', 'a1e00000-0000-4000-8000-000000000002'::uuid,
            'a1e00000-0000-4000-8000-000000000001'::uuid, 'EUR') $$,
  'Buchung: Betrag, Datum, getrimmter Empfänger, Quelle manual, Kategorie manuell gesetzt'
);

select set_eq(
  $$ select lower(tg.name) from public.transaction_tags tt
       join public.tags tg on tg.id = tt.tag_id
       join created c on c.id = tt.transaction_id $$,
  array['urlaub', 'familie'],
  'Tags: bestehender Tag wiederverwendet, neue Namen ohne Duplikate (Groß-/Kleinschreibung, Leerzeichen)'
);

select is(
  (select count(*)::int from public.tags where user_id = tests.get_supabase_uid('mt_alice')),
  2,
  'Nur ein neuer Tag angelegt ("Familie"); "URLAUB" nutzt den vorhandenen "Urlaub"'
);

select lives_ok(
  $$ select public.create_manual_transaction(
       date '2026-09-16', 1500, 'Arbeitgeber', null,
       'a1e00000-0000-4000-8000-000000000001', 'a1e00000-0000-4000-8000-000000000003') $$,
  'Einnahme mit Einnahmen-Kategorie wird angelegt'
);

select lives_ok(
  $$ select public.create_manual_transaction(
       date '2026-09-16', -200, 'Tagesgeld', null,
       'a1e00000-0000-4000-8000-000000000001', 'a1e00000-0000-4000-8000-000000000004') $$,
  'Umbuchungs-Kategorie ist für Ausgaben zulässig'
);

select lives_ok(
  $$ select public.create_manual_transaction(date '2026-09-17', -3.20, 'Bäcker') $$,
  'Ohne Konto, Kategorie und Tags wird angelegt'
);

select results_eq(
  $$ select a.name, a.type::text, a.provider::text from public.accounts a
      where a.user_id = auth.uid() and a.type = 'cash' $$,
  $$ values ('Bargeld', 'cash', 'manual') $$,
  'Ohne Konto: manuelles Bargeld-Konto wird angelegt'
);

select lives_ok(
  $$ select public.create_manual_transaction(date '2026-09-18', -1.10, 'Kiosk') $$,
  'Zweite Erfassung ohne Konto'
);

select is(
  (select count(*)::int from public.accounts where user_id = auth.uid() and type = 'cash'),
  1,
  'Bargeld-Konto wird wiederverwendet, nicht erneut angelegt'
);

-- ---------------------------------------------------------------------
-- 3. Alice: ungültige Eingaben (14–23)
-- ---------------------------------------------------------------------
select throws_ok(
  $$ select public.create_manual_transaction(date '2026-09-15', 0, 'X') $$,
  '22023', 'invalid_amount', 'Betrag 0 wird abgelehnt'
);
select throws_ok(
  $$ select public.create_manual_transaction(date '2026-09-15', -1.005, 'X') $$,
  '22023', 'invalid_amount', 'Mehr als zwei Nachkommastellen werden abgelehnt'
);
select throws_ok(
  $$ select public.create_manual_transaction(null, -1, 'X') $$,
  '22023', 'invalid_booking_date', 'Fehlendes Buchungsdatum wird abgelehnt'
);
select throws_ok(
  $$ select public.create_manual_transaction(date '2026-09-15', 10, 'X', null,
       'a1e00000-0000-4000-8000-000000000001', 'a1e00000-0000-4000-8000-000000000002') $$,
  '22023', 'category_kind_mismatch', 'Einnahme mit Ausgaben-Kategorie wird abgelehnt'
);
select throws_ok(
  $$ select public.create_manual_transaction(date '2026-09-15', -10, 'X', null,
       'a1e00000-0000-4000-8000-000000000001', 'a1e00000-0000-4000-8000-000000000003') $$,
  '22023', 'category_kind_mismatch', 'Ausgabe mit Einnahmen-Kategorie wird abgelehnt'
);
select throws_ok(
  $$ select public.create_manual_transaction(date '2026-09-15', -10, 'X', null,
       'a1e00000-0000-4000-8000-000000000006') $$,
  'P0002', 'account_not_found', 'Archiviertes Konto wird abgelehnt'
);
select throws_ok(
  $$ select public.create_manual_transaction(date '2026-09-15', -10, 'X', null,
       'b2e00000-0000-4000-8000-000000000001') $$,
  'P0002', 'account_not_found', 'Fremdes Konto (Bob) wird abgelehnt'
);
select throws_ok(
  $$ select public.create_manual_transaction(date '2026-09-15', -10, 'X', null,
       'a1e00000-0000-4000-8000-000000000001', 'b2e00000-0000-4000-8000-000000000002') $$,
  'P0002', 'category_not_found', 'Fremde Kategorie (Bob) wird abgelehnt'
);
select throws_ok(
  $$ select public.create_manual_transaction(date '2026-09-15', -10, 'X', null,
       'a1e00000-0000-4000-8000-000000000001', null,
       array['b2e00000-0000-4000-8000-000000000005']::uuid[]) $$,
  'P0002', 'tag_not_found', 'Fremder Tag (Bob) wird abgelehnt'
);
select throws_ok(
  $$ select public.create_manual_transaction(date '2026-09-15', -10, 'X', null, null, null, '{}',
       array['t1','t2','t3','t4','t5','t6','t7','t8','t9','t10','t11']) $$,
  '22023', 'too_many_tags', 'Mehr als 10 neue Tags werden abgelehnt'
);

-- ---------------------------------------------------------------------
-- 4. Atomarität (24–25)
-- ---------------------------------------------------------------------
-- Fehler NACH dem Tag-Insert (fremder Tag) → auch der neue Tag ist weg.
select throws_ok(
  $$ select public.create_manual_transaction(date '2026-09-15', -10, 'X', null,
       'a1e00000-0000-4000-8000-000000000001', null,
       array['b2e00000-0000-4000-8000-000000000005']::uuid[], array['Nur-bei-Erfolg']) $$,
  'P0002', 'tag_not_found', 'Fremder Tag zusammen mit neuem Tag wird abgelehnt'
);
select is(
  (select count(*)::int from public.tags where lower(name) = 'nur-bei-erfolg'),
  0,
  'Bei Fehler bleibt kein neuer Tag zurück (eine Transaktion)'
);

-- ---------------------------------------------------------------------
-- 5. Beraterin Carol: liest Alice, schreibt nie für sie (26–28)
-- ---------------------------------------------------------------------
select tests.authenticate_as('mt_carol');

select throws_ok(
  $$ select public.create_manual_transaction(date '2026-09-15', -10, 'X', null,
       'a1e00000-0000-4000-8000-000000000001') $$,
  'P0002', 'account_not_found', 'Beraterin kann nicht auf das Konto der Mandantin buchen'
);
select throws_ok(
  $$ select public.create_manual_transaction(date '2026-09-15', -10, 'X', null, null,
       'a1e00000-0000-4000-8000-000000000002') $$,
  'P0002', 'category_not_found', 'Beraterin kann keine Kategorie der Mandantin verwenden'
);
select is(
  (select count(*)::int from public.transactions where user_id = tests.get_supabase_uid('mt_alice')),
  5,
  'Beraterin sieht die 5 Buchungen der Mandantin (Lesen bleibt erlaubt)'
);

-- ---------------------------------------------------------------------
-- 6. Bob: sieht nichts von Alice (29–30)
-- ---------------------------------------------------------------------
select tests.authenticate_as('mt_bob');

select is(
  (select count(*)::int from public.transactions where user_id = tests.get_supabase_uid('mt_alice')),
  0,
  'Bob sieht keine Buchungen von Alice'
);
select is(
  (select count(*)::int from public.transaction_tags where user_id = tests.get_supabase_uid('mt_alice')),
  0,
  'Bob sieht keine Tag-Zuordnungen von Alice'
);

-- ---------------------------------------------------------------------
-- 7. anon (31–32)
-- ---------------------------------------------------------------------
select tests.clear_authentication();

select throws_ok(
  $$ select public.create_manual_transaction(date '2026-09-15', -10, 'X') $$,
  '42501', null, 'anon: kein Ausführungsrecht'
);

-- Auch mit Recht würde die Funktion ohne auth.uid() abbrechen.
reset role;
select throws_ok(
  $$ select public.create_manual_transaction(date '2026-09-15', -10, 'X') $$,
  '42501', 'not_authenticated', 'Ohne angemeldeten Nutzer bricht die Funktion ab'
);

select * from finish();
rollback;
