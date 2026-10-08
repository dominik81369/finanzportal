-- =====================================================================
--  supabase/tests/budget_b1.test.sql
--  Budget-1: Einstellungen (Prozentziele, Bezugsgröße), Standardkategorien
--  Darlehen/Darlehenszinsen, budget_category_totals(), Mandantentrennung
--  und Beraterzugriff (Migration 20261011100000)
--  Ausführen: supabase test db   (setzt 00000-test-helpers.sql voraus)
--
--  Identitäten
--    b1b_alice – Nutzerin mit Buchungen
--    b1b_bob   – anderer Nutzer
--    b1b_carol – Beraterin, aktive Verbindung zu Alice
--    b1b_dave  – Berater ohne Verbindung
-- =====================================================================

begin;

select plan(41);

select tests.create_supabase_user('b1b_alice', 'b1b-alice@example.test');
select tests.create_supabase_user('b1b_bob',   'b1b-bob@example.test');
select tests.create_supabase_user('b1b_carol', 'b1b-carol@example.test');
select tests.create_supabase_user('b1b_dave',  'b1b-dave@example.test');

select tests.authenticate_as_service_role();
update public.profiles set role = 'advisor'
 where user_id in (tests.get_supabase_uid('b1b_carol'), tests.get_supabase_uid('b1b_dave'));
insert into public.advisor_clients (advisor_id, user_id, status, invited_email, accepted_at) values
  (tests.get_supabase_uid('b1b_carol'), tests.get_supabase_uid('b1b_alice'), 'active', 'b1b-alice@example.test', now());

-- ---------------------------------------------------------------------
-- 1. Standardkategorien
-- ---------------------------------------------------------------------
select results_eq(
  format($$ select default_key, name, kind::text, budget_group::text from public.categories
             where user_id = %L and default_key in ('loan', 'loan_interest', 'loan_repayment') order by sort_order $$,
         tests.get_supabase_uid('b1b_alice')),
  $$ values ('loan'::text, 'Darlehen'::text, 'expense'::text, 'needs'::text),
            ('loan_interest', 'Darlehenszinsen', 'expense', 'needs'),
            ('loan_repayment', 'Kredittilgung', 'transfer', 'savings') $$,
  'Neue Nutzerin: Darlehen und Darlehenszinsen (Needs), Kredittilgung (Sparen & Schulden)'
);
select is(
  (select count(*)::integer from public.categories where user_id = tests.get_supabase_uid('b1b_alice') and default_key is not null),
  21, 'Neue Nutzerin: 21 Standardkategorien'
);

-- ---------------------------------------------------------------------
-- 2. Einstellungen
-- ---------------------------------------------------------------------
select tests.authenticate_as('b1b_alice');
select is_empty($$ select 1 from public.budget_settings $$, 'Ohne Speichern keine Einstellungen (Standardwerte in der App)');
select lives_ok($$ select public.save_budget_settings('expenses', 50, 30, 20, null, 'EUR') $$, 'Standardwerte speichern');
select results_eq(
  $$ select basis::text, needs_pct, wants_pct, savings_pct, fixed_amount, fixed_currency::text from public.budget_settings $$,
  $$ values ('expenses'::text, 50.0::numeric, 30.0::numeric, 20.0::numeric, null::numeric, 'EUR'::text) $$,
  'Einstellungen gespeichert'
);
select lives_ok($$ select public.save_budget_settings('income', 55.5, 24.5, 20, 9000, 'EUR') $$,
  'Ändern: eine Nachkommastelle, fester Betrag optional');
select results_eq(
  $$ select basis::text, needs_pct, wants_pct, fixed_amount from public.budget_settings $$,
  $$ values ('income'::text, 55.5::numeric, 24.5::numeric, 9000.00::numeric) $$,
  'Einstellungen geändert (eine Zeile je Nutzer)'
);
select throws_ok($$ select public.save_budget_settings('expenses', 50, 30, 21, null, 'EUR') $$,
  '22023', 'invalid_percentages', 'Summe ungleich 100 abgelehnt');
