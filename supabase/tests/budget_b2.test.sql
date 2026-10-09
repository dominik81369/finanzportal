-- =====================================================================
--  supabase/tests/budget_b2.test.sql
--  Budget-2: Einzelbudgets je Kategorie – save_category_budget(), ein
--  Budget je Kategorie, Mandantentrennung und Beraterzugriff, Wegfall von
--  budget_rule_summary() (Migration 20261012100000)
--  Ausführen: supabase test db   (setzt 00000-test-helpers.sql voraus)
--
--  Identitäten
--    b2b_alice – Nutzerin mit Budgets
--    b2b_bob   – anderer Nutzer
--    b2b_carol – Beraterin, aktive Verbindung zu Alice
--    b2b_dave  – Berater ohne Verbindung
-- =====================================================================

begin;

select plan(36);

select tests.create_supabase_user('b2b_alice', 'b2b-alice@example.test');
select tests.create_supabase_user('b2b_bob',   'b2b-bob@example.test');
select tests.create_supabase_user('b2b_carol', 'b2b-carol@example.test');
select tests.create_supabase_user('b2b_dave',  'b2b-dave@example.test');

select tests.authenticate_as_service_role();
update public.profiles set role = 'advisor'
 where user_id in (tests.get_supabase_uid('b2b_carol'), tests.get_supabase_uid('b2b_dave'));
insert into public.advisor_clients (advisor_id, user_id, status, invited_email, accepted_at) values
  (tests.get_supabase_uid('b2b_carol'), tests.get_supabase_uid('b2b_alice'), 'active', 'b2b-alice@example.test', now());

-- ---------------------------------------------------------------------
-- 1. Schema (1–4)
-- ---------------------------------------------------------------------
select ok(
  to_regprocedure('public.save_category_budget(uuid, uuid, public.budget_period, numeric, public.currency_code, integer)') is not null,
  'save_category_budget vorhanden'
);
select ok(to_regprocedure('public.budget_rule_summary(uuid, date, date)') is null, 'budget_rule_summary entfernt');
select ok(to_regclass('public.budgets_category_unique') is not null, 'Unique-Index budgets_category_unique vorhanden');
select ok(
  not has_function_privilege('anon',
    'public.save_category_budget(uuid, uuid, public.budget_period, numeric, public.currency_code, integer)', 'execute'),
  'anon darf save_category_budget nicht ausführen'
);

-- ---------------------------------------------------------------------
-- 2. Anlegen und Prüfungen (5–19)
-- ---------------------------------------------------------------------
select tests.authenticate_as('b2b_alice');

