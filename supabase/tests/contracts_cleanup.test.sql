-- =====================================================================
--  supabase/tests/contracts_cleanup.test.sql
--  Verträge – Bereinigung: Verknüpfung ohne Toleranz und Mandat (Band ×1,5,
--  eine Abbuchung je Periode, nächster Betrag zuerst), Betrag folgt den
--  Abbuchungen, sync_contracts(), refresh_contracts() ohne Erkennung,
--  Löschen jedes Vertrags, Gegenparteien fürs Formular, Mandantentrennung
--  und Beraterzugriff (Migration 20261014100000)
--  Ausführen: supabase test db   (setzt 00000-test-helpers.sql voraus)
--
--  Identitäten
--    cl_alice – Nutzerin mit Buchungen
--    cl_bob   – anderer Nutzer
--    cl_carol – Beraterin, aktive Verbindung zu Alice
-- =====================================================================

begin;

select plan(38);

select tests.create_supabase_user('cl_alice', 'cl-alice@example.test');
select tests.create_supabase_user('cl_bob',   'cl-bob@example.test');
select tests.create_supabase_user('cl_carol', 'cl-carol@example.test');

select tests.authenticate_as_service_role();
update public.profiles set role = 'advisor' where user_id = tests.get_supabase_uid('cl_carol');
insert into public.advisor_clients (advisor_id, user_id, status, invited_email, accepted_at) values
  (tests.get_supabase_uid('cl_carol'), tests.get_supabase_uid('cl_alice'), 'active', 'cl-alice@example.test', now());

insert into public.accounts (id, user_id, name, type, currency, provider) values
  ('7e000000-0000-4000-8000-0000000000a1', tests.get_supabase_uid('cl_alice'), 'Giro',     'checking', 'EUR', 'csv'),
  ('7e000000-0000-4000-8000-0000000000b1', tests.get_supabase_uid('cl_bob'),   'Bob Giro', 'checking', 'EUR', 'csv');

create function pg_temp.tx(p_counterparty text, p_purpose text, p_amount numeric, p_date date) returns void language sql as $$
  insert into public.transactions (user_id, account_id, booking_date, amount, currency, counterparty_name, purpose)
  values (tests.get_supabase_uid('cl_alice'), '7e000000-0000-4000-8000-0000000000a1', p_date, p_amount, 'EUR',
          p_counterparty, p_purpose);
$$;
create function pg_temp.key(p_counterparty text) returns text language sql as $$
  select t.counterparty_key from public.transactions t
   where t.user_id = tests.get_supabase_uid('cl_alice') and t.counterparty_name = p_counterparty limit 1;
$$;
create function pg_temp.cid(p_name text) returns uuid language sql as $$
  select rc.id from public.recurring_contracts rc
   where rc.user_id = tests.get_supabase_uid('cl_alice') and rc.name = p_name;
$$;
create function pg_temp.linked(p_name text) returns text language sql as $$
  select string_agg(t.purpose, ', ' order by t.booking_date, t.purpose)
    from public.transactions t
   where t.recurring_contract_id = (select rc.id from public.recurring_contracts rc
                                     where rc.user_id = tests.get_supabase_uid('cl_alice') and rc.name = p_name);
$$;
grant execute on function pg_temp.key(text), pg_temp.cid(text), pg_temp.linked(text) to authenticated;

