-- =====================================================================
--  supabase/tests/default_category_keys.test.sql
--  Schlüssel der Standardkategorien (Migration 20261002120000)
--  Ausführen: supabase test db   (setzt 00000-test-helpers.sql voraus)
-- =====================================================================

begin;

select plan(8);

select tests.create_supabase_user('dk_alice', 'dk-alice@example.test');

select has_column('public', 'categories', 'default_key', 'categories.default_key vorhanden');

select tests.authenticate_as('dk_alice');

select is(
  (select count(*)::int from public.categories where user_id = auth.uid() and default_key is not null),
  19,
  'Neues Konto: alle 19 Standardkategorien haben einen Schlüssel'
);

select is(
  (select count(distinct default_key)::int from public.categories where user_id = auth.uid()),
  19,
  'Schlüssel sind je Nutzer eindeutig'
);

select results_eq(
  $$ select name, kind::text from public.categories
      where user_id = auth.uid() and default_key in ('groceries', 'salary', 'transfer')
      order by default_key $$,
  $$ values ('Lebensmittel', 'expense'), ('Gehalt & Lohn', 'income'), ('Umbuchung', 'transfer') $$,
  'Schlüssel passen zu Name und Art (groceries, salary, transfer)'
);

select lives_ok(
  $$ insert into public.categories (name, kind) values ('Haustiere', 'expense') $$,
  'Eigene Kategorie ohne Schlüssel anlegbar'
);
select is(
  (select default_key from public.categories where user_id = auth.uid() and name = 'Haustiere'),
  null,
  'Eigene Kategorie hat keinen Schlüssel'
);

select throws_ok(
  $$ insert into public.categories (name, kind, default_key) values ('Doppelt', 'expense', 'groceries') $$,
  '23505', null,
  'Ein Schlüssel kann je Nutzer nur einmal vergeben werden'
);
select throws_ok(
  $$ insert into public.categories (name, kind, default_key) values ('Ungültig', 'expense', 'Groceries!') $$,
  '23514', null,
  'Ungültiges Schlüsselformat wird abgelehnt'
);

select * from finish();
rollback;
