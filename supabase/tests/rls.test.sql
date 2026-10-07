-- =====================================================================
--  supabase/tests/rls.test.sql
--  Phase 1b · RLS-, Mandantentrennungs- und Einladungs-Tests
--  Ausführen: supabase test db   (setzt 00000-test-helpers.sql voraus)
--
--  Identitäten
--    alice  – Mandantin A
--    bob    – Mandant B (versucht beim Signup role=advisor zu setzen)
--    carol  – Beraterin (per service_role hochgestuft)
--
--  PostgreSQL-Semantik, die die Assertions bestimmt
--    * SELECT auf fremde Zeilen wirft KEINEN Fehler, RLS filtert still
--      → is_empty().
--    * UPDATE/DELETE auf fremde Zeilen wirft KEINEN Fehler, es werden
--      0 Zeilen getroffen → Zählung über RETURNING + Zustandsprüfung.
--    * INSERT bzw. UPDATE, dessen neue Zeile die WITH-CHECK-Klausel verletzt,
--      wirft 42501 ("new row violates row-level security policy").
--    * Fehlende Tabellen-/Spaltenrechte werfen 42501 ("permission denied").
--    * Fremdschlüsselverletzungen werfen 23503.
--
--  Feste Test-IDs
--    a1…01 Alice-Konto        a1…02 Alice-Transaktion  a1…03 Alice-Kategorie
--    a1…04 Alice-Portfolio    a1…05 Alice-Asset        a1…06 Alice-Immobilie
--    b2…01 Bob-Konto          b2…02 Bob-Transaktion
--    c3…01 abgelaufene Einladung Carol → Bob
--
--  Einladungstokens (Klartext → SHA-256 hex)
--    tok_valid_alice_invite_7f3c9a1e5b2d4c8f0a6e
--      → e6c281fef30d81df56db76af433333970cb55c178467897efe866f44693cd8aa
--    tok_expired_bob_invite_2b8e4f6a1c9d3e7f5a0b
--      → 329621f0547dc3f630d80a35dcb6ff0d0057cb70131accd3e114b34193f3b91a
-- =====================================================================

begin;

select plan(76);

-- ---------------------------------------------------------------------
-- 0. Testidentitäten
-- ---------------------------------------------------------------------
-- Der Signup-Trigger (private.handle_new_user) legt Profil + 19
-- Standardkategorien an. Bobs Metadaten enthalten role=advisor – das muss
-- ignoriert werden (Test 2).
select tests.create_supabase_user(
  'alice', 'alice@example.test', null,
  '{"first_name": "Alice", "last_name": "Anders"}'::jsonb
);
select tests.create_supabase_user(
  'bob', 'bob@example.test', null,
  '{"first_name": "Bob", "last_name": "Berg", "role": "advisor"}'::jsonb
);
select tests.create_supabase_user(
  'carol', 'carol@example.test', null,
  '{"first_name": "Carol", "last_name": "Christ"}'::jsonb
);

-- Auth-Systemzustand (kein public-Datensatz): tests.create_supabase_user()
-- setzt kein email_confirmed_at. GoTrue setzt es nach Klick auf den
-- Bestätigungslink; accept_advisor_invitation() verlangt eine bestätigte E-Mail.
update auth.users
   set email_confirmed_at = now()
 where id in (
   tests.get_supabase_uid('alice'),
   tests.get_supabase_uid('bob'),
   tests.get_supabase_uid('carol')
 );

-- ---------------------------------------------------------------------
-- 1. Testdaten – ausschließlich als service_role (RLS-Bypass)
-- ---------------------------------------------------------------------
select tests.authenticate_as_service_role();

update public.profiles
   set role = 'advisor'
 where user_id = tests.get_supabase_uid('carol');

-- Saldo = opening_balance + Buchungen (Migration 20261002140000).
insert into public.accounts (id, user_id, name, type, opening_balance) values
  ('a1000000-0000-4000-8000-000000000001', tests.get_supabase_uid('alice'), 'Alice Girokonto', 'checking', 2500.00),
  ('b2000000-0000-4000-8000-000000000001', tests.get_supabase_uid('bob'),   'Bob Girokonto',   'checking', 1200.00);

