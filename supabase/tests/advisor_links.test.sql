-- =====================================================================
--  supabase/tests/advisor_links.test.sql
--  Beraterbereich: Einladungen zurückziehen, Zugriff beenden/widerrufen
--  Ausführen: supabase test db   (setzt 00000-test-helpers.sql voraus)
--
--  Prüft die Abfragen der Oberfläche (lib/actions/advisor-links.ts,
--  app/[locale]/advisor, app/[locale]/dashboard/advisors):
--    UPDATE advisor_clients SET status = 'revoked'
--     WHERE id = … AND advisor_id|user_id = eigener Nutzer AND status = …
--
--  Identitäten
--    al_carol – Beraterin      al_dave – anderer Berater
--    al_alice – Mandantin von Carol (aktiv)
--    al_bob   – Mandant ohne Verbindung
-- =====================================================================

begin;

select plan(14);

select tests.create_supabase_user('al_carol', 'al-carol@example.test');
select tests.create_supabase_user('al_dave',  'al-dave@example.test');
select tests.create_supabase_user('al_alice', 'al-alice@example.test');
select tests.create_supabase_user('al_bob',   'al-bob@example.test');

select tests.authenticate_as_service_role();

update public.profiles set role = 'advisor', first_name = 'Carol', last_name = 'Beraterin'
 where user_id = tests.get_supabase_uid('al_carol');
update public.profiles set role = 'advisor' where user_id = tests.get_supabase_uid('al_dave');
update public.profiles set first_name = 'Alice', last_name = 'Mandantin'
 where user_id = tests.get_supabase_uid('al_alice');

insert into public.advisor_clients (id, advisor_id, user_id, status, invited_email, accepted_at) values
  ('a1c00000-0000-4000-8000-000000000001', tests.get_supabase_uid('al_carol'),
   tests.get_supabase_uid('al_alice'), 'active', 'al-alice@example.test', now());
insert into public.advisor_clients (id, advisor_id, status, invited_email, invite_token_hash, invite_expires_at) values
  ('a1c00000-0000-4000-8000-000000000002', tests.get_supabase_uid('al_carol'), 'invited',
   'neu@example.test', repeat('c', 64), now() + interval '7 days');

insert into public.accounts (id, user_id, name, type) values
  ('a1c00000-0000-4000-8000-000000000003', tests.get_supabase_uid('al_alice'), 'Giro', 'checking');

-- ---------------------------------------------------------------------
-- 1. Sichtbarkeit wie in der Oberfläche (1–4)
-- ---------------------------------------------------------------------
select tests.authenticate_as('al_carol');

select results_eq(
  $$ select ac.status::text, p.first_name
       from public.advisor_clients ac
       left join public.profiles p on p.user_id = ac.user_id
      where ac.advisor_id = auth.uid() and ac.status in ('active', 'invited')
      order by ac.status $$,
  $$ values ('invited'::text, null::text), ('active', 'Alice') $$,
  'Beraterin sieht aktiven Mandanten (mit Namen) und offene Einladung'
);
select is(
  (select count(*)::int from public.accounts where user_id = tests.get_supabase_uid('al_alice')),
  1,
  'Beraterin liest Daten der aktiven Mandantin'
);

select tests.authenticate_as('al_alice');
select is(
  (select p.first_name from public.advisor_clients ac
     join public.profiles p on p.user_id = ac.advisor_id
    where ac.user_id = auth.uid() and ac.status = 'active'),
  'Carol',
  'Mandantin sieht ihre Beraterin mit Namen'
);

select tests.authenticate_as('al_dave');
select is(
  (select count(*)::int from public.advisor_clients),
  0,
  'Anderer Berater sieht Carols Verbindungen nicht'
);