select isnt(
  public.save_category_budget(null, (select id from public.categories where default_key = 'groceries'),
                              'monthly', 400, 'EUR', 80),
  null, 'Monatsbudget für Lebensmittel angelegt'
);
select results_eq(
  $$ select name, period::text, amount, currency::text, alert_threshold_pct::integer, is_active, tag_id, account_id
       from public.budgets $$,
  $$ values ('Lebensmittel'::text, 'monthly'::text, 400.00::numeric, 'EUR'::text, 80, true, null::uuid, null::uuid) $$,
  'Name folgt der Kategorie, Werte wie übergeben'
);
select lives_ok(
  $$ select public.save_category_budget(null, (select id from public.categories where default_key = 'leisure_travel'),
                                        'yearly', 2400, 'EUR', 90) $$,
  'Jahresbudget angelegt'
);
select throws_ok(
  $$ select public.save_category_budget(null, (select id from public.categories where default_key = 'groceries'),
                                        'yearly', 100, 'EUR', 80) $$,
  '23505', 'budget_exists', 'Zweites Budget für dieselbe Kategorie abgelehnt'
);
select throws_ok(
  $$ select public.save_category_budget(null, (select id from public.categories where default_key = 'shopping'),
                                        'weekly', 100, 'EUR', 80) $$,
  '22023', 'invalid_period', 'Woche (noch) nicht erlaubt'
);
select throws_ok(
  $$ select public.save_category_budget(null, (select id from public.categories where default_key = 'shopping'),
                                        'quarterly', 100, 'EUR', 80) $$,
  '22023', 'invalid_period', 'Quartal (noch) nicht erlaubt'
);
select throws_ok(
  $$ select public.save_category_budget(null, (select id from public.categories where default_key = 'shopping'),
                                        'monthly', 0, 'EUR', 80) $$,
  '22023', 'invalid_amount', 'Betrag 0 abgelehnt'
);
select throws_ok(
  $$ select public.save_category_budget(null, (select id from public.categories where default_key = 'shopping'),
                                        'monthly', 10.005, 'EUR', 80) $$,
  '22023', 'invalid_amount', 'Mehr als zwei Nachkommastellen abgelehnt'
);
select throws_ok(
  $$ select public.save_category_budget(null, (select id from public.categories where default_key = 'shopping'),
                                        'monthly', 100, 'EUR', 0) $$,
  '22023', 'invalid_threshold', 'Schwelle 0 abgelehnt'
);
select throws_ok(
  $$ select public.save_category_budget(null, (select id from public.categories where default_key = 'shopping'),
                                        'monthly', 100, 'EUR', 101) $$,
  '22023', 'invalid_threshold', 'Schwelle über 100 abgelehnt'
);
select throws_ok(
  $$ select public.save_category_budget(null, (select id from public.categories where default_key = 'shopping'),
                                        'monthly', 100, null, 80) $$,
  '22023', 'invalid_currency', 'Ohne Währung abgelehnt'
);
select throws_ok(
  $$ select public.save_category_budget(null, (select id from public.categories where default_key = 'salary'),
                                        'monthly', 100, 'EUR', 80) $$,
  '22023', 'invalid_category', 'Einkommenskategorie abgelehnt'
);
select throws_ok(
  $$ select public.save_category_budget(null, (select id from public.categories where default_key = 'savings_investments'),
                                        'monthly', 100, 'EUR', 80) $$,
  '22023', 'invalid_category', 'Umbuchungskategorie (Sparen & Investieren) abgelehnt'
);
select throws_ok(
  $$ select public.save_category_budget(null, null, 'monthly', 100, 'EUR', 80) $$,
  '22023', 'invalid_category', 'Ohne Kategorie abgelehnt'
);

-- Unterkategorie: eigenes Budget erlaubt (Hinweise macht die App).
insert into public.categories (name, kind, parent_category_id)
select 'Restaurant', 'expense', id from public.categories where default_key = 'leisure_travel';
select lives_ok(
  $$ select public.save_category_budget(null, (select id from public.categories where name = 'Restaurant'),
                                        'monthly', 300, 'EUR', 80) $$,
  'Budget auf Unterkategorie neben dem Budget der Oberkategorie erlaubt'
);

-- ---------------------------------------------------------------------
-- 3. Ändern (20–24)
-- ---------------------------------------------------------------------
select set_config('test.groceries_budget',
  (select b.id::text from public.budgets b join public.categories c on c.id = b.category_id
    where c.default_key = 'groceries'), true);

select is(
  public.save_category_budget(current_setting('test.groceries_budget')::uuid,
    (select id from public.categories where default_key = 'groceries'), 'yearly', 5000.5, 'CHF', 75),
  current_setting('test.groceries_budget')::uuid,
  'Ändern liefert dieselbe ID'
);
select results_eq(
  format($$ select period::text, amount, currency::text, alert_threshold_pct::integer from public.budgets where id = %L $$,
         current_setting('test.groceries_budget')),
  $$ values ('yearly'::text, 5000.50::numeric, 'CHF'::text, 75) $$,
  'Zeitraum, Betrag, Währung und Schwelle geändert'
);
select throws_ok(
  format($$ select public.save_category_budget(%L, (select id from public.categories where default_key = 'leisure_travel'),
                                               'monthly', 100, 'EUR', 80) $$,
         current_setting('test.groceries_budget')),
  '23505', 'budget_exists', 'Wechsel auf eine Kategorie mit Budget abgelehnt'
);
select throws_ok(
  $$ select public.save_category_budget('00000000-0000-4000-8000-0000000000b2',
       (select id from public.categories where default_key = 'shopping'), 'monthly', 100, 'EUR', 80) $$,
  'P0002', 'budget_not_found', 'Unbekannte ID → budget_not_found'
);
select throws_ok(
  $$ insert into public.budgets (name, category_id, amount)
     select 'Doppelt', id, 50 from public.categories where default_key = 'leisure_travel' $$,
  '23505', null, 'Auch direkt: ein Budget je Kategorie (Unique-Index)'
);