insert into public.categories (id, user_id, name, kind) values
  ('a1000000-0000-4000-8000-000000000003', tests.get_supabase_uid('alice'), 'Testkategorie Alice', 'expense');

insert into public.transactions (id, user_id, account_id, category_id, booking_date, amount, counterparty_name) values
  ('a1000000-0000-4000-8000-000000000002', tests.get_supabase_uid('alice'),
   'a1000000-0000-4000-8000-000000000001', 'a1000000-0000-4000-8000-000000000003',
   date '2026-09-01', -84.20, 'REWE Markt'),
  ('b2000000-0000-4000-8000-000000000002', tests.get_supabase_uid('bob'),
   'b2000000-0000-4000-8000-000000000001', null,
   date '2026-09-02', -19.99, 'Streamingdienst');

insert into public.portfolios (id, user_id, name, broker) values
  ('a1000000-0000-4000-8000-000000000004', tests.get_supabase_uid('alice'), 'Alice ETF-Depot', 'Testbroker');

insert into public.assets (id, user_id, portfolio_id, name, instrument_type, asset_class, region, isin, quantity, current_price) values
  ('a1000000-0000-4000-8000-000000000005', tests.get_supabase_uid('alice'),
   'a1000000-0000-4000-8000-000000000004', 'MSCI World ETF', 'etf', 'equity', 'global',
   'IE00B4L5Y983', 10, 100.00);

insert into public.real_estate_objects (id, user_id, name, purchase_price, monthly_cold_rent) values
  ('a1000000-0000-4000-8000-000000000006', tests.get_supabase_uid('alice'), 'ETW Leipzig', 250000.00, 850.00);

-- Bereits abgelaufene Einladung Carol → Bob
insert into public.advisor_clients (id, advisor_id, invited_email, invite_token_hash, invite_expires_at) values
  ('c3000000-0000-4000-8000-000000000001', tests.get_supabase_uid('carol'), 'bob@example.test',
   '329621f0547dc3f630d80a35dcb6ff0d0057cb70131accd3e114b34193f3b91a', now() - interval '1 day');

-- ---------------------------------------------------------------------
-- 2. Schema-Grundlagen (Tests 1–3)
-- ---------------------------------------------------------------------
select tests.rls_enabled('public');                                                         -- 1

select is(
  (select role::text from public.profiles where user_id = tests.get_supabase_uid('bob')),
  'client',
  'Signup ignoriert role aus raw_user_meta_data (Bob bleibt client)'
);                                                                                          -- 2

select is(
  (select count(*)::int from public.categories
    where user_id = tests.get_supabase_uid('alice') and is_default),
  19,
  'Signup-Trigger seedet 19 Standardkategorien'
);                                                                                          -- 3

-- ---------------------------------------------------------------------
-- 3. Owner-Zugriff Alice – Positiv (Tests 4–8)
-- ---------------------------------------------------------------------
select tests.authenticate_as('alice');

select results_eq(
  $$ select name from public.accounts order by name $$,
  $$ values ('Alice Girokonto'::text) $$,
  'Alice sieht ausschließlich ihr eigenes Konto'
);                                                                                          -- 4

select results_eq(
  $$ select amount from public.transactions $$,
  $$ values (-84.20::numeric) $$,
  'Alice sieht ausschließlich ihre eigene Transaktion'
);                                                                                          -- 5

select lives_ok(
  $$ insert into public.accounts (name, type, opening_balance) values ('Alice Tagesgeld', 'savings', 10000.00) $$,
  'Alice legt eigenes Konto an (user_id per Default auth.uid())'
);                                                                                          -- 6

select lives_ok(
  $$ update public.profiles set first_name = 'Alicia' where user_id = (select auth.uid()) $$,
  'Alice ändert erlaubte Profilspalte first_name'
);                                                                                          -- 7

select results_eq(
  $$ select first_name from public.profiles where user_id = (select auth.uid()) $$,
  $$ values ('Alicia'::text) $$,
  'Profiländerung von Alice ist persistiert'
);                                                                                          -- 8

-- ---------------------------------------------------------------------
-- 4. Cross-Tenant Read: Bob → Alice (Tests 9–17)
-- ---------------------------------------------------------------------
select tests.authenticate_as('bob');

