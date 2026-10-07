-- =====================================================================
--  supabase/tests/budget_groups.test.sql
--  50/30/20: categories.budget_group, budget_rule_summary(),
--  set_category_budget_groups()  (Migration 20261002150000)
--  Ausführen: supabase test db   (setzt 00000-test-helpers.sql voraus)
--
--  Identitäten
--    bg_alice – Mandantin mit Buchungen
--    bg_carol – Beraterin von Alice (aktiv)
--    bg_dave  – Berater ohne Verbindung
-- =====================================================================

begin;

select plan(26);

select tests.create_supabase_user('bg_alice', 'bg-alice@example.test');
select tests.create_supabase_user('bg_carol', 'bg-carol@example.test');
select tests.create_supabase_user('bg_dave',  'bg-dave@example.test');

select tests.authenticate_as_service_role();
update public.profiles set role = 'advisor'
 where user_id in (tests.get_supabase_uid('bg_carol'), tests.get_supabase_uid('bg_dave'));
insert into public.advisor_clients (advisor_id, user_id, status, invited_email, accepted_at) values
  (tests.get_supabase_uid('bg_carol'), tests.get_supabase_uid('bg_alice'), 'active', 'bg-alice@example.test', now());

-- ---------------------------------------------------------------------
-- 1. Standardkategorien (1–2)
-- ---------------------------------------------------------------------
select results_eq(
  format($$ select default_key, budget_group::text from public.categories
             where user_id = %L and default_key is not null order by sort_order $$,
         tests.get_supabase_uid('bg_alice')),
  $$ values
    ('salary'::text, null::text), ('investment_income', null), ('rental_income', null), ('other_income', null),
    ('housing', 'needs'), ('groceries', 'needs'), ('mobility', 'needs'), ('insurance', 'needs'),
    ('health', 'needs'), ('leisure_travel', 'wants'), ('subscriptions_media', 'wants'),
    ('shopping', 'wants'), ('education', 'wants'), ('taxes', 'needs'), ('capital_gains_tax', 'needs'), ('other_expenses', 'wants'),
    ('savings_investments', 'savings'), ('loan_repayment', 'savings'), ('transfer', null) $$,
  'Neue Nutzerin: 19 Standardkategorien mit der vereinbarten Zuordnung'
);
select has_type('public', 'budget_group', 'Typ public.budget_group existiert');

-- ---------------------------------------------------------------------
-- 2. Standardwert für eigene Kategorien (3–8)
-- ---------------------------------------------------------------------
select tests.authenticate_as('bg_alice');
create temp table ids as
select
  (select id from public.categories where default_key = 'salary')              as salary,
  (select id from public.categories where default_key = 'housing')             as housing,
  (select id from public.categories where default_key = 'groceries')           as groceries,
  (select id from public.categories where default_key = 'leisure_travel')      as leisure,
  (select id from public.categories where default_key = 'shopping')            as shopping,
  (select id from public.categories where default_key = 'savings_investments') as savings,
  (select id from public.categories where default_key = 'transfer')            as transfer;
grant select on ids to authenticated, service_role;

insert into public.categories (name, kind) values ('Haustier', 'expense'), ('Depotübertrag', 'transfer'), ('Bonus', 'income');
insert into public.categories (name, kind, parent_category_id)
  select 'Nebenkosten', 'expense', housing from ids;
insert into public.categories (name, kind, budget_group) values ('Notgroschen', 'expense', 'savings');

select results_eq(
  $$ select name, budget_group::text from public.categories
      where name in ('Haustier', 'Depotübertrag', 'Bonus', 'Nebenkosten', 'Notgroschen') order by name $$,
  $$ values ('Bonus'::text, null::text), ('Depotübertrag', null), ('Haustier', 'wants'),
            ('Nebenkosten', 'needs'), ('Notgroschen', 'savings') $$,
  'Eigene Kategorien: Ausgabe → wants, Transfer/Einkommen → NULL, Unterkategorie erbt, expliziter Wert bleibt'
);
select throws_ok(
  $$ insert into public.categories (name, kind, budget_group) values ('Falsch', 'income', 'wants') $$,
  '23514', null,
  'Einkommenskategorie mit Gruppe wird abgewiesen'
);

