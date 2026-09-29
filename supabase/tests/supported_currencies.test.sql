-- =====================================================================
--  supabase/tests/supported_currencies.test.sql
--  Unterstützte Währungen (Migration 20261001000000)
--  Ausführen: supabase test db   (setzt 00000-test-helpers.sql voraus)
--
--  Identität: cur_alice – Mandantin mit einem EUR- und einem CHF-Konto
--    c1…01 EUR-Konto   c1…02 CHF-Konto
-- =====================================================================

begin;

select plan(12);

select tests.create_supabase_user('cur_alice', 'cur-alice@example.test');

select tests.authenticate_as_service_role();

insert into public.accounts (id, user_id, name, type, currency) values
  ('c1c00000-0000-4000-8000-000000000001', tests.get_supabase_uid('cur_alice'), 'Giro EUR', 'checking', 'EUR'),
  ('c1c00000-0000-4000-8000-000000000002', tests.get_supabase_uid('cur_alice'), 'Konto CH', 'checking', 'CHF');

-- ---------------------------------------------------------------------
-- 1. Domain currency_code (1–5)
-- ---------------------------------------------------------------------
select lives_ok($$ select 'EUR'::public.currency_code $$, 'EUR ist zulässig');
select lives_ok($$ select 'USD'::public.currency_code $$, 'USD ist zulässig');
select lives_ok($$ select 'CHF'::public.currency_code $$, 'CHF ist zulässig');
select throws_ok($$ select 'GBP'::public.currency_code $$, '23514', null, 'GBP ist nicht zulässig');
select throws_ok(
  $$ insert into public.accounts (user_id, name, type, currency)
     values (tests.get_supabase_uid('cur_alice'), 'Konto GBP', 'checking', 'GBP') $$,
  '23514', null,
  'Konto in nicht unterstützter Währung wird abgelehnt'
);

-- ---------------------------------------------------------------------
-- 2. create_manual_transaction(): Originalwährung (6–12)
-- ---------------------------------------------------------------------
select function_privs_are(
  'public', 'create_manual_transaction',
  array['date', 'numeric', 'text', 'text', 'uuid', 'uuid', 'uuid[]', 'text[]', 'text'],
  'authenticated', array['EXECUTE'],
  'authenticated darf die neue Signatur ausführen'
);

select tests.authenticate_as('cur_alice');

create temporary table created (label text, id uuid) on commit drop;

insert into created
select 'chf', public.create_manual_transaction(
  date '2026-10-01', -10, 'Bäckerei', null, 'c1c00000-0000-4000-8000-000000000002');
insert into created
select 'usd', public.create_manual_transaction(
  date '2026-10-01', -49.99, 'Online-Shop', null, 'c1c00000-0000-4000-8000-000000000001',
  null, '{}', '{}', 'USD');

select is(
  (select t.currency::text from public.transactions t join created c on c.id = t.id where c.label = 'chf'),
  'CHF',
  'Ohne p_currency: Währung des Kontos (CHF)'
);

select is(
  (select t.currency::text || '|' || t.amount::text
     from public.transactions t join created c on c.id = t.id where c.label = 'usd'),
  'USD|-49.99',
  'USD-Buchung vom EUR-Konto: Originalbetrag in Originalwährung, keine Umrechnung'
);

select throws_ok(
  $$ select public.create_manual_transaction(date '2026-10-01', -1, 'X', null,
       'c1c00000-0000-4000-8000-000000000001', null, '{}', '{}', 'GBP') $$,
  '22023', 'invalid_currency', 'Nicht unterstützte Währung → invalid_currency'
);
select throws_ok(
  $$ select public.create_manual_transaction(date '2026-10-01', -1, 'X', null,
       'c1c00000-0000-4000-8000-000000000001', null, '{}', '{}', 'usd') $$,
  '22023', 'invalid_currency', 'Kleinschreibung wird nicht stillschweigend akzeptiert'
);

select is(
  (select count(*)::int from public.transactions where user_id = auth.uid()),
  2,
  'Nur die beiden gültigen Buchungen wurden angelegt'
);

select hasnt_table('public', 'exchange_rates', 'Keine Wechselkurs-Tabelle (bewusst keine Umrechnung)');

select * from finish();
rollback;