select is_empty(
  $$ select 1 from public.profiles where user_id = tests.get_supabase_uid('alice') $$,
  'Bob kann Alices Profil nicht lesen'
);                                                                                          -- 9
select is_empty(
  $$ select 1 from public.accounts where user_id = tests.get_supabase_uid('alice') $$,
  'Bob kann Alices Konten nicht lesen'
);                                                                                          -- 10
select is_empty(
  $$ select 1 from public.transactions where user_id = tests.get_supabase_uid('alice') $$,
  'Bob kann Alices Transaktionen nicht lesen'
);                                                                                          -- 11
select is_empty(
  $$ select 1 from public.categories where user_id = tests.get_supabase_uid('alice') $$,
  'Bob kann Alices Kategorien nicht lesen'
);                                                                                          -- 12
select is_empty(
  $$ select 1 from public.portfolios where user_id = tests.get_supabase_uid('alice') $$,
  'Bob kann Alices Portfolios nicht lesen'
);                                                                                          -- 13
select is_empty(
  $$ select 1 from public.assets where user_id = tests.get_supabase_uid('alice') $$,
  'Bob kann Alices Assets nicht lesen'
);                                                                                          -- 14
select is_empty(
  $$ select 1 from public.real_estate_objects where user_id = tests.get_supabase_uid('alice') $$,
  'Bob kann Alices Immobilien nicht lesen'
);                                                                                          -- 15
select is_empty(
  $$ select 1 from public.advisor_clients $$,
  'Bob sieht keine Berater-Verknüpfungen (auch nicht die an ihn adressierte Einladung)'
);                                                                                          -- 16
select results_eq(
  $$ select id from public.accounts $$,
  $$ values ('b2000000-0000-4000-8000-000000000001'::uuid) $$,
  'Bob sieht ausschließlich sein eigenes Konto'
);                                                                                          -- 17

-- ---------------------------------------------------------------------
-- 5. Cross-Tenant Write: Bob → Alice (Tests 18–24)
-- ---------------------------------------------------------------------
select throws_ok(
  $$ insert into public.accounts (user_id, name, type)
     values (tests.get_supabase_uid('alice'), 'Untergeschobenes Konto', 'checking') $$,
  '42501',
  'new row violates row-level security policy for table "accounts"',
  'Bob kann kein Konto im Namen von Alice anlegen'
);                                                                                          -- 18

select throws_ok(
  $$ insert into public.transactions (user_id, account_id, booking_date, amount)
     values (tests.get_supabase_uid('alice'), 'a1000000-0000-4000-8000-000000000001', current_date, -1.00) $$,
  '42501',
  'new row violates row-level security policy for table "transactions"',
  'Bob kann keine Transaktion im Namen von Alice anlegen'
);                                                                                          -- 19

select throws_ok(
  $$ update public.transactions set user_id = tests.get_supabase_uid('alice')
     where id = 'b2000000-0000-4000-8000-000000000002' $$,
  '42501',
  'new row violates row-level security policy for table "transactions"',
  'Bob kann eigene Datensätze nicht an Alice übertragen (WITH CHECK)'
);                                                                                          -- 20

with affected as (
  update public.accounts set balance = 0
   where id = 'a1000000-0000-4000-8000-000000000001'
  returning 1
)
select is(count(*)::int, 0, 'Bob UPDATE auf Alices Konto trifft 0 Zeilen') from affected;  -- 21

with affected as (
  delete from public.transactions
   where id = 'a1000000-0000-4000-8000-000000000002'
  returning 1
)
select is(count(*)::int, 0, 'Bob DELETE auf Alices Transaktion trifft 0 Zeilen') from affected; -- 22

with affected as (
  update public.profiles set first_name = 'Gehackt'
   where user_id = tests.get_supabase_uid('alice')
  returning 1
)
select is(count(*)::int, 0, 'Bob UPDATE auf Alices Profil trifft 0 Zeilen') from affected; -- 23

with affected as (
  delete from public.real_estate_objects
   where id = 'a1000000-0000-4000-8000-000000000006'
  returning 1
)
select is(count(*)::int, 0, 'Bob DELETE auf Alices Immobilie trifft 0 Zeilen') from affected; -- 24

