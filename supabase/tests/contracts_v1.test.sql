-- =====================================================================
--  supabase/tests/contracts_v1.test.sql
--  Verträge V1: Erkennung, Fortsetzung, Verwerfen, Verknüpfen, manuelle
--  Verträge, Mandantentrennung und Beraterzugriff
--  (Migration 20261010100000; seit 20261014100000 läuft die Erkennung nur
--  noch über private.refresh_contracts, public.refresh_contracts verknüpft nur)
--  Ausführen: supabase test db   (setzt 00000-test-helpers.sql voraus)
--
--  Identitäten
--    v1_alice – Nutzerin mit Buchungen
--    v1_bob   – anderer Nutzer
--    v1_carol – Beraterin, aktive Verbindung zu Alice
--    v1_dave  – Berater, Verbindung zu Alice widerrufen
--    v1_erin  – Beraterin, Einladung an Alice noch offen
-- =====================================================================

begin;

select plan(83);

select tests.create_supabase_user('v1_alice', 'v1-alice@example.test');
select tests.create_supabase_user('v1_bob',   'v1-bob@example.test');
select tests.create_supabase_user('v1_carol', 'v1-carol@example.test');
select tests.create_supabase_user('v1_dave',  'v1-dave@example.test');
select tests.create_supabase_user('v1_erin',  'v1-erin@example.test');

select tests.authenticate_as_service_role();

update public.profiles set role = 'advisor'
 where user_id in (tests.get_supabase_uid('v1_carol'), tests.get_supabase_uid('v1_dave'), tests.get_supabase_uid('v1_erin'));
insert into public.advisor_clients (advisor_id, user_id, status, invited_email, accepted_at, revoked_at) values
  (tests.get_supabase_uid('v1_carol'), tests.get_supabase_uid('v1_alice'), 'active',  'v1-alice@example.test', now(), null),
  (tests.get_supabase_uid('v1_dave'),  tests.get_supabase_uid('v1_alice'), 'revoked', 'v1-alice@example.test', now(), now());
insert into public.advisor_clients (advisor_id, status, invited_email, invite_token_hash, invite_expires_at) values
  (tests.get_supabase_uid('v1_erin'), 'invited', 'v1-alice@example.test', repeat('f', 64), now() + interval '7 days');

insert into public.accounts (id, user_id, name, type, currency, provider) values
  ('7c000000-0000-4000-8000-0000000000a1', tests.get_supabase_uid('v1_alice'), 'Giro',      'checking', 'EUR', 'csv'),
  ('7c000000-0000-4000-8000-0000000000a2', tests.get_supabase_uid('v1_alice'), 'Tagesgeld', 'savings',  'EUR', 'csv'),
  ('7c000000-0000-4000-8000-0000000000b1', tests.get_supabase_uid('v1_bob'),   'Bob Giro',  'checking', 'EUR', 'csv');

-- Serie: p_n Buchungen ab p_start im Abstand p_step.
create function pg_temp.series(
  p_user text, p_account uuid, p_counterparty text, p_purpose text, p_iban text,
  p_amount numeric, p_start date, p_step interval, p_n integer
) returns void language sql as $$
  insert into public.transactions (user_id, account_id, booking_date, amount, currency, counterparty_name, purpose, counterparty_iban)
  select tests.get_supabase_uid(p_user), p_account, (p_start + p_step * (k - 1))::date, p_amount, 'EUR',
         p_counterparty, p_purpose || ' ' || k, p_iban
    from generate_series(1, p_n) k;
$$;

create function pg_temp.contract(p_key text, p_status text default null) returns uuid language sql as $$
  select id from public.recurring_contracts
   where user_id = tests.get_supabase_uid('v1_alice') and counterparty_key = p_key
     and (p_status is null or status::text = p_status)
   order by created_at, abs(expected_amount) limit 1;
$$;
create function pg_temp.linked(p_contract uuid) returns integer language sql as $$
  select count(*)::integer from public.transactions where recurring_contract_id = p_contract;
$$;
grant execute on function pg_temp.contract(text, text), pg_temp.linked(uuid) to authenticated;