-- ---------------------------------------------------------------------
-- 2. Unbeteiligte ändern nichts (5–6)
-- ---------------------------------------------------------------------
select is_empty(
  $$ update public.advisor_clients set status = 'revoked'
      where id = 'a1c00000-0000-4000-8000-000000000001' returning id $$,
  'Anderer Berater kann die Verbindung nicht beenden (0 Zeilen)'
);
select tests.authenticate_as('al_bob');
select is_empty(
  $$ update public.advisor_clients set status = 'revoked'
      where id = 'a1c00000-0000-4000-8000-000000000002' returning id $$,
  'Unbeteiligter Mandant kann die Einladung nicht zurückziehen (0 Zeilen)'
);

-- ---------------------------------------------------------------------
-- 3. Beraterin zieht Einladung zurück (7–8)
-- ---------------------------------------------------------------------
select tests.authenticate_as('al_carol');
select results_eq(
  $$ update public.advisor_clients set status = 'revoked'
      where id = 'a1c00000-0000-4000-8000-000000000002'
        and advisor_id = auth.uid() and status = 'invited'
      returning status::text, invite_token_hash is null, revoked_at is not null $$,
  $$ values ('revoked'::text, true, true) $$,
  'Einladung zurückgezogen: Status revoked, Token-Hash gelöscht, revoked_at gesetzt'
);
select is_empty(
  $$ update public.advisor_clients set status = 'revoked'
      where id = 'a1c00000-0000-4000-8000-000000000002'
        and advisor_id = auth.uid() and status = 'invited'
      returning id $$,
  'Zweites Zurückziehen trifft keine Zeile mehr (UI meldet „nicht mehr vorhanden“)'
);

-- ---------------------------------------------------------------------
-- 4. Mandantin widerruft den Zugriff (9–12)
-- ---------------------------------------------------------------------
select tests.authenticate_as('al_alice');
select results_eq(
  $$ update public.advisor_clients set status = 'revoked'
      where id = 'a1c00000-0000-4000-8000-000000000001'
        and user_id = auth.uid() and status = 'active'
      returning status::text $$,
  $$ values ('revoked'::text) $$,
  'Mandantin widerruft den Zugriff ihrer Beraterin'
);

select tests.authenticate_as('al_carol');
select is(
  (select count(*)::int from public.accounts where user_id = tests.get_supabase_uid('al_alice')),
  0,
  'Nach dem Widerruf sieht die Beraterin keine Daten der Mandantin mehr'
);
select is(
  (select count(*)::int from public.profiles where user_id = tests.get_supabase_uid('al_alice')),
  0,
  'Nach dem Widerruf ist auch das Profil der Mandantin nicht mehr lesbar'
);
select throws_ok(
  $$ update public.advisor_clients set status = 'active'
      where id = 'a1c00000-0000-4000-8000-000000000001' $$,
  '42501', null,
  'Widerrufene Verbindung lässt sich nicht wieder aktivieren'
);

-- ---------------------------------------------------------------------
-- 5. Beraterin beendet eine aktive Verbindung (13–14)
-- ---------------------------------------------------------------------
select tests.authenticate_as_service_role();
insert into public.advisor_clients (id, advisor_id, user_id, status, invited_email, accepted_at) values
  ('a1c00000-0000-4000-8000-000000000004', tests.get_supabase_uid('al_carol'),
   tests.get_supabase_uid('al_bob'), 'active', 'al-bob@example.test', now());

select tests.authenticate_as('al_carol');
select results_eq(
  $$ update public.advisor_clients set status = 'revoked'
      where id = 'a1c00000-0000-4000-8000-000000000004'
        and advisor_id = auth.uid() and status = 'active'
      returning status::text $$,
  $$ values ('revoked'::text) $$,
  'Beraterin beendet den Zugriff auf einen Mandanten'
);
select is(
  (select count(*)::int from public.profiles where user_id = tests.get_supabase_uid('al_bob')),
  0,
  'Danach ist der Mandant für die Beraterin nicht mehr lesbar'
);

select * from finish();
rollback;