-- Abo neben Einkäufen bei derselben Gegenpartei
select pg_temp.tx('Versandhaus Nord', 'Gutschrift vor Beginn',  8.99, '2026-02-01');
select pg_temp.tx('Versandhaus Nord', 'Einkauf März',          -9.50, '2026-03-02');
select pg_temp.tx('Versandhaus Nord', 'Abo März',              -8.99, '2026-03-15');
select pg_temp.tx('Versandhaus Nord', 'Abo April',             -8.99, '2026-04-15');
select pg_temp.tx('Versandhaus Nord', 'Einkauf April',        -13.48, '2026-04-28');
select pg_temp.tx('Versandhaus Nord', 'Abo Mai',               -8.99, '2026-05-15');
select pg_temp.tx('Versandhaus Nord', 'Erstattung Mai',         8.99, '2026-05-20');
select pg_temp.tx('Versandhaus Nord', 'Gutschrift groß',       20.00, '2026-05-21');
select pg_temp.tx('Versandhaus Nord', 'Juni +50 %',           -13.48, '2026-06-20');
select pg_temp.tx('Versandhaus Nord', 'Einkauf Juli',         -13.49, '2026-07-20');
select pg_temp.tx('Versandhaus Nord', 'Einkauf August',        -5.99, '2026-08-20');
-- Zwei Verträge derselben Versicherung
select pg_temp.tx('Versicherung Süd', 'Hausrat ' || k, -6.00, ('2026-0' || (k + 2) || '-01')::date) from generate_series(1, 4) k;
select pg_temp.tx('Versicherung Süd', 'Haftpflicht ' || k, -8.50, ('2026-0' || (k + 2) || '-15')::date) from generate_series(1, 3) k;
select pg_temp.tx('Versicherung Süd', 'Haftpflicht neu 1', -8.90, '2026-06-15');
-- Preis weit über dem eingetragenen Betrag (zweiter Durchgang)
select pg_temp.tx('Stadtwerke West', 'Abschlag März',  -14.00, '2026-03-10');
select pg_temp.tx('Stadtwerke West', 'Abschlag April', -14.00, '2026-04-10');
select pg_temp.tx('Stadtwerke West', 'Abschlag Mai',   -20.00, '2026-05-10');
-- Verworfener und gekündigter Vertrag
select pg_temp.tx('Zeitung Ost', 'Zeitung ' || k, -4.99, ('2026-0' || (k + 2) || '-05')::date) from generate_series(1, 3) k;
select pg_temp.tx('Fitness Ost', 'Beitrag ' || k, -29.90, ('2026-0' || (k + 2) || '-03')::date) from generate_series(1, 3) k;
-- Klare Serie ohne Vertrag
select pg_temp.tx('Musikdienst Pro', 'Musik ' || k, -9.99, ('2026-0' || (k + 2) || '-07')::date) from generate_series(1, 6) k;
-- Februar: zweite Abbuchung genau eine halbe Periode später
select pg_temp.tx('Kasse Nord', 'Kasse Feb 1',  -5.00, '2026-02-01');
select pg_temp.tx('Kasse Nord', 'Kasse Feb 15', -5.00, '2026-02-15');
select pg_temp.tx('Kasse Nord', 'Kasse Mär 1',  -5.00, '2026-03-01');
-- Unregelmäßige Einkäufe (viele, aber nicht wiederkehrend)
select pg_temp.tx('Baumarkt Kunz', 'Einkauf ' || k, -(array[5, 7, 10, 13, 17, 25, 40])[k], ('2026-03-01'::date + k * 9)) from generate_series(1, 7) k;

-- ---------------------------------------------------------------------
-- 1. Band ×1,5 und eine Abbuchung je Periode (1–6)
-- ---------------------------------------------------------------------
select tests.authenticate_as('cl_alice');
select public.save_contract(null, 'Versand-Abo', pg_temp.key('Versandhaus Nord'), null, 'monthly', 1, 8.99, null,
                            'subscription', null, null, null);
select is(pg_temp.linked('Versand-Abo'), 'Abo März, Abo April, Abo Mai, Erstattung Mai, Juni +50 %',
  'Abo: je Monat eine Abbuchung im Band, Gegenbuchung im Band ab der ersten Abbuchung');
select is((select count(*)::integer from public.transactions where purpose in ('Einkauf März', 'Einkauf April')
             and recurring_contract_id is not null), 0,
  'Einkäufe in einer Periode mit Abbuchung werden nicht verknüpft (auch im Band)');
select is((select string_agg(purpose, ', ' order by booking_date) from public.transactions
            where purpose in ('Einkauf Juli', 'Einkauf August', 'Gutschrift groß', 'Gutschrift vor Beginn')
              and recurring_contract_id is null),
  'Gutschrift vor Beginn, Gutschrift groß, Einkauf Juli, Einkauf August',
  'Außerhalb des Bands (13,49 und 5,99 zu 8,99; Gutschrift 20,00) und Gegenbuchung vor der ersten Abbuchung bleiben offen');
select is((select expected_amount from public.recurring_contracts where id = pg_temp.cid('Versand-Abo')), -8.99::numeric,
  'Betrag: Median der letzten drei Abbuchungen (eine abweichende verschiebt ihn nicht)');
select is((select first_booking_date || '|' || last_booking_date || '|' || next_expected_date
             from public.recurring_contracts where id = pg_temp.cid('Versand-Abo')),
  '2026-03-15|2026-06-20|2026-07-20', 'Termine aus den verknüpften Abbuchungen');
select public.save_contract(null, 'Kasse', pg_temp.key('Kasse Nord'), null, 'monthly', 1, 5, null, 'other', null, null, null);
select is(pg_temp.linked('Kasse'), 'Kasse Feb 1, Kasse Mär 1',
  'Februar: genau eine halbe Periode Abstand (14 von 28 Tagen) gilt als dieselbe Periode');

-- ---------------------------------------------------------------------
-- 2. Zwei Verträge derselben Gegenpartei, zweiter Durchgang (7–11)
-- ---------------------------------------------------------------------
select public.save_contract(null, 'Hausrat', pg_temp.key('Versicherung Süd'), null, 'monthly', 1, 6, null,
                            'insurance', null, null, null);
