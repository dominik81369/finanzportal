-- =====================================================================
--  supabase/tests/password_set_at.test.sql
--  Phase 2 · profiles.password_set_at (Migration 20260928000000)
--  Ausführen: supabase test db   (setzt 00000-test-helpers.sql voraus)
--
--  Spielt die von GoTrue beobachtete UPDATE-Sequenz nach:
--    Einladung   : INSERT, danach UPDATE invited_at
--    Link-Klick  : UPDATE encrypted_password (E-Mail noch unbestätigt),
--                  danach UPDATE email_confirmed_at
--    updateUser  : UPDATE encrypted_password (E-Mail bestätigt)
--
--  Identitäten
--    dana – selbst registriert
--    emil – per Berater-Einladung angelegt
-- =====================================================================

begin;

select plan(9);

select tests.create_supabase_user('dana', 'dana@example.test');
select tests.create_supabase_user('emil', 'emil@example.test');

-- 1. Registrierung → Passwort gilt als gesetzt
select isnt(
  (select password_set_at from public.profiles where user_id = tests.get_supabase_uid('dana')),
  null,
  'Selbst registriertes Konto: password_set_at gesetzt'
);

-- 2. Einladung (GoTrue setzt invited_at per UPDATE nach dem INSERT)
update auth.users set invited_at = now() where id = tests.get_supabase_uid('emil');
select is(
  (select password_set_at from public.profiles where user_id = tests.get_supabase_uid('emil')),
  null,
  'Eingeladenes Konto: password_set_at NULL'
);

-- 3. Link-Klick: GoTrue tauscht den Zufalls-Hash, E-Mail noch unbestätigt
update auth.users
   set encrypted_password = extensions.crypt('zufall', extensions.gen_salt('bf'))
 where id = tests.get_supabase_uid('emil');
update auth.users set email_confirmed_at = now() where id = tests.get_supabase_uid('emil');
select is(
  (select password_set_at from public.profiles where user_id = tests.get_supabase_uid('emil')),
  null,
  'Hash-Tausch beim Einlösen der Einladung zählt nicht als eigenes Passwort'
);

-- 4. updateUser({ password }) bei bestätigter E-Mail
update auth.users
   set encrypted_password = extensions.crypt('ein-sicheres-passwort', extensions.gen_salt('bf'))
 where id = tests.get_supabase_uid('emil');
select isnt(
  (select password_set_at from public.profiles where user_id = tests.get_supabase_uid('emil')),
  null,
  'updateUser(password) nach Bestätigung: password_set_at gesetzt'
);

-- 5./6. Clients können den Wert weder ändern noch beim INSERT vorgeben
select tests.authenticate_as('emil');
select throws_ok(
  $$update public.profiles set password_set_at = null where user_id = auth.uid()$$,
  '42501',
  null,
  'authenticated darf password_set_at nicht ändern'
);
select is(
  (select password_set_at is not null from public.profiles where user_id = auth.uid()),
  true,
  'Eigener Wert ist lesbar'
);

-- 7. Kein Hash-Zugriff für Clients
select throws_ok(
  'select encrypted_password from auth.users',
  '42501',
  null,
  'authenticated kann auth.users weiterhin nicht lesen'
);

-- 8./9. Trigger-Funktionen sind nicht direkt aufrufbar (Prüfung als Owner)
reset role;
select ok(
  not has_function_privilege('authenticated', 'private.handle_auth_user_password_state()', 'execute'),
  'handle_auth_user_password_state() nicht für authenticated ausführbar'
);
select ok(
  not has_function_privilege('authenticated', 'private.profiles_init_password_set_at()', 'execute'),
  'profiles_init_password_set_at() nicht für authenticated ausführbar'
);

select * from finish();

rollback;