select throws_ok($$ select public.save_budget_settings('expenses', 50.25, 29.75, 20, null, 'EUR') $$,
  '22023', 'invalid_percentages', 'Zwei Nachkommastellen abgelehnt');
select throws_ok($$ select public.save_budget_settings('expenses', 110, -30, 20, null, 'EUR') $$,
  '22023', 'invalid_percentages', 'Werte außerhalb 0–100 abgelehnt');
select throws_ok($$ select public.save_budget_settings('fixed', 50, 30, 20, null, 'EUR') $$,
  '22023', 'invalid_fixed_amount', 'Fester Betrag als Bezugsgröße braucht einen Betrag');
select throws_ok($$ select public.save_budget_settings('expenses', 50, 30, 20, 0, 'EUR') $$,
  '22023', 'invalid_fixed_amount', 'Fester Betrag muss positiv sein');
select lives_ok($$ select public.save_budget_settings('fixed', 50, 30, 20, 9601.76, 'EUR') $$,
  'Fester Monatsbetrag als Voreinstellung');
select throws_ok(
  $$ update public.budget_settings set needs_pct = 60 where user_id = auth.uid() $$,
  '23514', null, 'Auch direkt: Summe muss 100 ergeben (Check-Constraint)'
);

-- ---------------------------------------------------------------------
-- 3. Mandantentrennung und Beraterzugriff auf Einstellungen
-- ---------------------------------------------------------------------
select tests.authenticate_as('b1b_bob');
select is_empty($$ select 1 from public.budget_settings $$, 'Bob sieht keine fremden Einstellungen');
select is_empty(
  format($$ update public.budget_settings set basis = 'income' where user_id = %L returning 1 $$, tests.get_supabase_uid('b1b_alice')),
  'Bob kann fremde Einstellungen nicht ändern');
select throws_ok(
  format($$ insert into public.budget_settings (user_id) values (%L) $$, tests.get_supabase_uid('b1b_alice')),
  '42501', null, 'Bob kann keine Einstellungen für Alice anlegen');

select tests.authenticate_as('b1b_carol');
select results_eq(
  format($$ select basis::text, fixed_amount from public.budget_settings where user_id = %L $$, tests.get_supabase_uid('b1b_alice')),
  $$ values ('fixed'::text, 9601.76::numeric) $$,
  'Beraterin (aktiv) liest die Einstellungen der Mandantin'
);
select is_empty(
  format($$ update public.budget_settings set basis = 'income' where user_id = %L returning 1 $$, tests.get_supabase_uid('b1b_alice')),
  'Beraterin kann die Einstellungen nicht ändern');
select public.save_budget_settings('income', 50, 30, 20, null, 'EUR');
select is(
  (select basis::text from public.budget_settings where user_id = tests.get_supabase_uid('b1b_alice')),
  'fixed', 'Speichern der Beraterin betrifft nur ihre eigenen Einstellungen');

select tests.authenticate_as('b1b_dave');
select is_empty(
  format($$ select 1 from public.budget_settings where user_id = %L $$, tests.get_supabase_uid('b1b_alice')),
  'Berater ohne Verbindung sieht nichts');

-- ---------------------------------------------------------------------
-- 4. Summen je Kategorie
-- ---------------------------------------------------------------------
select tests.authenticate_as('b1b_alice');
-- Eigenes Konto vor den Buchungen anlegen (ordnet so nichts um).
select public.add_own_account_identifier('iban', 'DE02 1203 0000 0000 2020 51',
  (select id from public.categories where user_id = auth.uid() and default_key = 'savings_investments'));
insert into public.categories (name, kind, parent_category_id)
select 'Grundsteuer', 'expense', id from public.categories where user_id = auth.uid() and default_key = 'taxes';

insert into public.accounts (id, name, type, currency) values
  ('b1b00000-0000-4000-8000-000000000001', 'Giro', 'checking', 'EUR'),
  ('b1b00000-0000-4000-8000-000000000002', 'Konto CH', 'checking', 'CHF');

create function pg_temp.cat(p_key text) returns uuid language sql as $$
  select id from public.categories where user_id = auth.uid() and default_key = p_key;
