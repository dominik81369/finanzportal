-- =====================================================================
--  supabase/tests/account_balance.test.sql
--  Kontostand aus Buchungen (Migration 20261002140000)
--  Ausführen: supabase test db   (setzt 00000-test-helpers.sql voraus)
--
--  balance = opening_balance + Summe der Buchungen in Kontowährung,
--  nur für provider manual/csv; synchronisierte Konten unberührt.
--
--  Identitäten
--    ab_alice – Kontoinhaberin
--    ab_carol – Beraterin von Alice (nur lesend)
-- =====================================================================

begin;

select plan(27);

select tests.create_supabase_user('ab_alice', 'ab-alice@example.test');
select tests.create_supabase_user('ab_carol', 'ab-carol@example.test');

select tests.authenticate_as_service_role();
update public.profiles set role = 'advisor' where user_id = tests.get_supabase_uid('ab_carol');
insert into public.advisor_clients (advisor_id, user_id, status, invited_email, accepted_at) values
  (tests.get_supabase_uid('ab_carol'), tests.get_supabase_uid('ab_alice'), 'active', 'ab-alice@example.test', now());

prepare balance_of(uuid) as select balance from public.accounts where id = $1;

-- ---------------------------------------------------------------------
-- 1. Anlegen (1–4)
-- ---------------------------------------------------------------------
select tests.authenticate_as('ab_alice');

insert into public.accounts (id, name, type, opening_balance) values
  ('ab000000-0000-4000-8000-000000000001', 'Giro', 'checking', 100.00),
  ('ab000000-0000-4000-8000-000000000002', 'Tagesgeld', 'savings', 0);

select results_eq(
  $$ execute balance_of('ab000000-0000-4000-8000-000000000001') $$,
  $$ values (100.00::numeric) $$,
  'Neues Konto: Saldo = Anfangsbestand'
);
select throws_ok(
  $$ insert into public.accounts (name, type, balance) values ('Falsch', 'checking', 50) $$,
  '22023', 'balance_is_calculated',
  'Anlegen mit abweichendem balance wird abgewiesen'
);
select lives_ok(
  $$ insert into public.accounts (id, name, type, opening_balance, balance)
     values ('ab000000-0000-4000-8000-000000000003', 'Bar', 'cash', 30, 30) $$,
  'balance = opening_balance beim Anlegen ist erlaubt'
);
select results_eq(
  $$ execute balance_of('ab000000-0000-4000-8000-000000000003') $$,
  $$ values (30.00::numeric) $$,
  'Konto mit gleichem balance/opening_balance hat Saldo 30'
);

-- ---------------------------------------------------------------------
-- 2. Buchungen anlegen, ändern, verschieben, löschen, RPCs (5–14)
-- ---------------------------------------------------------------------
insert into public.transactions (id, account_id, booking_date, amount, currency) values
  ('ab000000-0000-4000-8000-0000000000a1', 'ab000000-0000-4000-8000-000000000001', '2026-09-01', -20.00, 'EUR');
select results_eq(
  $$ execute balance_of('ab000000-0000-4000-8000-000000000001') $$,
  $$ values (80.00::numeric) $$,
  'Einzelne Buchung: 100 − 20 = 80'
);

insert into public.transactions (id, account_id, booking_date, amount, currency) values
  ('ab000000-0000-4000-8000-0000000000a2', 'ab000000-0000-4000-8000-000000000001', '2026-09-02', 10.00, 'EUR'),
  ('ab000000-0000-4000-8000-0000000000a3', 'ab000000-0000-4000-8000-000000000001', '2026-09-03', -5.00, 'EUR'),
  ('ab000000-0000-4000-8000-0000000000a4', 'ab000000-0000-4000-8000-000000000002', '2026-09-03', 500.00, 'EUR');
select results_eq(
  $$ select balance from public.accounts
      where id in ('ab000000-0000-4000-8000-000000000001', 'ab000000-0000-4000-8000-000000000002')
      order by id $$,
  $$ values (85.00::numeric), (500.00::numeric) $$,
  'Mehrzeiliger Insert über zwei Konten: 85 bzw. 500'
);