select public.save_contract(null, 'Haftpflicht', pg_temp.key('Versicherung Süd'), null, 'monthly', 1, 8.50, null,
                            'insurance', null, null, null);
select is(pg_temp.linked('Hausrat'), 'Hausrat 1, Hausrat 2, Hausrat 3, Hausrat 4',
  'Erster Vertrag: nur seine Abbuchungen (8,50 liegt im Band, aber in derselben Periode)');
select is(pg_temp.linked('Haftpflicht'), 'Haftpflicht 1, Haftpflicht 2, Haftpflicht 3, Haftpflicht neu 1',
  'Zweiter Vertrag: seine Abbuchungen, auch nach der Preisänderung auf 8,90');
select is((select expected_amount from public.recurring_contracts where id = pg_temp.cid('Haftpflicht')), -8.50::numeric,
  'Eine Abbuchung zum neuen Preis ändert den Vertragsbetrag noch nicht');

select public.save_contract(null, 'Strom', pg_temp.key('Stadtwerke West'), null, 'monthly', 1, 10, null,
                            'energy', null, null, null);
select is(pg_temp.linked('Strom'), 'Abschlag März, Abschlag April, Abschlag Mai',
  'Zweiter Durchgang: nach dem Nachführen des Betrags (14,00) fällt 20,00 ins Band');
select is((select expected_amount from public.recurring_contracts where id = pg_temp.cid('Strom')), -14.00::numeric,
  'Eingetragener Betrag folgt den verknüpften Abbuchungen');

-- ---------------------------------------------------------------------
-- 3. Status: verworfen verknüpft nicht, gekündigt schon (12–14)
-- ---------------------------------------------------------------------
insert into public.recurring_contracts (name, counterparty_key, rhythm, expected_amount, status, detection_source)
values ('Zeitung alt', pg_temp.key('Zeitung Ost'), 'monthly', -4.99, 'dismissed', 'auto'),
       ('Fitness alt', pg_temp.key('Fitness Ost'), 'monthly', -29.90, 'cancelled', 'manual');
select is(public.sync_contracts(), 3, 'sync_contracts liefert die Anzahl neu verknüpfter Buchungen');
select is(pg_temp.linked('Zeitung alt'), null, 'Verworfener Vertrag bekommt keine Buchungen');
select is(pg_temp.linked('Fitness alt'), 'Beitrag 1, Beitrag 2, Beitrag 3', 'Gekündigter Vertrag bekommt weiter Buchungen');

-- ---------------------------------------------------------------------
-- 4. Neue Buchungen: nächster Betrag zuerst, Betrag folgt (15–18)
-- ---------------------------------------------------------------------
select tests.authenticate_as_service_role();
select pg_temp.tx('Versicherung Süd', 'Hausrat 5',         -6.00, '2026-07-01');
select pg_temp.tx('Versicherung Süd', 'Haftpflicht neu 2', -8.90, '2026-07-15');
select pg_temp.tx('Versicherung Süd', 'Hausrat 6',         -6.00, '2026-08-01');
select pg_temp.tx('Versicherung Süd', 'Haftpflicht neu 3', -8.90, '2026-08-15');
select tests.authenticate_as('cl_alice');
select is(public.sync_contracts(), 4, 'Vier neue Abbuchungen verknüpft');
select is((select count(*)::integer from public.transactions
            where recurring_contract_id = pg_temp.cid('Hausrat') and amount <> -6.00), 0,
  'Zwei Verträge derselben Gegenpartei: jede Abbuchung beim Vertrag mit dem nächsten Betrag');
select is((select expected_amount from public.recurring_contracts where id = pg_temp.cid('Haftpflicht')), -8.90::numeric,
  'Nach drei Abbuchungen zum neuen Preis folgt der Vertragsbetrag');
select is(public.sync_contracts(), 0, 'Nichts Neues: nichts verknüpft');

-- ---------------------------------------------------------------------
-- 5. refresh_contracts ohne Erkennung (19–20)
-- ---------------------------------------------------------------------
select is(public.refresh_contracts(), '{"created": 0, "removed": 0, "linked": 0}'::jsonb,
  'refresh_contracts (ältere App-Stände): nur verknüpfen');
select is((select count(*)::integer from public.recurring_contracts where status = 'suggested'), 0,
  'Keine Vorschläge, obwohl die Musik-Serie klar erkennbar ist');