\set giro '''7c000000-0000-4000-8000-0000000000a1'''
\set tagesgeld '''7c000000-0000-4000-8000-0000000000a2'''

-- Netflix über PayPal: monatlich, 6×
select pg_temp.series('v1_alice', :giro, 'PayPal Europe S.a.r.l. et Cie S.C.A', 'PP.1234.PP . Netflix, Ihr Einkauf bei Netflix',
                      null, -9.99, '2026-04-03', interval '1 month', 6);
-- Spotify: 6× 9,99, dann Preiserhöhung 3× 12,99 (Fortsetzung)
select pg_temp.series('v1_alice', :giro, 'Spotify AB', 'Spotify Premium', null, -9.99, '2025-12-10', interval '1 month', 6);
select pg_temp.series('v1_alice', :giro, 'Spotify AB', 'Spotify Premium neu', null, -12.99, '2026-06-10', interval '1 month', 3);
-- Allianz (gleiche IBAN): zwei parallele Verträge 6,00 und 8,50
select pg_temp.series('v1_alice', :giro, 'Allianz Versicherungs-AG', 'Hausrat', 'DE89370400440532013000', -6.00, '2026-04-01', interval '1 month', 6);
select pg_temp.series('v1_alice', :giro, 'Allianz Versicherungs-AG', 'Haftpflicht', 'DE89370400440532013000', -8.50, '2026-04-15', interval '1 month', 6);
-- HUK jährlich, nur 2 Buchungen
select pg_temp.series('v1_alice', :giro, 'HUK-COBURG', 'Kfz-Versicherung', null, -389.00, '2025-03-01', interval '1 year', 2);
-- Zwei monatliche Buchungen: zu wenig
select pg_temp.series('v1_alice', :giro, 'Zeitschriftenverlag', 'Probeabo', null, -4.99, '2026-08-05', interval '1 month', 2);
-- 14-tägig
select pg_temp.series('v1_alice', :giro, 'Reinigung Müller', 'Fensterputz', null, -60, '2026-07-01', interval '14 days', 6);
-- Zweimonatlich
select pg_temp.series('v1_alice', :giro, 'Stadtwerke München', 'Abschlag Wasser', null, -45, '2026-01-20', interval '2 months', 5);
-- Eigenes Konto per IBAN (Sparrate)
select pg_temp.series('v1_alice', :giro, 'Alice Depot', 'Sparrate', 'DE02120300000000202051', -300, '2026-04-02', interval '1 month', 6);
-- Umbuchung (Kategorie transfer)
select pg_temp.series('v1_alice', :giro, 'Alice Tagesgeld', 'Übertrag', null, -100, '2026-04-04', interval '1 month', 6);
-- Beendet (letzte Abbuchung lange vor dem Datenstand)
select pg_temp.series('v1_alice', :giro, 'FitStudio Nord', 'Beitrag Fitness', null, -29.90, '2025-01-05', interval '1 month', 6);
-- Einnahme
select pg_temp.series('v1_alice', :giro, 'Arbeitgeber GmbH', 'Gehalt', null, 3200, '2026-04-28', interval '1 month', 6);
-- Miete über zwei Konten (für den manuellen Vertrag)
select pg_temp.series('v1_alice', :giro, 'Hausverwaltung Schmidt GmbH', 'Miete', null, -950, '2026-04-01', interval '1 month', 5);
select pg_temp.series('v1_alice', :tagesgeld, 'Hausverwaltung Schmidt GmbH', 'Miete Sept', null, -950, '2026-09-01', interval '1 month', 1);
-- Verworfener Altvertrag ohne Buchungen (Band ±20 %): 21 € wird
-- unterdrückt, 30 € (parallel) nicht.
select pg_temp.series('v1_alice', :giro, 'Abc Service', 'Service klein', null, -21, '2026-04-07', interval '1 month', 6);
select pg_temp.series('v1_alice', :giro, 'Abc Service', 'Service groß', null, -30, '2026-04-20', interval '1 month', 6);
-- Bob: eigene Serie
select pg_temp.series('v1_bob', '7c000000-0000-4000-8000-0000000000b1', 'Bob Streaming', 'Abo', null, -7.99, '2026-04-02', interval '1 month', 6);