update public.transactions set amount = -50.00 where id = 'ab000000-0000-4000-8000-0000000000a1';
select results_eq(
  $$ execute balance_of('ab000000-0000-4000-8000-000000000001') $$,
  $$ values (55.00::numeric) $$,
  'Betrag geändert (−20 → −50): 55'
);

select tests.authenticate_as_service_role();
update public.accounts set balance_updated_at = '2000-01-01 00:00:00+00'
 where id = 'ab000000-0000-4000-8000-000000000001';
select tests.authenticate_as('ab_alice');
update public.transactions set purpose = 'nur Text' where id = 'ab000000-0000-4000-8000-0000000000a1';
select results_eq(
  $$ select balance, balance_updated_at = '2000-01-01 00:00:00+00'
       from public.accounts where id = 'ab000000-0000-4000-8000-000000000001' $$,
  $$ values (55.00::numeric, true) $$,
  'Änderung ohne Betrag/Konto/Währung löst keine Neuberechnung aus'
);

update public.transactions set account_id = 'ab000000-0000-4000-8000-000000000002'
 where id = 'ab000000-0000-4000-8000-0000000000a2';
select results_eq(
  $$ select balance from public.accounts
      where id in ('ab000000-0000-4000-8000-000000000001', 'ab000000-0000-4000-8000-000000000002')
      order by id $$,
  $$ values (45.00::numeric), (510.00::numeric) $$,
  'Kontowechsel: altes Konto 45, neues Konto 510'
);

delete from public.transactions where id = 'ab000000-0000-4000-8000-0000000000a3';
select results_eq(
  $$ execute balance_of('ab000000-0000-4000-8000-000000000001') $$,
  $$ values (50.00::numeric) $$,
  'Löschen (−5 entfernt): 50'
);

-- Über die RPCs der App (manuelle Erfassung, Bearbeiten, Löschen).
select lives_ok(
  $$ select public.create_manual_transaction(
       p_booking_date => '2026-09-10', p_amount => -12.34, p_counterparty_name => 'RPC',
       p_account_id => 'ab000000-0000-4000-8000-000000000003') $$,
  'create_manual_transaction läuft'
);
select results_eq(
  $$ execute balance_of('ab000000-0000-4000-8000-000000000003') $$,
  $$ values (17.66::numeric) $$,
  'create_manual_transaction: 30 − 12,34 = 17,66'
);
select lives_ok(
  $$ select public.delete_manual_transaction(
       (select id from public.transactions where counterparty_name = 'RPC')) $$,
  'delete_manual_transaction läuft'
);

-- ---------------------------------------------------------------------
-- 3. Fremdwährung zählt nicht (15)
-- ---------------------------------------------------------------------
select results_eq(
  $$ execute balance_of('ab000000-0000-4000-8000-000000000003') $$,
  $$ values (30.00::numeric) $$,
  'delete_manual_transaction: wieder 30'
);
insert into public.transactions (id, account_id, booking_date, amount, currency) values
  ('ab000000-0000-4000-8000-0000000000c1', 'ab000000-0000-4000-8000-000000000001', '2026-09-05', 120.00, 'CHF');
select results_eq(
  $$ execute balance_of('ab000000-0000-4000-8000-000000000001') $$,
  $$ values (50.00::numeric) $$,
  'CHF-Buchung auf EUR-Konto verändert den EUR-Saldo nicht'
);

