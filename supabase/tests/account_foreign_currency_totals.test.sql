-- =====================================================================
--  supabase/tests/account_foreign_currency_totals.test.sql
--  Fremdwährungssummen je Konto (Migration 20261002160000)
--  Ausführen: supabase test db   (setzt 00000-test-helpers.sql voraus)
--
--  Identitäten
--    fc_alice – Kontoinhaberin
--    fc_carol – Beraterin von Alice (aktiv)
--    fc_dave  – Berater ohne Verbindung
-- =====================================================================

begin;

select plan(6);

select tests.create_supabase_user('fc_alice', 'fc-alice@example.test');
select tests.create_supabase_user('fc_carol', 'fc-carol@example.test');
select tests.create_supabase_user('fc_dave',  'fc-dave@example.test');

select tests.authenticate_as_service_role();
update public.profiles set role = 'advisor'
 where user_id in (tests.get_supabase_uid('fc_carol'), tests.get_supabase_uid('fc_dave'));
insert into public.advisor_clients (advisor_id, user_id, status, invited_email, accepted_at) values
  (tests.get_supabase_uid('fc_carol'), tests.get_supabase_uid('fc_alice'), 'active', 'fc-alice@example.test', now());

insert into public.accounts (id, user_id, name, type, currency, provider, provider_account_id) values
  ('fc000000-0000-4000-8000-000000000001', tests.get_supabase_uid('fc_alice'), 'Giro EUR', 'checking', 'EUR', 'manual', null),
  ('fc000000-0000-4000-8000-000000000002', tests.get_supabase_uid('fc_alice'), 'Konto CHF', 'checking', 'CHF', 'manual', null),
  ('fc000000-0000-4000-8000-000000000003', tests.get_supabase_uid('fc_alice'), 'Bank sync', 'checking', 'EUR', 'gocardless', 'ext-fc');

insert into public.transactions (user_id, account_id, booking_date, amount, currency)
select tests.get_supabase_uid('fc_alice'), a, '2026-09-01', v, c
  from (values
    ('fc000000-0000-4000-8000-000000000001'::uuid, -10.00, 'EUR'),
    ('fc000000-0000-4000-8000-000000000001',       120.00, 'CHF'),
    ('fc000000-0000-4000-8000-000000000001',       -20.00, 'CHF'),
    ('fc000000-0000-4000-8000-000000000001',         5.00, 'USD'),
    ('fc000000-0000-4000-8000-000000000001',        -5.00, 'USD'),  -- Summe 0 → entfällt
    ('fc000000-0000-4000-8000-000000000002',        30.00, 'CHF'),  -- Kontowährung
    ('fc000000-0000-4000-8000-000000000002',        -7.50, 'EUR'),
    ('fc000000-0000-4000-8000-000000000003',        50.00, 'CHF')   -- synchronisiert → entfällt
  ) as v (a, v, c);

prepare totals(uuid) as
  select account_id, currency, total from public.account_foreign_currency_totals($1);

select tests.authenticate_as('fc_alice');
select results_eq(
  format('execute totals(%L)', tests.get_supabase_uid('fc_alice')),
  $$ values ('fc000000-0000-4000-8000-000000000001'::uuid, 'CHF'::text, 100.00::numeric),
            ('fc000000-0000-4000-8000-000000000002'::uuid, 'EUR'::text,  -7.50::numeric) $$,
  'Je Konto nur Fremdwährungen; Summe 0 und synchronisierte Konten entfallen'
);
select results_eq(
  $$ select balance from public.accounts
      where id in ('fc000000-0000-4000-8000-000000000001', 'fc000000-0000-4000-8000-000000000002') order by id $$,
  $$ values (-10.00::numeric), (30.00::numeric) $$,
  'Saldo enthält nur Buchungen in Kontowährung (Gegenprobe)'
);

select tests.authenticate_as('fc_carol');
select results_eq(
  format('execute totals(%L)', tests.get_supabase_uid('fc_alice')),
  $$ values ('fc000000-0000-4000-8000-000000000001'::uuid, 'CHF'::text, 100.00::numeric),
            ('fc000000-0000-4000-8000-000000000002'::uuid, 'EUR'::text,  -7.50::numeric) $$,
  'Beraterin mit aktiver Verbindung sieht dieselben Summen'
);

select tests.authenticate_as('fc_dave');
select is_empty(
  format('execute totals(%L)', tests.get_supabase_uid('fc_alice')),
  'Berater ohne Verbindung: leer'
);

select tests.authenticate_as_service_role();
select ok(
  not has_function_privilege('anon', 'public.account_foreign_currency_totals(uuid)', 'execute'),
  'anon darf die Funktion nicht ausführen'
);
select ok(
  has_function_privilege('authenticated', 'public.account_foreign_currency_totals(uuid)', 'execute'),
  'authenticated darf die Funktion ausführen'
);

select * from finish();
rollback;