select tests.authenticate_as('v1_alice');
select public.add_own_account_identifier('iban', 'DE02 1203 0000 0000 2020 51');
update public.transactions
   set category_id = (select id from public.categories where user_id = auth.uid() and default_key = 'transfer')
 where user_id = auth.uid() and counterparty_name = 'Alice Tagesgeld';
insert into public.recurring_contracts (name, counterparty_key, rhythm, expected_amount, status, detection_source, detection_confidence)
values ('Abc alt', 'n:abc service', 'monthly', -20, 'dismissed', 'auto', 0.9);

-- ---------------------------------------------------------------------
-- 1. Hilfsfunktionen
-- ---------------------------------------------------------------------
select is((select rhythm_key from private.series_rhythm(array['2026-01-01', '2026-01-15', '2026-01-29']::date[])),
  'biweekly', 'Rhythmus: 14 Tage → biweekly');
select is((select rhythm_key from private.series_rhythm(array['2026-01-01', '2026-03-02', '2026-05-01']::date[])),
  'bimonthly', 'Rhythmus: 2 Monate → bimonthly');
select is((select count(*)::integer from private.series_rhythm(array['2026-01-01', '2026-01-20']::date[])), 0,
  'Rhythmus: 19 Tage passt in kein Band');
select is(private.contract_period('weekly', 2), interval '14 days', 'Periode 14-tägig');
select is(private.contract_period('monthly', 2), interval '2 months', 'Periode zweimonatlich');
select is(private.guess_contract_type('Allianz Versicherungs-AG Hausrat', null), 'insurance'::public.contract_type, 'Typ: Versicherung am Namen');
select is(private.guess_contract_type('Vodafone GmbH', null), 'telecom'::public.contract_type, 'Typ: Mobilfunk am Namen');
select is(private.guess_contract_type('E.ON Energie Deutschland', null), 'energy'::public.contract_type, 'Typ: Energie am Namen');
select is(private.guess_contract_type('Max Muster', 'subscriptions_media'), 'subscription'::public.contract_type, 'Typ: sonst aus der Kategorie');
select is(private.guess_contract_type('Max Muster', null), 'other'::public.contract_type, 'Typ: sonst Sonstiges');

-- ---------------------------------------------------------------------
-- 2. Erkennung
-- ---------------------------------------------------------------------
select is((private.refresh_contracts(auth.uid()) ->> 'created')::integer, 9, 'Erkennung legt 9 Vorschläge an');

select is((select name || '|' || rhythm || '|' || interval_count || '|' || expected_amount || '|' || contract_type || '|' || detection_confidence
             from public.recurring_contracts where id = pg_temp.contract('m:netflix')),
  'Netflix|monthly|1|-9.99|subscription|1.00', 'Netflix über PayPal: Händler als Gegenpartei, monatlich, 9,99, Abo');
select is(pg_temp.linked(pg_temp.contract('m:netflix')), 6, 'Netflix: 6 Buchungen verknüpft');
select is((select next_expected_date from public.recurring_contracts where id = pg_temp.contract('m:netflix')),
  '2026-10-03'::date, 'Netflix: nächste Abbuchung = letzte + 1 Monat');
select is((select status::text || '|' || detection_source from public.recurring_contracts where id = pg_temp.contract('m:netflix')),
  'suggested|auto', 'Vorschlag, erkannt');

select is((select count(*)::integer from public.recurring_contracts where user_id = auth.uid() and counterparty_key = 'n:spotify'), 1,
  'Spotify: Preiserhöhung ist Fortsetzung, kein zweiter Vorschlag');
select is((select expected_amount from public.recurring_contracts where id = pg_temp.contract('n:spotify')), -12.99::numeric,
  'Spotify: erwarteter Betrag = aktueller Preis');
select is(pg_temp.linked(pg_temp.contract('n:spotify')), 9, 'Spotify: alte und neue Abbuchungen verknüpft');

select is((select count(*)::integer from public.recurring_contracts
            where user_id = auth.uid() and counterparty_key = 'i:' || md5('DE89370400440532013000')), 2,
  'Allianz: zwei parallele Serien gleicher IBAN → zwei Vorschläge');