-- ---------------------------------------------------------------------
-- 6. Löschen jedes Vertrags (21–24)
-- ---------------------------------------------------------------------
insert into public.recurring_contracts (name, counterparty_key, rhythm, expected_amount, status, detection_source)
values ('Musik', pg_temp.key('Musikdienst Pro'), 'monthly', -9.99, 'active', 'auto');
select public.sync_contracts();
select public.set_contract_link((select id from public.transactions where purpose = 'Musik 1'), pg_temp.cid('Musik'));
select is((select count(*)::integer || '|' || bool_or(contract_link_manual) from public.transactions
            where recurring_contract_id = pg_temp.cid('Musik')), '6|true',
  'Bestätigter erkannter Vertrag mit Buchungen (eine manuell verknüpft)');
create temp table deleted_contract as select pg_temp.cid('Musik') as id;
grant select on deleted_contract to authenticated;
select lives_ok($$ select public.delete_contract(pg_temp.cid('Musik')) $$, 'Erkannter Vertrag lässt sich löschen');
select is((select count(*)::integer from public.transactions
            where purpose like 'Musik %' and (recurring_contract_id is not null or contract_link_manual)), 0,
  'Gelöscht: Buchungen gelöst, manuelle Verknüpfung zurückgesetzt');
select is((select count(*)::integer from public.recurring_contracts where id = (select id from deleted_contract)), 0,
  'Gelöscht: Vertrag entfernt');

-- ---------------------------------------------------------------------
-- 7. Gegenparteien fürs Formular (25–30)
-- ---------------------------------------------------------------------
select private.refresh_recurrence(auth.uid());
select results_eq(
  $$ select label, tx_count, last_amount, recurrence, contract_type::text, has_contract
       from public.contract_counterparties() where counterparty_key = pg_temp.key('Versicherung Süd') $$,
  $$ values ('Versicherung Süd'::text, 12, 8.90::numeric, 'monthly'::text, 'insurance'::text, true) $$,
  'Gegenpartei mit Rhythmus, Typvorschlag (Versicherung) und bestehendem Vertrag'
);
select results_eq(
  $$ select recurrence, contract_type::text, has_contract
       from public.contract_counterparties() where counterparty_key = pg_temp.key('Musikdienst Pro') $$,
  $$ values ('monthly'::text, 'other'::text, false) $$,
  'Nach dem Löschen: kein Vertrag mehr, Typ ohne Hinweis Sonstiges'
);
select is((select has_contract from public.contract_counterparties() where counterparty_key = pg_temp.key('Zeitung Ost')),
  false, 'Verworfener Vertrag zählt nicht als bestehender Vertrag');
select is((select contract_type::text from public.contract_counterparties() where counterparty_key = pg_temp.key('Stadtwerke West')),
  'energy', 'Typvorschlag Energie aus dem Namen');
select is((select recurrence from public.contract_counterparties() where counterparty_key = pg_temp.key('Baumarkt Kunz')),
  null, 'Unregelmäßige Einkäufe: kein Rhythmus');
select ok(
  (select min(n) filter (where key = pg_temp.key('Zeitung Ost')) < min(n) filter (where key = pg_temp.key('Baumarkt Kunz'))
     from (select cc.counterparty_key as key, row_number() over () as n from public.contract_counterparties() cc) x),
  'Wiederkehrende zuerst (Zeitung mit 3 vor Baumarkt mit 7 Buchungen)'
);

-- ---------------------------------------------------------------------
-- 8. Mandantentrennung und Beraterzugriff (31–38)
-- ---------------------------------------------------------------------
create temp table alice_contract as select pg_temp.cid('Hausrat') as id;
grant select on alice_contract to authenticated;
select set_config('test.alice_links',
  (select count(*)::text from public.transactions where recurring_contract_id is not null), true);

select tests.authenticate_as('cl_bob');
select throws_ok($$ select public.delete_contract((select id from alice_contract)) $$,
  'P0002', 'contract_not_found', 'Bob kann fremde Verträge nicht löschen');
select is_empty($$ select 1 from public.contract_counterparties() $$, 'Bob sieht keine fremden Gegenparteien');
select is(public.sync_contracts(), 0, 'Bob: sync_contracts nur für eigene Daten');

select tests.authenticate_as('cl_carol');
select throws_ok($$ select public.delete_contract((select id from alice_contract)) $$,
  'P0002', 'contract_not_found', 'Beraterin kann Verträge der Mandantin nicht löschen');
select is(public.sync_contracts(), 0, 'Beraterin: sync_contracts nur für eigene Daten');
select is((select count(*)::text from public.transactions
            where user_id = tests.get_supabase_uid('cl_alice') and recurring_contract_id is not null),
  current_setting('test.alice_links'), 'Beraterin sieht die Verknüpfungen der Mandantin unverändert');

select tests.clear_authentication();
select throws_ok($$ select public.sync_contracts() $$, '42501', null, 'Ohne Anmeldung: kein sync_contracts');
select ok(not has_function_privilege('anon', 'public.sync_contracts()', 'execute'), 'anon darf sync_contracts nicht ausführen');

select * from finish();
rollback;
