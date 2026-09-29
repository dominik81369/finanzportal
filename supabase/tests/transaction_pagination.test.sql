-- =====================================================================
--  supabase/tests/transaction_pagination.test.sql
--  Grundlagen der Seitennavigation der Transaktionsliste
--  Ausführen: supabase test db   (setzt 00000-test-helpers.sql voraus)
--
--  Die App sortiert nach booking_date absteigend, id aufsteigend und
--  blättert per LIMIT/OFFSET (PostgREST .range()). Geprüft wird:
--  - der Index passt genau zu dieser Reihenfolge und wird genutzt,
--  - Seiten sind lückenlos und überschneidungsfrei, auch bei vielen Buchungen
--    mit gleichem Datum (id als Tiebreaker),
--  - Zählen und Blättern sehen nur eigene Buchungen.
-- =====================================================================

begin;

select plan(8);

select tests.create_supabase_user('pg_alice', 'pg-alice@example.test');
select tests.create_supabase_user('pg_bob',   'pg-bob@example.test');

select tests.authenticate_as_service_role();

insert into public.accounts (id, user_id, name, type) values
  ('a1b00000-0000-4000-8000-000000000001', tests.get_supabase_uid('pg_alice'), 'Giro', 'checking'),
  ('b2b00000-0000-4000-8000-000000000001', tests.get_supabase_uid('pg_bob'),   'Giro', 'checking');

-- 23 Buchungen für Alice, nur 3 verschiedene Tage (viele Gleichstände),
-- 5 für Bob.
insert into public.transactions (user_id, account_id, booking_date, amount, counterparty_name)
select tests.get_supabase_uid('pg_alice'), 'a1b00000-0000-4000-8000-000000000001',
       date '2026-09-01' + (n % 3), -n, 'Alice ' || n
  from generate_series(1, 23) as n;
insert into public.transactions (user_id, account_id, booking_date, amount, counterparty_name)
select tests.get_supabase_uid('pg_bob'), 'b2b00000-0000-4000-8000-000000000001',
       date '2026-09-02', -n, 'Bob ' || n
  from generate_series(1, 5) as n;

-- ---------------------------------------------------------------------
-- 1. Index (1–2)
-- ---------------------------------------------------------------------
select is(
  (select pg_get_indexdef('public.transactions_user_id_booking_date_idx'::regclass)),
  'CREATE INDEX transactions_user_id_booking_date_idx ON public.transactions USING btree (user_id, booking_date DESC, id)',
  'Index (user_id, booking_date DESC, id) passt zur Sortierung der Liste'
);

-- Ausführungsplan als Text (für die Prüfung, ob der Index die Sortierung liefert).
create function pg_temp.query_plan(q text) returns text
language plpgsql as $$
declare
  line text;
  plan text := '';
begin
  for line in execute 'explain ' || q loop
    plan := plan || line || E'\n';
  end loop;
  return plan;
end;
$$;

select tests.authenticate_as('pg_alice');

-- Wie die App: Filter auf die eigene user_id als Literal (.eq('user_id',
-- user.id)), gleiche Sortierung, Seite 2. Sequenzielle Scans aus, weil der
-- Planer bei 28 Zeilen sonst immer die Tabelle liest.
set local enable_seqscan = off;
select ok(
  pg_temp.query_plan(format($q$
    select id from public.transactions
     where user_id = %L
     order by booking_date desc, id asc
     limit 10 offset 10 $q$, tests.get_supabase_uid('pg_alice')))
    ~ 'Index (Only )?Scan using transactions_user_id_booking_date_idx'
  and pg_temp.query_plan(format($q$
    select id from public.transactions
     where user_id = %L
     order by booking_date desc, id asc
     limit 10 offset 10 $q$, tests.get_supabase_uid('pg_alice'))) !~ 'Sort',
  'Seitenabfrage nutzt den Index und braucht keinen eigenen Sortierschritt'
);
reset enable_seqscan;

-- ---------------------------------------------------------------------
-- 2. Lückenlos und überschneidungsfrei (3–5)
-- ---------------------------------------------------------------------
create temporary table pages (page int, pos int, id uuid) on commit drop;

insert into pages
select p, row_number() over (), t.id
  from generate_series(1, 3) as p,
  lateral (
    select id from public.transactions
     where user_id = auth.uid()
     order by booking_date desc, id asc
     limit 10 offset (p - 1) * 10
  ) t;

select is(
  (select count(*)::int from pages),
  23,
  'Drei Seiten à 10 liefern alle 23 Buchungen (10 + 10 + 3)'
);
select is(
  (select count(distinct id)::int from pages),
  23,
  'Keine Buchung erscheint auf zwei Seiten (Tiebreaker id)'
);
select results_eq(
  $$ select id from pages order by page, pos $$,
  $$ select id from public.transactions where user_id = auth.uid() order by booking_date desc, id asc $$,
  'Seiten hintereinander ergeben genau die Gesamtreihenfolge'
);

-- ---------------------------------------------------------------------
-- 3. Nur eigene Buchungen (6–7)
-- ---------------------------------------------------------------------
select is(
  (select count(*)::int from public.transactions where user_id = auth.uid()),
  23,
  'Alice zählt 23 Buchungen'
);
select is(
  (select count(*)::int from public.transactions),
  23,
  'Bobs Buchungen sind für Alice unsichtbar (RLS)'
);

-- ---------------------------------------------------------------------
-- 4. Offset jenseits des Endes (8)
-- ---------------------------------------------------------------------
select is_empty(
  $$ select id from public.transactions where user_id = auth.uid()
      order by booking_date desc, id asc limit 10 offset 30 $$,
  'Seite jenseits des Endes ist leer (die App leitet dann zur letzten Seite)'
);

select * from finish();
rollback;