-- ---------------------------------------------------------------------
-- 4. Anfangsbestand und Kontowährung ändern (16–17)
-- ---------------------------------------------------------------------
update public.accounts set opening_balance = 1000 where id = 'ab000000-0000-4000-8000-000000000001';
select results_eq(
  $$ execute balance_of('ab000000-0000-4000-8000-000000000001') $$,
  $$ values (950.00::numeric) $$,
  'Anfangsbestand 100 → 1000: Saldo 950'
);
update public.accounts set currency = 'CHF' where id = 'ab000000-0000-4000-8000-000000000001';
select results_eq(
  $$ execute balance_of('ab000000-0000-4000-8000-000000000001') $$,
  $$ values (1120.00::numeric) $$,
  'Kontowährung EUR → CHF: 1000 + 120 CHF = 1120, EUR-Buchungen zählen nicht mehr'
);

-- ---------------------------------------------------------------------
-- 5. balance ist nicht direkt schreibbar (18–20)
-- ---------------------------------------------------------------------
select throws_ok(
  $$ update public.accounts set balance = 1 where id = 'ab000000-0000-4000-8000-000000000001' $$,
  '22023', 'balance_is_calculated',
  'Inhaberin kann balance nicht direkt setzen'
);
select tests.authenticate_as_service_role();
select throws_ok(
  $$ update public.accounts set balance = 1 where id = 'ab000000-0000-4000-8000-000000000001' $$,
  '22023', 'balance_is_calculated',
  'Auch service_role kann balance manueller Konten nicht direkt setzen'
);
select tests.authenticate_as('ab_carol');
select is_empty(
  $$ update public.accounts set opening_balance = 0
      where id = 'ab000000-0000-4000-8000-000000000001' returning id $$,
  'Beraterin kann den Anfangsbestand der Mandantin nicht ändern (0 Zeilen)'
);

-- ---------------------------------------------------------------------
-- 6. Synchronisierte Konten behalten den Bank-Saldo (21–24)
-- ---------------------------------------------------------------------
select tests.authenticate_as_service_role();
insert into public.accounts (id, user_id, name, type, provider, provider_account_id, balance) values
  ('ab000000-0000-4000-8000-000000000009', tests.get_supabase_uid('ab_alice'),
   'Bank sync', 'checking', 'gocardless', 'ext-1', 999.99);
select results_eq(
  $$ execute balance_of('ab000000-0000-4000-8000-000000000009') $$,
  $$ values (999.99::numeric) $$,
  'Synchronisiertes Konto: Bank-Saldo beim Anlegen übernommen'
);
insert into public.transactions (user_id, account_id, booking_date, amount, currency) values
  (tests.get_supabase_uid('ab_alice'), 'ab000000-0000-4000-8000-000000000009', '2026-09-06', -99.99, 'EUR');
select results_eq(
  $$ execute balance_of('ab000000-0000-4000-8000-000000000009') $$,
  $$ values (999.99::numeric) $$,
  'Synchronisiertes Konto: Buchung ändert den Bank-Saldo nicht'
);
select lives_ok(
  $$ update public.accounts set balance = 900 where id = 'ab000000-0000-4000-8000-000000000009' $$,
  'Synchronisiertes Konto: Sync darf balance setzen'
);
update public.accounts set provider = 'manual' where id = 'ab000000-0000-4000-8000-000000000009';
select results_eq(
  $$ execute balance_of('ab000000-0000-4000-8000-000000000009') $$,
  $$ values (-99.99::numeric) $$,
  'Wechsel auf manuell: ab jetzt berechnet (0 − 99,99)'
);

-- ---------------------------------------------------------------------
-- 7. Invariante, Index, Standardwert (25–27)
-- ---------------------------------------------------------------------
select is(
  (select count(*)::int
     from public.accounts a
    where a.provider in ('manual', 'csv')
      and a.balance <> a.opening_balance + coalesce((
            select sum(t.amount) from public.transactions t
             where t.account_id = a.id and t.currency = a.currency), 0)),
  0,
  'Alle manuellen/CSV-Konten: balance = opening_balance + Buchungen in Kontowährung'
);
select has_index('public', 'transactions', 'transactions_account_currency_idx',
  'Index für die Summe je Konto und Währung');
select col_default_is('public', 'accounts', 'opening_balance', '0',
  'opening_balance hat den Standard 0');

select * from finish();
rollback;