select is((select string_agg(contract_type::text, ',') from public.recurring_contracts
            where user_id = auth.uid() and counterparty_key = 'i:' || md5('DE89370400440532013000')), 'insurance,insurance',
  'Allianz: Typ Versicherung');

select is((select rhythm || '|' || detection_confidence from public.recurring_contracts where id = pg_temp.contract('n:coburg huk')),
  'yearly|0.50', 'Jährlich mit 2 Buchungen: erkannt, geringe Sicherheit');
select is(pg_temp.contract('n:zeitschriftenverlag'), null, 'Monatlich mit 2 Buchungen: kein Vorschlag');
select is((select rhythm || '|' || interval_count from public.recurring_contracts where id = pg_temp.contract('n:mueller reinigung')),
  'weekly|2', '14-tägig erkannt (weekly ×2)');
select is((select rhythm || '|' || interval_count || '|' || contract_type from public.recurring_contracts
            where id = pg_temp.contract('n:muenchen stadtwerke')),
  'monthly|2|energy', 'Zweimonatlich erkannt (monthly ×2), Typ Energie');
select is(pg_temp.contract('i:' || md5('DE02120300000000202051')), null, 'Eigenes Konto (IBAN): kein Vorschlag');
select is(pg_temp.contract('n:alice tagesgeld'), null, 'Umbuchung: kein Vorschlag');
select is(pg_temp.contract('n:fitstudio nord'), null, 'Beendete Serie: kein Vorschlag');
select is(pg_temp.contract('n:arbeitgeber'), null, 'Einnahmen: kein Vorschlag');
select is((select count(*)::integer from public.recurring_contracts where user_id = auth.uid() and counterparty_key = 'n:abc service'), 2,
  'Verworfen (20 €): 21 € unterdrückt, 30 € neuer Vorschlag');
select is((select abs(expected_amount) from public.recurring_contracts
            where user_id = auth.uid() and counterparty_key = 'n:abc service' and status = 'suggested'), 30::numeric,
  'Verworfen: Vorschlag nur für die Serie außerhalb des Bands');

select is((private.refresh_contracts(auth.uid()) ->> 'created')::integer, 0, 'Erneute Erkennung: keine Doppelten');
select private.refresh_recurrence(auth.uid());
select is((select recurrence from public.transactions where user_id = auth.uid() and purpose = 'Fensterputz 1'), 'biweekly',
  'Wiederkehrende Buchungen (B1) kennen 14-tägig');

-- ---------------------------------------------------------------------
-- 3. Verwerfen bleibt verworfen
-- ---------------------------------------------------------------------
select public.set_contract_status(pg_temp.contract('m:netflix'), 'dismissed');
select is((select status::text from public.recurring_contracts where id = pg_temp.contract('m:netflix')), 'dismissed', 'Netflix verworfen');
select tests.authenticate_as_service_role();
-- Preiserhöhung um 35 % (außerhalb ±20 %, aber Fortsetzung derselben Serie)
select pg_temp.series('v1_alice', :giro, 'PayPal Europe S.a.r.l. et Cie S.C.A', 'PP.9999.PP . Netflix, Ihr Einkauf bei Netflix',
                      null, -13.49, '2026-10-03', interval '1 month', 1);
select tests.authenticate_as('v1_alice');
select private.refresh_contracts(auth.uid());
select is((select count(*)::integer from public.recurring_contracts where user_id = auth.uid() and counterparty_key = 'm:netflix'), 1,
  'Nach neuen Buchungen und Preiserhöhung: kein neuer Netflix-Vorschlag');
select is((select status::text from public.recurring_contracts where id = pg_temp.contract('m:netflix')), 'dismissed',
  'Netflix bleibt verworfen');

select public.set_contract_status(pg_temp.contract('m:netflix'), 'suggested');
select is((select status::text from public.recurring_contracts where id = pg_temp.contract('m:netflix')), 'suggested',
  'Wiederherstellen: wieder Vorschlag');
select is(pg_temp.linked(pg_temp.contract('m:netflix')), 6,
  'Wiederhergestellt: Vorschläge bekommen ohne Erkennung keine neuen Buchungen');