-- ---------------------------------------------------------------------
-- 6. Cross-Tenant FK: Bob referenziert Alices IDs (Tests 25–28)
-- ---------------------------------------------------------------------
-- user_id = Bob (Default) → WITH CHECK besteht, der zusammengesetzte
-- Fremdschlüssel (id, user_id) schlägt fehl.
select throws_ok(
  $$ insert into public.transactions (account_id, booking_date, amount)
     values ('a1000000-0000-4000-8000-000000000001', current_date, -5.00) $$,
  '23503',
  'insert or update on table "transactions" violates foreign key constraint "transactions_account_fkey"',
  'Bob kann keine Transaktion auf Alices Konto buchen'
);                                                                                          -- 25

select throws_ok(
  $$ insert into public.transactions (account_id, category_id, booking_date, amount)
     values ('b2000000-0000-4000-8000-000000000001', 'a1000000-0000-4000-8000-000000000003', current_date, -5.00) $$,
  '23503',
  'insert or update on table "transactions" violates foreign key constraint "transactions_category_fkey"',
  'Bob kann keine Kategorie von Alice verwenden'
);                                                                                          -- 26

select throws_ok(
  $$ insert into public.assets (portfolio_id, name, instrument_type, asset_class)
     values ('a1000000-0000-4000-8000-000000000004', 'Fremdposition', 'stock', 'equity') $$,
  '23503',
  'insert or update on table "assets" violates foreign key constraint "assets_portfolio_fkey"',
  'Bob kann keine Position in Alices Portfolio anlegen'
);                                                                                          -- 27

select throws_ok(
  $$ insert into public.real_estate_objects (name, loan_account_id)
     values ('Bob Immobilie', 'a1000000-0000-4000-8000-000000000001') $$,
  '23503',
  'insert or update on table "real_estate_objects" violates foreign key constraint "real_estate_objects_loan_account_fkey"',
  'Bob kann Alices Konto nicht als Finanzierungskonto verknüpfen'
);                                                                                          -- 28

-- ---------------------------------------------------------------------
-- 7. Rechte-Eskalation (Tests 29–32)
-- ---------------------------------------------------------------------
select tests.authenticate_as('alice');

select throws_ok(
  $$ update public.profiles set role = 'advisor' where user_id = (select auth.uid()) $$,
  '42501',
  'permission denied for table profiles',
  'Alice kann profiles.role nicht auf advisor setzen'
);                                                                                          -- 29

select throws_ok(
  $$ insert into public.advisor_clients (invited_email, invite_token_hash, invite_expires_at)
     values ('fremd@example.test', repeat('a', 64), now() + interval '7 days') $$,
  '42501',
  'new row violates row-level security policy for table "advisor_clients"',
  'Alice (client) kann keine Beratereinladung anlegen'
);                                                                                          -- 30

select results_eq(
  $$ select role::text from public.profiles where user_id = (select auth.uid()) $$,
  $$ values ('client'::text) $$,
  'Alices Rolle ist unverändert client'
);                                                                                          -- 31

select tests.authenticate_as('bob');

select throws_ok(
  $$ update public.profiles set role = 'advisor' where user_id = (select auth.uid()) $$,
  '42501',
  'permission denied for table profiles',
  'Bob kann profiles.role nicht auf advisor setzen'
);                                                                                          -- 32

-- ---------------------------------------------------------------------
-- 8. Einladungs-Flow (Tests 33–45)
-- ---------------------------------------------------------------------
select tests.authenticate_as('carol');

select is_empty(
  $$ select 1 from public.accounts where user_id = tests.get_supabase_uid('alice') $$,
  'Carol sieht Alices Konten vor Annahme der Einladung nicht'
);                                                                                          -- 33

select lives_ok(
  $$ insert into public.advisor_clients (invited_email, invite_token_hash, invite_expires_at)
     values ('alice@example.test',
             'e6c281fef30d81df56db76af433333970cb55c178467897efe866f44693cd8aa',
             now() + interval '7 days') $$,
  'Carol (advisor) legt Einladung für Alice an'
);                                                                                          -- 34

select throws_ok(
  $$ insert into public.advisor_clients (invited_email, invite_token_hash, invite_expires_at, status)
     values ('dritte@example.test', repeat('b', 64), now() + interval '7 days', 'active') $$,
  '42501',
  'permission denied for table advisor_clients',
  'Carol kann keine bereits aktive Verknüpfung anlegen (kein Spalten-Grant auf status)'
);                                                                                          -- 35

