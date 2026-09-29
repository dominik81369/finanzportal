-- =====================================================================
--  supabase/tests/advisor_client_view.test.sql
--  Leseansicht des Beraters auf die Finanzdaten eines Mandanten
--  Ausführen: supabase test db   (setzt 00000-test-helpers.sql voraus)
--
--  Prüft die Abfragen von app/[locale]/advisor/clients/[clientId]/page.tsx
--  (Verbindung, Konten) und transaction-list.ts / form-options.ts
--  (Buchungen, Kategorien, Tags) – jeweils mit user_id = Mandant.
--
--  Identitäten
--    cv_carol – Beraterin, zugleich mit eigenen Daten
--    cv_dave  – anderer Berater
--    cv_alice – aktive Mandantin von Carol
--    cv_bob   – aktiver Mandant von Dave
--    cv_erin  – nur eingeladen (Einladung noch offen)
-- =====================================================================

begin;

select plan(16);

select tests.create_supabase_user('cv_carol', 'cv-carol@example.test');
select tests.create_supabase_user('cv_dave',  'cv-dave@example.test');
select tests.create_supabase_user('cv_alice', 'cv-alice@example.test');
select tests.create_supabase_user('cv_bob',   'cv-bob@example.test');
select tests.create_supabase_user('cv_erin',  'cv-erin@example.test');

select tests.authenticate_as_service_role();

update public.profiles set role = 'advisor'
 where user_id in (tests.get_supabase_uid('cv_carol'), tests.get_supabase_uid('cv_dave'));
update public.profiles set first_name = 'Alice', last_name = 'Mandantin'
 where user_id = tests.get_supabase_uid('cv_alice');

insert into public.advisor_clients (id, advisor_id, user_id, status, invited_email, accepted_at) values
  ('c7000000-0000-4000-8000-000000000001', tests.get_supabase_uid('cv_carol'),
   tests.get_supabase_uid('cv_alice'), 'active', 'cv-alice@example.test', now()),
  ('c7000000-0000-4000-8000-000000000002', tests.get_supabase_uid('cv_dave'),
   tests.get_supabase_uid('cv_bob'), 'active', 'cv-bob@example.test', now());
insert into public.advisor_clients (advisor_id, status, invited_email, invite_token_hash, invite_expires_at) values
  (tests.get_supabase_uid('cv_carol'), 'invited', 'cv-erin@example.test', repeat('e', 64), now() + interval '7 days');

-- Je Nutzer ein Konto mit einer Buchung (Carol hat eigene Finanzdaten).
insert into public.accounts (id, user_id, name, type, currency) values
  ('c7000000-0000-4000-8000-0000000000a1', tests.get_supabase_uid('cv_alice'), 'Alice Giro', 'checking', 'EUR'),
  ('c7000000-0000-4000-8000-0000000000a2', tests.get_supabase_uid('cv_alice'), 'Alice CHF',  'savings',  'CHF'),
  ('c7000000-0000-4000-8000-0000000000b1', tests.get_supabase_uid('cv_bob'),   'Bob Giro',   'checking', 'EUR'),
  ('c7000000-0000-4000-8000-0000000000c1', tests.get_supabase_uid('cv_carol'), 'Carol Giro', 'checking', 'EUR'),
  ('c7000000-0000-4000-8000-0000000000e1', tests.get_supabase_uid('cv_erin'),  'Erin Giro',  'checking', 'EUR');
update public.accounts set archived_at = now() where id = 'c7000000-0000-4000-8000-0000000000a2';

insert into public.transactions (id, user_id, account_id, booking_date, amount, currency, counterparty_name) values
  ('c7000000-0000-4000-8000-000000000a01', tests.get_supabase_uid('cv_alice'),
   'c7000000-0000-4000-8000-0000000000a1', '2026-09-01', -42.50, 'EUR', 'Supermarkt'),
  ('c7000000-0000-4000-8000-000000000a02', tests.get_supabase_uid('cv_alice'),
   'c7000000-0000-4000-8000-0000000000a1', '2026-09-02', 2500, 'EUR', 'Arbeitgeber'),
  ('c7000000-0000-4000-8000-000000000b01', tests.get_supabase_uid('cv_bob'),
   'c7000000-0000-4000-8000-0000000000b1', '2026-09-01', -10, 'EUR', 'Bob-Laden'),
  ('c7000000-0000-4000-8000-000000000c01', tests.get_supabase_uid('cv_carol'),
   'c7000000-0000-4000-8000-0000000000c1', '2026-09-01', -99, 'EUR', 'Carol privat'),
  ('c7000000-0000-4000-8000-000000000e01', tests.get_supabase_uid('cv_erin'),
   'c7000000-0000-4000-8000-0000000000e1', '2026-09-01', -5, 'EUR', 'Erin-Laden');

insert into public.tags (id, user_id, name) values
  ('c7000000-0000-4000-8000-0000000000f1', tests.get_supabase_uid('cv_alice'), 'Urlaub');
insert into public.transaction_tags (user_id, transaction_id, tag_id) values
  (tests.get_supabase_uid('cv_alice'), 'c7000000-0000-4000-8000-000000000a01',
   'c7000000-0000-4000-8000-0000000000f1');

-- ---------------------------------------------------------------------
-- 1. Verbindungsprüfung der Seite (1–4)
-- ---------------------------------------------------------------------
select tests.authenticate_as('cv_carol');