$$;
grant execute on function pg_temp.cat(text) to authenticated;

insert into public.transactions (account_id, booking_date, amount, currency, category_id, counterparty_iban, exclude_from_budget)
values
  ('b1b00000-0000-4000-8000-000000000001', '2026-04-01', 12640.14, 'EUR', pg_temp.cat('salary'), null, false),
  ('b1b00000-0000-4000-8000-000000000001', '2026-04-02', -1000.00, 'EUR', pg_temp.cat('housing'), null, false),
  ('b1b00000-0000-4000-8000-000000000001', '2026-04-03', -500.00, 'EUR', pg_temp.cat('taxes'), null, false),
  ('b1b00000-0000-4000-8000-000000000001', '2026-04-04', -20.00, 'EUR', pg_temp.cat('capital_gains_tax'), null, false),
  ('b1b00000-0000-4000-8000-000000000001', '2026-04-05', -60.00, 'EUR',
   (select id from public.categories where user_id = auth.uid() and name = 'Grundsteuer'), null, false),
  ('b1b00000-0000-4000-8000-000000000001', '2026-04-06', -3993.29, 'EUR', pg_temp.cat('loan'), null, false),
  ('b1b00000-0000-4000-8000-000000000001', '2026-04-07', -300.00, 'EUR', pg_temp.cat('shopping'), null, false),
  ('b1b00000-0000-4000-8000-000000000001', '2026-04-08', 50.00, 'EUR', pg_temp.cat('shopping'), null, false),
  ('b1b00000-0000-4000-8000-000000000001', '2026-04-09', -200.00, 'EUR', pg_temp.cat('savings_investments'), 'DE02120300000000202051', false),
  ('b1b00000-0000-4000-8000-000000000001', '2026-04-10', -100.00, 'EUR', pg_temp.cat('savings_investments'), 'DE89370400440532013000', false),
  ('b1b00000-0000-4000-8000-000000000001', '2026-04-11', -400.00, 'EUR', pg_temp.cat('loan_repayment'), null, false),
  ('b1b00000-0000-4000-8000-000000000001', '2026-04-12', -1000.00, 'EUR', pg_temp.cat('transfer'), 'DE02120300000000202051', false),
  ('b1b00000-0000-4000-8000-000000000001', '2026-04-13', 300.00, 'EUR', pg_temp.cat('transfer'), null, false),
  ('b1b00000-0000-4000-8000-000000000001', '2026-04-14', -40.00, 'EUR', null, null, false),
  ('b1b00000-0000-4000-8000-000000000001', '2026-04-15', 25.00, 'EUR', null, null, false),
  ('b1b00000-0000-4000-8000-000000000001', '2026-04-16', -999.00, 'EUR', pg_temp.cat('shopping'), null, true),
  ('b1b00000-0000-4000-8000-000000000001', '2026-05-02', -1000.00, 'EUR', pg_temp.cat('housing'), null, false),
  ('b1b00000-0000-4000-8000-000000000002', '2026-04-01', 1000.00, 'CHF', pg_temp.cat('salary'), null, false),
  ('b1b00000-0000-4000-8000-000000000002', '2026-04-20', -100.00, 'CHF', pg_temp.cat('groceries'), null, false);

create temp table totals as
select * from public.budget_category_totals(tests.get_supabase_uid('b1b_alice'), '2026-04-01', '2026-05-31');
grant select on totals to authenticated;

select is((select sum(amount) from totals where month = '2026-04-01' and currency = 'EUR' and kind = 'income'),
  12640.14::numeric, 'Einkommen April');
select is((select sum(amount) from totals where month = '2026-04-01' and currency = 'EUR' and budget_group = 'needs'),
  -5573.29::numeric, 'Needs April: Wohnen, Steuern (inkl. Unterkategorie), Darlehen');
select is((select sum(amount) from totals where month = '2026-04-01' and currency = 'EUR' and budget_group = 'needs' and flag = 'taxes'),
  -580.00::numeric, 'Merkmal Steuern: Steuern & Abgaben, Kapitalertragsteuer und Unterkategorie Grundsteuer');