select throws_ok(
  $$ update public.advisor_clients set status = 'active' where invited_email = 'alice@example.test' $$,
  '42501',
  'advisor_clients: Statuswechsel invited -> active ist nicht erlaubt',
  'Carol kann die Einladung nicht selbst aktivieren'
);                                                                                          -- 36

select tests.authenticate_as('bob');

select throws_ok(
  $$ select public.accept_advisor_invitation('tok_valid_alice_invite_7f3c9a1e5b2d4c8f0a6e') $$,
  'P0001',
  'invalid_or_expired_invitation',
  'Bob kann Alices Einladung nicht annehmen (E-Mail passt nicht)'
);                                                                                          -- 37

select throws_ok(
  $$ select public.accept_advisor_invitation('tok_expired_bob_invite_2b8e4f6a1c9d3e7f5a0b') $$,
  'P0001',
  'invalid_or_expired_invitation',
  'Bob kann seine abgelaufene Einladung nicht annehmen'
);                                                                                          -- 38

select tests.authenticate_as('alice');

select throws_ok(
  $$ select public.accept_advisor_invitation('tok_invalid_0000000000000000000000000000') $$,
  'P0001',
  'invalid_or_expired_invitation',
  'Unbekanntes Token wird abgelehnt'
);                                                                                          -- 39

select throws_ok(
  $$ select public.accept_advisor_invitation('kurz') $$,
  'P0001',
  'invalid_or_expired_invitation',
  'Zu kurzes Token wird abgelehnt'
);                                                                                          -- 40

select isnt(
  public.accept_advisor_invitation('tok_valid_alice_invite_7f3c9a1e5b2d4c8f0a6e'),
  null::uuid,
  'Alice nimmt die Einladung mit gültigem Token an'
);                                                                                          -- 41

select results_eq(
  $$ select status::text, user_id = (select auth.uid()), invite_token_hash is null, accepted_at is not null
       from public.advisor_clients
      where advisor_id = tests.get_supabase_uid('carol') $$,
  $$ values ('active'::text, true, true, true) $$,
  'Verknüpfung ist aktiv, Alice zugeordnet, Token-Hash gelöscht'
);                                                                                          -- 42

select throws_ok(
  $$ select public.accept_advisor_invitation('tok_valid_alice_invite_7f3c9a1e5b2d4c8f0a6e') $$,
  'P0001',
  'invalid_or_expired_invitation',
  'Token ist nach Annahme nicht wiederverwendbar (Replay)'
);                                                                                          -- 43

select results_eq(
  $$ select first_name from public.profiles order by first_name $$,
  $$ values ('Alicia'::text), ('Carol'::text) $$,
  'Alice sieht ihr eigenes Profil und das ihrer Beraterin'
);                                                                                          -- 44

select tests.authenticate_as('bob');

select is_empty(
  $$ select 1 from public.profiles where user_id = tests.get_supabase_uid('carol') $$,
  'Bob sieht Carols Profil nicht (keine angenommene Verknüpfung)'
);                                                                                          -- 45

-- ---------------------------------------------------------------------
-- 9. Berater-Zugriff Carol – Lesen (Tests 46–53)
-- ---------------------------------------------------------------------
select tests.authenticate_as('carol');