-- set_category_budget_groups
select is(
  public.set_category_budget_groups(jsonb_build_array(
    jsonb_build_object('id', (select groceries from ids), 'budget_group', 'needs'),   -- unverändert
    jsonb_build_object('id', (select id from public.categories where name = 'Haustier'), 'budget_group', 'needs'))),
  1,
  'set_category_budget_groups ändert nur abweichende Zuordnungen (1)'
);
select throws_ok(
  $$ select public.set_category_budget_groups('[{"id": "kein-uuid", "budget_group": "needs"}]') $$,
  '22023', 'invalid_assignments',
  'Ungültige ID → invalid_assignments'
);
select throws_ok(
  format($$ select public.set_category_budget_groups('[{"id": "%s", "budget_group": "luxus"}]') $$,
         (select housing from ids)),
  '22023', 'invalid_assignments',
  'Ungültige Gruppe → invalid_assignments'
);
select throws_ok(
  format($$ select public.set_category_budget_groups('[{"id": "%s", "budget_group": "wants"}]') $$,
         (select salary from ids)),
  '23514', null,
  'Einkommenskategorie lässt sich keiner Gruppe zuordnen'
);

-- ---------------------------------------------------------------------
-- 3. Auswertung (9–15)
-- ---------------------------------------------------------------------
insert into public.accounts (id, name, type, currency) values
  ('b9000000-0000-4000-8000-000000000001', 'Giro', 'checking', 'EUR'),
  ('b9000000-0000-4000-8000-000000000002', 'Konto CH', 'checking', 'CHF');

insert into public.transactions (account_id, booking_date, amount, currency, category_id, exclude_from_budget)
select 'b9000000-0000-4000-8000-000000000001', d, a, 'EUR', c, x
  from ids, lateral (values
    ('2026-09-01'::date,  3000.00, salary,    false),  -- Einkommen
    ('2026-09-03',       -1000.00, housing,   false),  -- needs
    ('2026-09-04',        -500.00, groceries, false),  -- needs
    ('2026-09-05',        -300.00, leisure,   false),  -- wants
    ('2026-09-06',          50.00, shopping,  false),  -- Erstattung mindert wants
    ('2026-09-07',        -600.00, savings,   false),  -- savings
    ('2026-09-08',        -200.00, transfer,  false),  -- zählt nicht
    ('2026-09-09',         -40.00, null,      false),  -- nicht zugeordnet
    ('2026-09-10',          25.00, null,      false),  -- zählt nirgends
    ('2026-09-11',        -999.00, leisure,   true),   -- exclude_from_budget
    ('2026-10-02',         -70.00, groceries, false)
  ) as v (d, a, c, x);
insert into public.transactions (account_id, booking_date, amount, currency, category_id)
select 'b9000000-0000-4000-8000-000000000002', d, a, 'CHF', c
  from ids, lateral (values
    ('2026-09-01'::date, 1000.00, salary),
    ('2026-09-15',       -100.00, groceries)
  ) as v (d, a, c);

prepare summary(uuid, date, date) as
  select month, currency, income, needs, wants, savings, unassigned
    from public.budget_rule_summary($1, $2, $3);

select results_eq(
  format($$ execute summary(%L, '2026-09-01', '2026-10-31') $$, tests.get_supabase_uid('bg_alice')),
  $$ values
    ('2026-09-01'::date, 'CHF'::text, 1000.00::numeric, 100.00::numeric, 0::numeric, 0::numeric, 0::numeric),
    ('2026-09-01',       'EUR',       3000.00,          1500.00,         250.00,      600.00,      40.00),
    ('2026-10-01',       'EUR',       0,                70.00,           0,           0,           0) $$,
  'Je Monat und Währung: Einkommen, needs, wants (netto), savings, nicht zugeordnet'
);
select results_eq(
  format($$ execute summary(%L, '2026-10-01', '2026-10-31') $$, tests.get_supabase_uid('bg_alice')),
  $$ values ('2026-10-01'::date, 'EUR'::text, 0::numeric, 70.00::numeric, 0::numeric, 0::numeric, 0::numeric) $$,
  'Zeitraum begrenzt die Buchungen'
);
select is_empty(
  format($$ execute summary(%L, '2026-01-01', '2026-01-31') $$, tests.get_supabase_uid('bg_alice')),
  'Monat ohne Buchungen: keine Zeile'
);
select throws_ok(
  format($$ select * from public.budget_rule_summary(%L, '2026-10-01', '2026-09-01') $$, tests.get_supabase_uid('bg_alice')),
  '22023', 'invalid_period', 'von nach bis → invalid_period'
);
select throws_ok(
  format($$ select * from public.budget_rule_summary(%L, '2020-01-01', '2026-01-02') $$, tests.get_supabase_uid('bg_alice')),
  '22023', 'invalid_period', 'mehr als 5 Jahre → invalid_period'
);
select throws_ok(
  $$ select * from public.budget_rule_summary(null, '2026-09-01', '2026-09-30') $$,
  '22023', 'invalid_period', 'ohne Nutzer → invalid_period'
);