select is((select abs(expected_amount) from public.recurring_contracts where id = pg_temp.contract('m:netflix')), 9.99::numeric,
  'Wiederhergestellt: Betrag = Median der letzten drei Abbuchungen');

-- ---------------------------------------------------------------------
-- 4. Bestätigen und automatisch verknüpfen
-- ---------------------------------------------------------------------
select public.set_contract_status(pg_temp.contract('n:spotify'), 'active', 'subscription');
select is((select status::text || '|' || contract_type from public.recurring_contracts where id = pg_temp.contract('n:spotify')),
  'active|subscription', 'Spotify bestätigt mit Typ');
select tests.authenticate_as_service_role();
select pg_temp.series('v1_alice', :tagesgeld, 'Spotify AB', 'Spotify Okt', null, -12.99, '2026-09-10', interval '1 month', 1);
select pg_temp.series('v1_alice', :giro, 'Spotify AB', 'Spotify Familie', null, -15.99, '2026-09-20', interval '1 month', 1);
select tests.authenticate_as('v1_alice');
select public.refresh_contracts();
select is((select recurring_contract_id from public.transactions where user_id = auth.uid() and purpose = 'Spotify Okt 1'),
  pg_temp.contract('n:spotify'), 'Neue Abbuchung innerhalb der Toleranz verknüpft (anderes Konto)');
select is((select recurring_contract_id from public.transactions where user_id = auth.uid() and purpose = 'Spotify Familie 1'),
  null, 'Abbuchung außerhalb der Toleranz nicht verknüpft');
select is((select last_booking_date || '|' || next_expected_date from public.recurring_contracts where id = pg_temp.contract('n:spotify')),
  '2026-09-10|2026-10-10', 'Letzte und nächste Abbuchung nachgeführt');

select throws_ok($$ select public.set_contract_status(pg_temp.contract('n:spotify'), 'suggested') $$,
  '22023', 'invalid_transition', 'Ungültiger Statuswechsel abgelehnt');
select throws_ok($$ select public.delete_contract(gen_random_uuid()) $$,
  'P0002', 'contract_not_found', 'Unbekannter Vertrag lässt sich nicht löschen');

-- ---------------------------------------------------------------------
-- 5. Manueller Vertrag
-- ---------------------------------------------------------------------
select throws_ok($$ select public.save_contract(null, 'Miete', null, 'Hausverwaltung Schmidt', 'monthly', 1, 0, null,
                                                'housing', null, null, null) $$,
  '22023', 'invalid_amount', 'Betrag muss positiv sein');
select throws_ok($$ select public.save_contract(null, '  ', null, null, 'monthly', 1, 10, null, 'other', null, null, null) $$,
  '22023', 'invalid_name', 'Name ist Pflicht');
select throws_ok($$ select public.save_contract(null, 'X', 'x:kaputt', null, 'monthly', 1, 10, null, 'other', null, null, null) $$,
  '22023', 'invalid_counterparty', 'Ungültiger Gegenpartei-Schlüssel');

select lives_ok($$ select public.save_contract(null, 'Wohnung', null, 'Hausverwaltung Schmidt', 'monthly', 1, 950, '2026-10-01',
                                               'housing', '7c000000-0000-4000-8000-0000000000a1', null, 'Kaltmiete') $$,
  'Manuellen Vertrag anlegen');
select is((select status::text || '|' || detection_source || '|' || counterparty_key || '|' || expected_amount
             from public.recurring_contracts where user_id = auth.uid() and name = 'Wohnung'),
  'active|manual|n:hausverwaltung schmidt|-950.00', 'Manuell: aktiv, Schlüssel aus dem Namen, Betrag als Abbuchung');
select is(pg_temp.linked((select id from public.recurring_contracts where user_id = auth.uid() and name = 'Wohnung')), 6,
  'Manuell: passende Buchungen beider Konten verknüpft');
select is((select count(*)::integer from public.transactions t join public.recurring_contracts rc on rc.id = t.recurring_contract_id
            where t.user_id = auth.uid() and rc.counterparty_key = 'n:hausverwaltung schmidt' and rc.status = 'suggested'), 0,
  'Manuell: übernimmt die Buchungen des Vorschlags derselben Serie');