-- Tagbudgets sind vom Index nicht betroffen.
insert into public.tags (name) values ('Urlaub');
select lives_ok(
  $$ insert into public.budgets (name, tag_id, amount)
     select n, (select id from public.tags where name = 'Urlaub'), 100 from (values ('Tag A'), ('Tag B')) v (n) $$,
  'Mehrere Budgets je Tag bleiben möglich'
);

-- ---------------------------------------------------------------------
-- 4. Andere Nutzer und Berater (26–33)
-- ---------------------------------------------------------------------
select tests.authenticate_as('b2b_bob');
select is_empty($$ select 1 from public.budgets $$, 'Bob sieht keine fremden Budgets');
select throws_ok(
  format($$ select public.save_category_budget(null, %L, 'monthly', 100, 'EUR', 80) $$,
         (select id from public.categories where user_id = tests.get_supabase_uid('b2b_alice') and default_key = 'shopping')),
  '22023', 'invalid_category', 'Bob kann kein Budget auf Alices Kategorie anlegen'
);
select throws_ok(
  format($$ select public.save_category_budget(%L, (select id from public.categories where default_key = 'shopping'),
                                               'monthly', 1, 'EUR', 80) $$,
         current_setting('test.groceries_budget')),
  'P0002', 'budget_not_found', 'Bob kann Alices Budget nicht ändern'
);
with d as (delete from public.budgets where id = current_setting('test.groceries_budget')::uuid returning 1)
select is(count(*)::integer, 0, 'Bob kann Alices Budget nicht löschen') from d;

select tests.authenticate_as('b2b_carol');
select is((select count(*)::integer from public.budgets), 5, 'Beraterin sieht die Budgets der Mandantin');
select throws_ok(
  format($$ select public.save_category_budget(null, %L, 'monthly', 100, 'EUR', 80) $$,
         (select id from public.categories where user_id = tests.get_supabase_uid('b2b_alice') and default_key = 'shopping')),
  '22023', 'invalid_category', 'Beraterin kann kein Budget für die Mandantin anlegen'
);
with u as (update public.budgets set amount = 1 where id = current_setting('test.groceries_budget')::uuid returning 1)
select is(count(*)::integer, 0, 'Beraterin kann Budgets der Mandantin nicht ändern') from u;

select tests.authenticate_as('b2b_dave');
select is_empty($$ select 1 from public.budgets $$, 'Berater ohne Verbindung sieht keine Budgets');

-- ---------------------------------------------------------------------
-- 5. Löschen durch die Eigentümerin (34–36)
-- ---------------------------------------------------------------------
select tests.authenticate_as('b2b_alice');
with d as (delete from public.budgets where id = current_setting('test.groceries_budget')::uuid returning 1)
select is(count(*)::integer, 1, 'Alice löscht ihr Budget') from d;
select lives_ok(
  $$ select public.save_category_budget(null, (select id from public.categories where default_key = 'groceries'),
                                        'monthly', 450, 'EUR', 80) $$,
  'Nach dem Löschen ist die Kategorie wieder frei'
);
select is((select count(*)::integer from public.budgets where category_id is not null), 3, 'Drei Kategoriebudgets');

select * from finish();
rollback;