select is((select sum(amount) from totals where month = '2026-04-01' and currency = 'EUR' and budget_group = 'needs' and flag = 'loan'),
  -3993.29::numeric, 'Merkmal Darlehen in Needs (ungeteilte Rate)');
select is((select sum(amount) from totals where month = '2026-04-01' and currency = 'EUR' and budget_group = 'wants'),
  -250.00::numeric, 'Wants netto (Erstattung mindert), ausgenommene Buchung zählt nicht');
select is((select sum(amount) from totals where month = '2026-04-01' and currency = 'EUR' and budget_group = 'savings'),
  -700.00::numeric, 'Sparen & Schulden: Sparen (eigenes und fremdes Konto) und Kredittilgung');
select is((select sum(amount) from totals where month = '2026-04-01' and currency = 'EUR' and budget_group = 'savings' and own_account),
  -200.00::numeric, 'Davon auf eigene Sparkonten (IBAN-Regel)');
select is((select sum(amount) from totals where month = '2026-04-01' and currency = 'EUR' and budget_group = 'savings' and flag = 'loan'),
  -400.00::numeric, 'Kredittilgung trägt das Merkmal Darlehen');
select is((select sum(amount) from totals where month = '2026-04-01' and currency = 'EUR' and budget_group is null and kind = 'transfer'),
  -700.00::numeric, 'Umbuchungen netto (zählen nicht als Ausgabe)');
select is((select sum(amount) from totals where month = '2026-04-01' and currency = 'EUR' and category_id is null),
  -40.00::numeric, 'Ohne Kategorie: nur Abflüsse');
select is((select bool_or(own_account) from totals where kind = 'transfer'),
  true, 'Eigenes Gegenkonto auch bei Umbuchungen erkannt');
select results_eq(
  $$ select currency, kind::text, amount from totals where currency = 'CHF' order by kind::text desc $$,
  $$ values ('CHF'::text, 'income'::text, 1000.00::numeric), ('CHF', 'expense', -100.00) $$,
  'Je Währung getrennt'
);
select is((select sum(amount) from totals where month = '2026-05-01'), -1000.00::numeric, 'Mai: eigener Monat');

select throws_ok(
  format($$ select * from public.budget_category_totals(%L, '2026-05-01', '2026-04-01') $$, tests.get_supabase_uid('b1b_alice')),
  '22023', 'invalid_period', 'von nach bis → invalid_period');
select throws_ok(
  format($$ select * from public.budget_category_totals(%L, '2020-01-01', '2026-01-02') $$, tests.get_supabase_uid('b1b_alice')),
  '22023', 'invalid_period', 'zu langer Zeitraum → invalid_period');

-- ---------------------------------------------------------------------
-- 5. Zugriff auf die Summen
-- ---------------------------------------------------------------------
select tests.authenticate_as('b1b_carol');
select is(
  (select sum(amount) from public.budget_category_totals(tests.get_supabase_uid('b1b_alice'), '2026-04-01', '2026-04-30')
    where currency = 'EUR' and budget_group = 'savings' and own_account),
  -200.00::numeric, 'Beraterin (aktiv) sieht die Summen der Mandantin inkl. eigener Konten');
select tests.authenticate_as('b1b_dave');
select is_empty(
  format($$ select * from public.budget_category_totals(%L, '2026-04-01', '2026-04-30') $$, tests.get_supabase_uid('b1b_alice')),
  'Berater ohne Verbindung: leeres Ergebnis');
select tests.authenticate_as('b1b_bob');
select is_empty(
  format($$ select * from public.budget_category_totals(%L, '2026-04-01', '2026-04-30') $$, tests.get_supabase_uid('b1b_alice')),
  'Anderer Nutzer: leeres Ergebnis');

select tests.clear_authentication();
select ok(not has_function_privilege('anon', 'public.budget_category_totals(uuid, date, date)', 'execute'),
  'anon darf budget_category_totals nicht ausführen');
select ok(not has_table_privilege('anon', 'public.budget_settings', 'select'), 'anon hat keinen Zugriff auf budget_settings');

select * from finish();

rollback;