prepare link_for(uuid) as
  select ac.invited_email, p.first_name
    from public.advisor_clients ac
    left join public.profiles p on p.user_id = ac.user_id
   where ac.advisor_id = auth.uid() and ac.user_id = $1 and ac.status = 'active';

select results_eq(
  format('execute link_for(%L)', tests.get_supabase_uid('cv_alice')),
  $$ values ('cv-alice@example.test'::text, 'Alice'::text) $$,
  'Aktive Mandantin: Verbindung mit Namen gefunden'
);
select is_empty(
  format('execute link_for(%L)', tests.get_supabase_uid('cv_bob')),
  'Mandant eines anderen Beraters: keine Verbindung (→ 404)'
);
select is_empty(
  format('execute link_for(%L)', tests.get_supabase_uid('cv_erin')),
  'Nur eingeladen: keine aktive Verbindung (→ 404)'
);
select is_empty(
  format('execute link_for(%L)', tests.get_supabase_uid('cv_carol')),
  'Eigene ID: keine Verbindung (→ 404)'
);

-- ---------------------------------------------------------------------
-- 2. Daten der aktiven Mandantin, gefiltert auf user_id (5–10)
-- ---------------------------------------------------------------------
select results_eq(
  format($$ select name, type::text, currency::text from public.accounts
             where user_id = %L and archived_at is null order by name $$,
         tests.get_supabase_uid('cv_alice')),
  $$ values ('Alice Giro'::text, 'checking'::text, 'EUR'::text) $$,
  'Konten der Mandantin (ohne archivierte)'
);
select results_eq(
  format($$ select counterparty_name, amount from public.transactions
             where user_id = %L order by booking_date desc, created_at desc, id $$,
         tests.get_supabase_uid('cv_alice')),
  $$ values ('Arbeitgeber'::text, 2500.00::numeric), ('Supermarkt', -42.50) $$,
  'Buchungen der Mandantin, neueste zuerst'
);
select results_eq(
  format($$ select t.counterparty_name, tg.name
              from public.transactions t
              join public.transaction_tags tt on tt.transaction_id = t.id
              join public.tags tg on tg.id = tt.tag_id
             where t.user_id = %L $$,
         tests.get_supabase_uid('cv_alice')),
  $$ values ('Supermarkt'::text, 'Urlaub'::text) $$,
  'Tags der Buchungen sind lesbar'
);
select ok(
  (select count(*) from public.categories where user_id = tests.get_supabase_uid('cv_alice')) > 0,
  'Kategorien der Mandantin sind lesbar (Filter-Auswahl)'
);
select is(
  (select count(*)::int from public.transactions
    where user_id = tests.get_supabase_uid('cv_alice')
      and counterparty_name in ('Carol privat', 'Bob-Laden', 'Erin-Laden')),
  0,
  'Filter auf user_id: keine fremden oder eigenen Buchungen in der Mandantenliste'
);
select is(
  (select count(*)::int from public.transactions where user_id = tests.get_supabase_uid('cv_carol')),
  1,
  'Eigene Buchungen der Beraterin bleiben getrennt lesbar'
);

-- ---------------------------------------------------------------------
-- 3. Kein Zugriff ohne aktive Verbindung (11–12)
-- ---------------------------------------------------------------------
select is(
  (select count(*)::int from public.transactions
    where user_id in (tests.get_supabase_uid('cv_bob'), tests.get_supabase_uid('cv_erin'))),
  0,
  'Keine Buchungen fremder Mandanten oder nur Eingeladener'
);
select is(
  (select count(*)::int from public.accounts
    where user_id in (tests.get_supabase_uid('cv_bob'), tests.get_supabase_uid('cv_erin'))),
  0,
  'Keine Konten fremder Mandanten oder nur Eingeladener'
);

-- ---------------------------------------------------------------------
-- 4. Nur lesen (13–14)
-- ---------------------------------------------------------------------
select is_empty(
  $$ update public.transactions set amount = -1
      where id = 'c7000000-0000-4000-8000-000000000a01' returning id $$,
  'Beraterin kann Buchungen der Mandantin nicht ändern (0 Zeilen)'
);
select throws_ok(
  format($$ insert into public.transactions (user_id, account_id, booking_date, amount, currency)
            values (%L, 'c7000000-0000-4000-8000-0000000000a1', '2026-09-03', -1, 'EUR') $$,
         tests.get_supabase_uid('cv_alice')),
  '42501', null,
  'Beraterin kann keine Buchung für die Mandantin anlegen'
);

-- ---------------------------------------------------------------------
-- 5. Nach Widerruf ist alles weg (15–16)
-- ---------------------------------------------------------------------
select tests.authenticate_as('cv_alice');
update public.advisor_clients set status = 'revoked'
 where id = 'c7000000-0000-4000-8000-000000000001';

select tests.authenticate_as('cv_carol');
select is_empty(
  format('execute link_for(%L)', tests.get_supabase_uid('cv_alice')),
  'Nach Widerruf: keine aktive Verbindung (→ 404)'
);
select is(
  (select count(*)::int from public.transactions where user_id = tests.get_supabase_uid('cv_alice'))
  + (select count(*)::int from public.accounts where user_id = tests.get_supabase_uid('cv_alice')),
  0,
  'Nach Widerruf: keine Konten und Buchungen der Mandantin mehr lesbar'
);

select * from finish();
rollback;