select results_eq(
  $$ select name from public.accounts where user_id = tests.get_supabase_uid('alice') order by name $$,
  $$ values ('Alice Girokonto'::text), ('Alice Tagesgeld'::text) $$,
  'Carol liest Alices Konten'
);                                                                                          -- 46
select results_eq(
  $$ select id from public.transactions where user_id = tests.get_supabase_uid('alice') $$,
  $$ values ('a1000000-0000-4000-8000-000000000002'::uuid) $$,
  'Carol liest Alices Transaktionen'
);                                                                                          -- 47
select is(
  (select count(*)::int from public.categories where user_id = tests.get_supabase_uid('alice')),
  20,
  'Carol liest Alices Kategorien (19 Standard + 1 eigene)'
);                                                                                          -- 48
select results_eq(
  $$ select name from public.portfolios where user_id = tests.get_supabase_uid('alice') $$,
  $$ values ('Alice ETF-Depot'::text) $$,
  'Carol liest Alices Portfolio'
);                                                                                          -- 49
select results_eq(
  $$ select market_value from public.assets where user_id = tests.get_supabase_uid('alice') $$,
  $$ values (1000.00::numeric) $$,
  'Carol liest Alices Asset inkl. berechnetem Marktwert'
);                                                                                          -- 50
select results_eq(
  $$ select name from public.real_estate_objects where user_id = tests.get_supabase_uid('alice') $$,
  $$ values ('ETW Leipzig'::text) $$,
  'Carol liest Alices Immobilie'
);                                                                                          -- 51
select results_eq(
  $$ select first_name from public.profiles where user_id = tests.get_supabase_uid('alice') $$,
  $$ values ('Alicia'::text) $$,
  'Carol liest Alices Profil'
);                                                                                          -- 52
select is_empty(
  $$ select 1 from public.accounts where user_id = tests.get_supabase_uid('bob') $$,
  'Carol liest keine Daten von Bob (Einladung abgelaufen, keine aktive Verknüpfung)'
);                                                                                          -- 53

-- ---------------------------------------------------------------------
-- 10. Berater-Zugriff Carol – Schreibversuche (Tests 54–67)
-- ---------------------------------------------------------------------
select throws_ok(
  $$ insert into public.accounts (user_id, name, type)
     values (tests.get_supabase_uid('alice'), 'Beraterkonto', 'checking') $$,
  '42501',
  'new row violates row-level security policy for table "accounts"',
  'Carol kann kein Konto für Alice anlegen'
);                                                                                          -- 54

select throws_ok(
  $$ insert into public.transactions (user_id, account_id, booking_date, amount)
     values (tests.get_supabase_uid('alice'), 'a1000000-0000-4000-8000-000000000001', current_date, -1.00) $$,
  '42501',
  'new row violates row-level security policy for table "transactions"',
  'Carol kann keine Transaktion für Alice anlegen'
);                                                                                          -- 55

select throws_ok(
  $$ insert into public.real_estate_objects (user_id, name)
     values (tests.get_supabase_uid('alice'), 'Beraterimmobilie') $$,
  '42501',
  'new row violates row-level security policy for table "real_estate_objects"',
  'Carol kann keine Immobilie für Alice anlegen'
);                                                                                          -- 56

with affected as (
  update public.accounts set balance = 0
   where id = 'a1000000-0000-4000-8000-000000000001'
  returning 1
)
select is(count(*)::int, 0, 'Carol UPDATE auf Alices Konto trifft 0 Zeilen') from affected; -- 57

with affected as (
  update public.transactions set amount = 0
   where id = 'a1000000-0000-4000-8000-000000000002'
  returning 1
)
select is(count(*)::int, 0, 'Carol UPDATE auf Alices Transaktion trifft 0 Zeilen') from affected; -- 58

with affected as (
  delete from public.transactions
   where id = 'a1000000-0000-4000-8000-000000000002'
  returning 1
)
select is(count(*)::int, 0, 'Carol DELETE auf Alices Transaktion trifft 0 Zeilen') from affected; -- 59

with affected as (
  update public.assets set quantity = 0
   where id = 'a1000000-0000-4000-8000-000000000005'
  returning 1
)
select is(count(*)::int, 0, 'Carol UPDATE auf Alices Asset trifft 0 Zeilen') from affected; -- 60

with affected as (
  delete from public.real_estate_objects
   where id = 'a1000000-0000-4000-8000-000000000006'
  returning 1
)
select is(count(*)::int, 0, 'Carol DELETE auf Alices Immobilie trifft 0 Zeilen') from affected; -- 61

with affected as (
  update public.profiles set first_name = 'Beraterin war hier'
   where user_id = tests.get_supabase_uid('alice')
  returning 1
)
select is(count(*)::int, 0, 'Carol UPDATE auf Alices Profil trifft 0 Zeilen') from affected; -- 62

select throws_ok(
  $$ update public.advisor_clients set user_id = tests.get_supabase_uid('bob')
      where advisor_id = (select auth.uid()) $$,
  '42501',
  'permission denied for table advisor_clients',
  'Carol kann die Verknüpfung nicht auf einen anderen Mandanten umbiegen'
);                                                                                          -- 63