select is((select next_expected_date from public.recurring_contracts where user_id = auth.uid() and name = 'Wohnung'),
  '2026-10-01'::date, 'Manuell: eingetragene nächste Abbuchung bleibt');

-- Gegenpartei-Liste fürs Formular
select is((select label || '|' || tx_count from public.contract_counterparties() where counterparty_key = 'm:netflix'),
  'Netflix|7', 'Gegenparteien: Händler hinter PayPal mit Anzahl');
select is((select count(*)::integer from public.contract_counterparties() where counterparty_key = 'n:arbeitgeber'), 0,
  'Gegenparteien: nur Ausgaben');

-- ---------------------------------------------------------------------
-- 6. Lösen und manuell verknüpfen
-- ---------------------------------------------------------------------
select public.set_contract_link((select id from public.transactions where user_id = auth.uid() and purpose = 'Miete 1'), null);
select public.refresh_contracts();
select is((select recurring_contract_id is null from public.transactions where user_id = auth.uid() and purpose = 'Miete 1'),
  true, 'Gelöste Buchung bleibt nach erneuter Erkennung gelöst');
select is((select contract_link_manual from public.transactions where user_id = auth.uid() and purpose = 'Miete 1'),
  true, 'Gelöste Buchung ist als manuell markiert');
select public.set_contract_link((select id from public.transactions where user_id = auth.uid() and purpose = 'Spotify Familie 1'),
                                pg_temp.contract('n:spotify'));
select is((select recurring_contract_id from public.transactions where user_id = auth.uid() and purpose = 'Spotify Familie 1'),
  pg_temp.contract('n:spotify'), 'Manuell verknüpft');
select throws_ok($$ select public.set_contract_link(gen_random_uuid(), null) $$,
  'P0002', 'transaction_not_found', 'Unbekannte Buchung');

-- Vorschlag entfällt, wenn die Serie nicht mehr gilt (eigenes Konto).
select public.add_own_account_identifier('iban', 'DE89370400440532013000');
select private.refresh_contracts(auth.uid());
select is((select count(*)::integer from public.recurring_contracts
            where user_id = auth.uid() and counterparty_key = 'i:' || md5('DE89370400440532013000')), 0,
  'Vorschläge ohne gültige Serie werden entfernt');

-- Löschen (manuell): Buchungen werden gelöst.
-- Vorher eine Buchung manuell wieder verknüpfen: nach dem Löschen ist sie
-- wieder für die Automatik offen.
select public.set_contract_link((select id from public.transactions where user_id = auth.uid() and purpose = 'Miete 1'),
                                (select id from public.recurring_contracts where user_id = auth.uid() and name = 'Wohnung'));
select public.delete_contract((select id from public.recurring_contracts where user_id = auth.uid() and name = 'Wohnung'));
select is((select count(*)::integer from public.transactions where user_id = auth.uid() and purpose like 'Miete%'
             and recurring_contract_id is not null), 0,
  'Manuell gelöscht: keine Buchung mehr am gelöschten Vertrag');
select is((select contract_link_manual from public.transactions where user_id = auth.uid() and purpose = 'Miete 1'), false,
  'Manuell gelöscht: manuelle Verknüpfung zurückgesetzt');

-- ---------------------------------------------------------------------
-- 7. Mandantentrennung
-- ---------------------------------------------------------------------
create temp table alice_ids as
select (select id from public.recurring_contracts where user_id = auth.uid() and counterparty_key = 'n:spotify') as contract_id,
       (select id from public.transactions where user_id = auth.uid() and purpose = 'Spotify Premium 1') as tx_id;
grant select on alice_ids to authenticated;

select tests.authenticate_as('v1_bob');
select is((private.refresh_contracts(auth.uid()) ->> 'created')::integer, 1, 'Bob: eigene Erkennung');
select is((select count(*)::integer from public.recurring_contracts), 1, 'Bob sieht nur seinen eigenen Vertrag');
select is((select count(*)::integer from public.transactions where recurring_contract_id = (select contract_id from alice_ids)), 0,
  'Bob sieht keine Buchungen fremder Verträge');