-- Ausschließen per Zuordnung: Lebensmittel zählt danach nicht mehr.
select public.set_category_budget_groups(jsonb_build_array(
  jsonb_build_object('id', (select groceries from ids), 'budget_group', null)));
select results_eq(
  format($$ select needs from public.budget_rule_summary(%L, '2026-09-01', '2026-09-30') where currency = 'EUR' $$,
         tests.get_supabase_uid('bg_alice')),
  $$ values (1000.00::numeric) $$,
  'Kategorie ausgeschlossen (NULL): ihre Buchungen zählen nicht mehr'
);

-- ---------------------------------------------------------------------
-- 4. Berater (16–19)
-- ---------------------------------------------------------------------
select tests.authenticate_as('bg_carol');
select results_eq(
  format($$ select currency, income, needs from public.budget_rule_summary(%L, '2026-09-01', '2026-09-30') $$,
         tests.get_supabase_uid('bg_alice')),
  $$ values ('CHF'::text, 1000.00::numeric, 0::numeric), ('EUR', 3000.00, 1000.00) $$,
  'Beraterin mit aktiver Verbindung sieht die Auswertung der Mandantin'
);
select is(
  public.set_category_budget_groups(jsonb_build_array(
    jsonb_build_object('id', (select housing from ids), 'budget_group', 'wants'))),
  0,
  'Beraterin kann die Zuordnung der Mandantin nicht ändern (0)'
);
select tests.authenticate_as('bg_dave');
select is_empty(
  format($$ select * from public.budget_rule_summary(%L, '2026-09-01', '2026-10-31') $$,
         tests.get_supabase_uid('bg_alice')),
  'Berater ohne Verbindung: leeres Ergebnis'
);
select tests.authenticate_as_service_role();
select is(
  (select budget_group::text from public.categories c, ids where c.id = ids.housing),
  'needs',
  'Zuordnung der Mandantin unverändert'
);

-- ---------------------------------------------------------------------
-- 5. Rechte, Bestand, service_role (20–26)
-- ---------------------------------------------------------------------
select ok(
  not has_function_privilege('anon', 'public.budget_rule_summary(uuid, date, date)', 'execute'),
  'anon darf budget_rule_summary nicht ausführen'
);
select ok(
  not has_function_privilege('anon', 'public.set_category_budget_groups(jsonb)', 'execute'),
  'anon darf set_category_budget_groups nicht ausführen'
);
select is(
  (select count(*)::int from public.categories where kind = 'income' and budget_group is not null),  -- Check-Constraint, global gültig
  0,
  'Keine Einkommenskategorie hat eine Gruppe'
);
select is(
  (select count(*)::int from public.categories c
     join (values
       ('housing', 'needs'), ('groceries', 'needs'), ('mobility', 'needs'), ('insurance', 'needs'),
       ('health', 'needs'), ('taxes', 'needs'), ('leisure_travel', 'wants'),
       ('subscriptions_media', 'wants'), ('shopping', 'wants'), ('education', 'wants'),
       ('other_expenses', 'wants'), ('savings_investments', 'savings'), ('loan_repayment', 'savings'),
       ('transfer', null), ('salary', null), ('investment_income', null), ('rental_income', null),
       ('other_income', null)
     ) as m (default_key, budget_group) using (default_key)
    where c.budget_group::text is distinct from m.budget_group
      and c.user_id in (tests.get_supabase_uid('bg_carol'), tests.get_supabase_uid('bg_dave'))),
  0,
  'Standardkategorien der übrigen Testnutzer tragen die Standardzuordnung'
);
select lives_ok(
  format($$ insert into public.categories (user_id, name, kind) values (%L, 'Per Service', 'expense') $$,
         tests.get_supabase_uid('bg_dave')),
  'service_role kann Kategorien anlegen (Trigger läuft als SECURITY DEFINER)'
);
select is(
  (select budget_group::text from public.categories where name = 'Per Service'),
  'wants',
  'Auch per service_role angelegt: Standard wants'
);
select is(
  (select count(*)::int from public.categories where kind = 'expense' and budget_group is null
      and user_id in (tests.get_supabase_uid('bg_carol'), tests.get_supabase_uid('bg_dave'))),
  0,
  'Keine Ausgabenkategorie der übrigen Testnutzer ist ohne Gruppe'
);

select * from finish();
rollback;