-- Zustandsprüfung: Alices Daten sind nach allen Angriffen unverändert
select tests.authenticate_as_service_role();

select results_eq(
  $$ select balance from public.accounts where id = 'a1000000-0000-4000-8000-000000000001' $$,
  $$ values (2415.80::numeric) $$,
  'Alices Kontostand ist unverändert (2500,00 Anfangsbestand − 84,20)'
);                                                                                          -- 64
select results_eq(
  $$ select amount from public.transactions where id = 'a1000000-0000-4000-8000-000000000002' $$,
  $$ values (-84.20::numeric) $$,
  'Alices Transaktion existiert unverändert'
);                                                                                          -- 65
select results_eq(
  $$ select a.quantity, p.first_name
       from public.assets a
       join public.profiles p on p.user_id = a.user_id
      where a.id = 'a1000000-0000-4000-8000-000000000005' $$,
  $$ values (10::numeric, 'Alicia'::text) $$,
  'Alices Asset und Profil sind unverändert'
);                                                                                          -- 66
select is(
  (select count(*)::int from public.real_estate_objects where id = 'a1000000-0000-4000-8000-000000000006'),
  1,
  'Alices Immobilie existiert noch'
);                                                                                          -- 67

-- ---------------------------------------------------------------------
-- 11. Widerruf (Tests 68–74)
-- ---------------------------------------------------------------------
select tests.authenticate_as('alice');

select lives_ok(
  $$ update public.advisor_clients set status = 'revoked'
      where advisor_id = tests.get_supabase_uid('carol') $$,
  'Alice widerruft den Beraterzugriff'
);                                                                                          -- 68

select results_eq(
  $$ select status::text, revoked_at is not null
       from public.advisor_clients
      where advisor_id = tests.get_supabase_uid('carol') $$,
  $$ values ('revoked'::text, true) $$,
  'Widerruf setzt Status und revoked_at'
);                                                                                          -- 69

select throws_ok(
  $$ update public.advisor_clients set status = 'active'
      where advisor_id = tests.get_supabase_uid('carol') $$,
  '42501',
  'advisor_clients: Statuswechsel revoked -> active ist nicht erlaubt',
  'Alice kann den Zugriff nicht direkt reaktivieren'
);                                                                                          -- 70

select throws_ok(
  $$ select public.accept_advisor_invitation('tok_valid_alice_invite_7f3c9a1e5b2d4c8f0a6e') $$,
  'P0001',
  'invalid_or_expired_invitation',
  'Altes Token reaktiviert den widerrufenen Zugriff nicht'
);                                                                                          -- 71

select tests.authenticate_as('carol');

select is_empty(
  $$ select 1 from public.accounts where user_id = tests.get_supabase_uid('alice') $$,
  'Carol verliert nach Widerruf sofort den Zugriff auf Alices Konten'
);                                                                                          -- 72

select is_empty(
  $$ select 1 from public.profiles where user_id = tests.get_supabase_uid('alice') $$,
  'Carol verliert nach Widerruf den Zugriff auf Alices Profil'
);                                                                                          -- 73

select throws_ok(
  $$ update public.advisor_clients set status = 'active'
      where advisor_id = (select auth.uid()) and invited_email = 'alice@example.test' $$,
  '42501',
  'advisor_clients: Statuswechsel revoked -> active ist nicht erlaubt',
  'Carol kann den widerrufenen Zugriff nicht reaktivieren'
);                                                                                          -- 74

-- ---------------------------------------------------------------------
-- 12. Anonymer Zugriff (Tests 75–76)
-- ---------------------------------------------------------------------
select tests.clear_authentication();

select throws_ok(
  $$ select 1 from public.accounts $$,
  '42501',
  'permission denied for table accounts',
  'anon hat keinen Tabellenzugriff'
);                                                                                          -- 75

select throws_ok(
  $$ select public.accept_advisor_invitation('tok_valid_alice_invite_7f3c9a1e5b2d4c8f0a6e') $$,
  '42501',
  'permission denied for function accept_advisor_invitation',
  'anon kann die Einladungs-RPC nicht aufrufen'
);                                                                                          -- 76

select * from finish();

rollback;