select is_empty($$ update public.recurring_contracts set name = 'gekapert' where id = (select contract_id from alice_ids) returning id $$,
  'Bob kann fremde Verträge nicht ändern');
select is_empty($$ delete from public.recurring_contracts where id = (select contract_id from alice_ids) returning id $$,
  'Bob kann fremde Verträge nicht löschen');
select throws_ok($$ insert into public.recurring_contracts (user_id, name) values (tests.get_supabase_uid('v1_alice'), 'fremd') $$,
  '42501', null, 'Bob kann keinen Vertrag für Alice anlegen');
select throws_ok($$ select public.set_contract_status((select contract_id from alice_ids), 'dismissed') $$,
  'P0002', 'contract_not_found', 'Bob: Statuswechsel fremder Verträge abgelehnt');
select throws_ok($$ select public.save_contract((select contract_id from alice_ids), 'X', null, null, 'monthly', 1, 1, null,
                                                'other', null, null, null) $$,
  'P0002', 'contract_not_found', 'Bob: Ändern fremder Verträge abgelehnt');
select throws_ok($$ select public.set_contract_link((select tx_id from alice_ids), null) $$,
  'P0002', 'transaction_not_found', 'Bob: fremde Buchung nicht lösbar');
select throws_ok($$ select public.set_contract_link((select id from public.transactions limit 1), (select contract_id from alice_ids)) $$,
  'P0002', 'contract_not_found', 'Bob: eigene Buchung nicht an fremden Vertrag');
select throws_ok($$ update public.transactions set recurring_contract_id = (select contract_id from alice_ids)
                     where user_id = auth.uid() $$,
  '23503', null, 'Bob: Fremdschlüssel verhindert Verknüpfung mit fremdem Vertrag');
select throws_ok($$ select public.save_contract(null, 'X', null, null, 'monthly', 1, 1, null, 'other',
                                                '7c000000-0000-4000-8000-0000000000a1', null, null) $$,
  'P0002', 'account_not_found', 'Bob: fremdes Konto als Standard abgelehnt');

-- ---------------------------------------------------------------------
-- 8. Beraterzugriff
-- ---------------------------------------------------------------------
select tests.authenticate_as('v1_carol');
select is((select count(*)::integer from public.recurring_contracts where user_id = tests.get_supabase_uid('v1_alice')
             and status = 'active'), 1, 'Beraterin (aktiv) sieht die Verträge der Mandantin');
select is((select count(*)::integer from public.transactions where recurring_contract_id = (select contract_id from alice_ids)), 11,
  'Beraterin sieht die verknüpften Buchungen');
select is_empty($$ update public.recurring_contracts set name = 'Berater' where id = (select contract_id from alice_ids) returning id $$,
  'Beraterin kann Verträge nicht ändern');
select throws_ok($$ select public.set_contract_status((select contract_id from alice_ids), 'dismissed') $$,
  'P0002', 'contract_not_found', 'Beraterin: kein Statuswechsel');
select throws_ok($$ select public.delete_contract((select contract_id from alice_ids)) $$,
  'P0002', 'contract_not_found', 'Beraterin: kein Löschen');
select throws_ok($$ select public.set_contract_link((select tx_id from alice_ids), null) $$,
  'P0002', 'transaction_not_found', 'Beraterin: keine Verknüpfung ändern');
select is((public.refresh_contracts() ->> 'created')::integer, 0, 'Beraterin: Erkennung nur für eigene Daten');

select tests.authenticate_as('v1_dave');
select is_empty($$ select 1 from public.recurring_contracts where user_id = tests.get_supabase_uid('v1_alice') $$,
  'Widerrufener Berater sieht keine Verträge');
select tests.authenticate_as('v1_erin');
select is_empty($$ select 1 from public.recurring_contracts where user_id = tests.get_supabase_uid('v1_alice') $$,
  'Nur eingeladene Beraterin sieht keine Verträge');

select tests.clear_authentication();
select throws_ok($$ select public.refresh_contracts() $$, '42501', null, 'Ohne Anmeldung: keine Erkennung');

select * from finish();

rollback;
