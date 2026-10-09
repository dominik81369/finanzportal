-- =====================================================================
--  supabase/tests/contracts_v2a.test.sql
--  Verträge V2a: Mandatsreferenz und Gläubiger-ID (Auslesen, Import,
--  Nachtrag), Mandat in Erkennung und Verknüpfung, Gegenbuchungen,
--  contract_actuals(), Mandantentrennung und Beraterzugriff
--  (Migration 20261013100000)
--  Ausführen: supabase test db   (setzt 00000-test-helpers.sql voraus)
--
--  Identitäten
--    v2_alice – Nutzerin mit Buchungen
--    v2_bob   – anderer Nutzer
--    v2_carol – Beraterin, aktive Verbindung zu Alice
-- =====================================================================

begin;

select plan(41);

select tests.create_supabase_user('v2_alice', 'v2-alice@example.test');
select tests.create_supabase_user('v2_bob',   'v2-bob@example.test');
select tests.create_supabase_user('v2_carol', 'v2-carol@example.test');

select tests.authenticate_as_service_role();
update public.profiles set role = 'advisor' where user_id = tests.get_supabase_uid('v2_carol');
insert into public.advisor_clients (advisor_id, user_id, status, invited_email, accepted_at) values
  (tests.get_supabase_uid('v2_carol'), tests.get_supabase_uid('v2_alice'), 'active', 'v2-alice@example.test', now());

insert into public.accounts (id, user_id, name, type, currency, provider) values
  ('7d000000-0000-4000-8000-0000000000a1', tests.get_supabase_uid('v2_alice'), 'Giro',     'checking', 'EUR', 'csv'),
  ('7d000000-0000-4000-8000-0000000000b1', tests.get_supabase_uid('v2_bob'),   'Bob Giro', 'checking', 'EUR', 'csv');

-- Serie: p_n Buchungen ab p_start im Abstand p_step, optional mit Mandat.
create function pg_temp.series(
  p_counterparty text, p_purpose text, p_amount numeric, p_start date, p_step interval, p_n integer,
  p_mandate text default null
) returns void language sql as $$
  insert into public.transactions (user_id, account_id, booking_date, amount, currency, counterparty_name, purpose,
                                   mandate_reference)
  select tests.get_supabase_uid('v2_alice'), '7d000000-0000-4000-8000-0000000000a1', (p_start + p_step * (k - 1))::date,
         p_amount, 'EUR', p_counterparty, p_purpose || ' ' || k, p_mandate
    from generate_series(1, p_n) k;
$$;
create function pg_temp.contracts(p_counterparty text) returns bigint language sql as $$
  select count(*) from public.recurring_contracts rc
   where rc.user_id = tests.get_supabase_uid('v2_alice')
     and rc.counterparty_key = (select t.counterparty_key from public.transactions t
                                 where t.counterparty_name = p_counterparty limit 1);
$$;
create function pg_temp.contract(p_counterparty text, p_amount numeric) returns uuid language sql as $$
  select rc.id from public.recurring_contracts rc
   where rc.user_id = tests.get_supabase_uid('v2_alice')
     and rc.counterparty_key = (select t.counterparty_key from public.transactions t
                                 where t.counterparty_name = p_counterparty limit 1)
     and rc.expected_amount = p_amount;
$$;
grant execute on function pg_temp.contract(text, numeric) to authenticated;

-- ---------------------------------------------------------------------
-- 1. Auslesen aus dem Verwendungszweck (1–10)
-- ---------------------------------------------------------------------
select tests.authenticate_as('v2_alice');
select results_eq(
  $$ select private.extract_mandate_reference(v), private.extract_creditor_id(v)
       from (values
         ('EREF+123456 MREF+M-0001-ABC CRED+DE98ZZZ09999999999 SVWZ+Beitrag Oktober'),
         ('EREF+123456MREF+M0001ABCCRED+DE98ZZZ09999999999SVWZ+Beitrag'),
         ('Netflix Abo Mandatsreferenz: NFX.12345, Gläubiger-ID: DE12ZZZ00000123456'),
         ('Mandat: 4711-0815 Referenz: 123'),
         ('Mandatsref. ABC/2024/1 Glaeubiger-ID DE12ZZZ00000123456'),
         ('MREF: KD-778899, CI: AT61ZZZ01234567890')) x (v) $$,
  $$ values ('M-0001-ABC'::text, 'DE98ZZZ09999999999'::text), ('M0001ABC', 'DE98ZZZ09999999999'),
            ('NFX.12345', 'DE12ZZZ00000123456'), ('4711-0815', null), ('ABC/2024/1', 'DE12ZZZ00000123456'),
            ('KD-778899', 'AT61ZZZ01234567890') $$,
  'Mandat und Gläubiger-ID in üblichen Schreibweisen, auch ohne Leerzeichen zwischen den SEPA-Feldern'
);
select is(private.extract_creditor_id('Rechnung 2024 DE12ZZZ00000123456 danke'), 'DE12ZZZ00000123456',
          'Frei stehende Gläubiger-ID mit ZZZ');
select is(private.extract_creditor_id('Überweisung an DE89370400440532013000'), null, 'IBAN ist keine Gläubiger-ID');
select is(private.extract_mandate_reference('kein Mandat hier'), null, 'Ohne Kennung kein Mandat');
select is(private.extract_mandate_reference('Mandatsreferenz:'), null, 'Leere Mandatsreferenz');
select is(private.extract_mandate_reference('Mandatsreferenz: 123456789012345678901234567890123456789 x'), null,
          'Mandat über 35 Zeichen wird verworfen');

insert into public.transactions (account_id, booking_date, amount, currency, counterparty_name, purpose)
values ('7d000000-0000-4000-8000-0000000000a1', '2026-01-02', -10, 'EUR', 'Trigger GmbH',
        'MREF+TRG-1 CRED+DE11ZZZ00000000001 SVWZ+Test');
select results_eq(
  $$ select mandate_reference, creditor_id from public.transactions where counterparty_name = 'Trigger GmbH' $$,
  $$ values ('TRG-1'::text, 'DE11ZZZ00000000001'::text) $$,
  'Beim Anlegen aus dem Verwendungszweck gelesen'
);
insert into public.transactions (account_id, booking_date, amount, currency, counterparty_name, purpose, mandate_reference)
values ('7d000000-0000-4000-8000-0000000000a1', '2026-01-03', -10, 'EUR', 'Explizit GmbH', 'MREF+AUS-ZWECK', 'SPALTE-1');
select is((select mandate_reference from public.transactions where counterparty_name = 'Explizit GmbH'), 'SPALTE-1',
          'Gesetzter Wert (eigene Spalte) bleibt');
update public.transactions set purpose = 'Mandatsreferenz: NEU-2' where counterparty_name = 'Trigger GmbH';
select is((select mandate_reference from public.transactions where counterparty_name = 'Trigger GmbH'), 'TRG-1',
          'Ändern des Zwecks überschreibt vorhandenes Mandat nicht');
select throws_ok(
  $$ update public.transactions set creditor_id = 'KEINE-ID' where counterparty_name = 'Trigger GmbH' $$,
  '23514', null, 'Ungültige Gläubiger-ID wird abgelehnt (Check)'
);

-- ---------------------------------------------------------------------
-- 2. Import: Spalten, Prüfung, Anreichern (11–15)
-- ---------------------------------------------------------------------
select is(
  (public.import_transactions('7d000000-0000-4000-8000-0000000000a1', jsonb_build_array(
     jsonb_build_object('booking_date', '2026-02-01', 'amount', -5, 'purpose', 'Import A', 'counterparty', 'Imp',
                        'mandate_reference', ' IMP-1 ', 'creditor_id', 'de 98 zzz 09999999999'),
     jsonb_build_object('booking_date', '2026-02-02', 'amount', -5, 'purpose', 'Import B MREF+AUSZWECK', 'counterparty', 'Imp',
                        'mandate_reference', repeat('x', 36), 'creditor_id', 'keine'),
     jsonb_build_object('booking_date', '2026-02-03', 'amount', -5, 'purpose', 'Import C', 'counterparty', 'Imp')
   )) ->> 'new')::integer,
  3, 'Import mit Mandat-/Gläubiger-Spalten: ungültige Werte verwerfen die Zeile nicht'
);
select results_eq(
  $$ select purpose, mandate_reference, creditor_id from public.transactions where counterparty_name = 'Imp' order by booking_date $$,
  $$ values ('Import A'::text, 'IMP-1'::text, 'DE98ZZZ09999999999'::text),
            ('Import B MREF+AUSZWECK', 'AUSZWECK', null), ('Import C', null, null) $$,
  'Spaltenwerte bereinigt; zu langes Mandat → aus dem Zweck; ungültige Gläubiger-ID → leer'
);
select is(
  (public.import_transactions('7d000000-0000-4000-8000-0000000000a1', jsonb_build_array(
     jsonb_build_object('booking_date', '2026-02-03', 'amount', -5, 'purpose', 'Import C', 'counterparty', 'Imp',
                        'mandate_reference', 'NACHTRAG-1', 'creditor_id', 'DE55ZZZ00000000055')
   )) ->> 'enriched')::integer,
  1, 'Erneuter Import ergänzt Mandat und Gläubiger-ID einer vorhandenen Buchung'
);
select results_eq(
  $$ select mandate_reference, creditor_id from public.transactions where purpose = 'Import C' $$,
  $$ values ('NACHTRAG-1'::text, 'DE55ZZZ00000000055'::text) $$,
  'Angereichert'
);
select is(
  (public.import_transactions('7d000000-0000-4000-8000-0000000000a1', jsonb_build_array(
     jsonb_build_object('booking_date', '2026-02-01', 'amount', -5, 'purpose', 'Import A', 'counterparty', 'Imp',
                        'mandate_reference', 'ANDERS')
   )) ->> 'enriched')::integer,
  0, 'Vorhandenes Mandat wird nicht überschrieben'
);

-- ---------------------------------------------------------------------
-- 3. Erkennung: parallele Mandate trennen, Wechsel ist Fortsetzung (16–21)
-- ---------------------------------------------------------------------
-- Zwei Verträge derselben Versicherung mit gleichem Betrag, parallele Mandate.
select pg_temp.series('Allianz Versicherungs-AG', 'Beitrag Hausrat',     -12.50, '2026-03-01', interval '1 month', 6, 'ALZ-HAUS');
select pg_temp.series('Allianz Versicherungs-AG', 'Beitrag Haftpflicht', -12.50, '2026-03-03', interval '1 month', 6, 'ALZ-HAFT');
-- Mandatswechsel: 4× altes, dann 3× neues Mandat, gleicher Betrag.
select pg_temp.series('Fitnessstudio Kraftwerk', 'Mitgliedsbeitrag', -39.90, '2026-02-05', interval '1 month', 4, 'FIT-ALT');
select pg_temp.series('Fitnessstudio Kraftwerk', 'Mitgliedsbeitrag', -39.90, '2026-06-05', interval '1 month', 3, 'FIT-NEU');

select public.refresh_contracts();
select is(pg_temp.contracts('Allianz Versicherungs-AG'), 2::bigint, 'Parallele Mandate: zwei Vorschläge trotz gleichem Betrag');
select is(
  (select count(distinct t.mandate_reference) from public.transactions t
     join public.recurring_contracts rc on rc.id = t.recurring_contract_id
    where t.counterparty_name = 'Allianz Versicherungs-AG' group by rc.id limit 1),
  1::bigint, 'Je Vorschlag nur Buchungen eines Mandats'
);
select results_eq(
  $$ select rc.mandate_reference from public.recurring_contracts rc
      where rc.counterparty_key = (select counterparty_key from public.transactions where counterparty_name = 'Allianz Versicherungs-AG' limit 1)
      order by 1 $$,
  $$ values ('ALZ-HAFT'::text), ('ALZ-HAUS') $$,
  'Vorschläge tragen ihr Mandat'
);
select is(pg_temp.contracts('Fitnessstudio Kraftwerk'), 1::bigint, 'Mandatswechsel: ein Vorschlag (Fortsetzung)');
select results_eq(
  $$ select count(t.id)::integer, rc.mandate_reference from public.recurring_contracts rc
       join public.transactions t on t.recurring_contract_id = rc.id
      where t.counterparty_name = 'Fitnessstudio Kraftwerk' group by rc.id, rc.mandate_reference $$,
  $$ values (7, 'FIT-NEU'::text) $$,
  'Alle 7 Abbuchungen verknüpft, Mandat der letzten Abbuchung'
);

-- Bestätigen; danach neue Abbuchungen verknüpfen nur zum passenden Mandat.
select public.set_contract_status(rc.id, 'active', 'insurance')
  from public.recurring_contracts rc where rc.mandate_reference in ('ALZ-HAUS', 'ALZ-HAFT');
select pg_temp.series('Allianz Versicherungs-AG', 'Beitrag Haftpflicht', -12.50, '2026-09-03', interval '1 month', 1, 'ALZ-HAFT');
select public.refresh_contracts();
select is(
  (select rc.mandate_reference from public.transactions t join public.recurring_contracts rc on rc.id = t.recurring_contract_id
    where t.counterparty_name = 'Allianz Versicherungs-AG' and t.booking_date = '2026-09-03'),
  'ALZ-HAFT', 'Neue Abbuchung beim Vertrag mit gleichem Mandat'
);

-- ---------------------------------------------------------------------
-- 4. Verknüpfen bestätigter Verträge, Gegenbuchungen (22–29)
-- ---------------------------------------------------------------------
select public.set_contract_status(rc.id, 'active', 'membership')
  from public.recurring_contracts rc
 where rc.counterparty_key = (select counterparty_key from public.transactions where counterparty_name = 'Fitnessstudio Kraftwerk' limit 1);
select set_config('test.fit', pg_temp.contract('Fitnessstudio Kraftwerk', -39.90)::text, true);

-- Ein weiteres Mandat, das parallel zum aktuellen läuft, wird nicht verknüpft.
select pg_temp.series('Fitnessstudio Kraftwerk', 'Mitgliedsbeitrag Partner', -39.90, '2026-08-20', interval '1 month', 2, 'FIT-PARTNER');
select pg_temp.series('Fitnessstudio Kraftwerk', 'Mitgliedsbeitrag', -39.90, '2026-09-05', interval '1 month', 1, 'FIT-NEU');
select private.link_contract_bookings(tests.get_supabase_uid('v2_alice'));
select is(
  (select count(*)::integer from public.transactions where mandate_reference = 'FIT-PARTNER' and recurring_contract_id is not null),
  0, 'Parallel laufendes anderes Mandat wird nicht verknüpft'
);
select is(
  (select recurring_contract_id::text from public.transactions where mandate_reference = 'FIT-NEU' and booking_date = '2026-09-05'),
  current_setting('test.fit'), 'Gleiches Mandat wird verknüpft'
);

-- Gegenbuchungen: Erstattung in Toleranz nach der ersten Abbuchung.
insert into public.transactions (account_id, booking_date, amount, currency, counterparty_name, purpose, mandate_reference) values
  ('7d000000-0000-4000-8000-0000000000a1', '2026-09-12',  39.90, 'EUR', 'Fitnessstudio Kraftwerk', 'Rücklastschrift', 'FIT-NEU'),
  ('7d000000-0000-4000-8000-0000000000a1', '2026-01-10',  39.90, 'EUR', 'Fitnessstudio Kraftwerk', 'Gutschrift vor Beginn', null),
  ('7d000000-0000-4000-8000-0000000000a1', '2026-09-15',   5.00, 'EUR', 'Fitnessstudio Kraftwerk', 'Bonus', null),
  ('7d000000-0000-4000-8000-0000000000a1', '2026-09-16',  39.90, 'EUR', 'Fitnessstudio Kraftwerk', 'Gutschrift Partner', 'FIT-PARTNER');
select public.refresh_contracts();
select results_eq(
  $$ select purpose, recurring_contract_id is not null from public.transactions
      where counterparty_name = 'Fitnessstudio Kraftwerk' and amount > 0 order by booking_date $$,
  $$ values ('Gutschrift vor Beginn'::text, false), ('Rücklastschrift', true), ('Bonus', false), ('Gutschrift Partner', false) $$,
  'Gegenbuchung in Toleranz ab der ersten Abbuchung; nicht davor, nicht außerhalb der Toleranz, nicht vom parallelen Mandat'
);
select results_eq(
  format($$ select first_booking_date, last_booking_date, mandate_reference from public.recurring_contracts where id = %L $$,
         current_setting('test.fit')),
  $$ values ('2026-02-05'::date, '2026-09-05'::date, 'FIT-NEU'::text) $$,
  'Termine und Mandat folgen nur den Abbuchungen (Gegenbuchung vom 12.09. zählt nicht)'
);
select is(
  (select next_expected_date from public.recurring_contracts where id = current_setting('test.fit')::uuid),
  '2026-10-05'::date, 'Nächste Abbuchung aus der letzten Abbuchung'
);

-- Gläubiger-ID des Vertrags aus der letzten Abbuchung.
select pg_temp.series('Stadtwerke Musterstadt', 'Abschlag Strom CRED+DE77ZZZ00000077777', -80, '2026-04-15', interval '1 month', 5,
                      'SWM-STROM');
select public.refresh_contracts();
select results_eq(
  $$ select mandate_reference, creditor_id from public.recurring_contracts
      where counterparty_key = (select counterparty_key from public.transactions where counterparty_name = 'Stadtwerke Musterstadt' limit 1) $$,
  $$ values ('SWM-STROM'::text, 'DE77ZZZ00000077777'::text) $$,
  'Vertrag übernimmt Mandat und Gläubiger-ID'
);

-- Lösen einer Gegenbuchung bleibt bestehen.
select public.set_contract_link((select id from public.transactions where purpose = 'Rücklastschrift'), null);
select public.refresh_contracts();
select is(
  (select recurring_contract_id from public.transactions where purpose = 'Rücklastschrift'), null,
  'Manuell gelöste Gegenbuchung wird nicht wieder verknüpft'
);
select public.set_contract_link((select id from public.transactions where purpose = 'Rücklastschrift'), current_setting('test.fit')::uuid);

-- Ohne Abbuchungen: Termine und Mandat leer.
select public.set_contract_status(rc.id, 'active', 'energy')
  from public.recurring_contracts rc
 where rc.counterparty_key = (select counterparty_key from public.transactions where counterparty_name = 'Stadtwerke Musterstadt' limit 1);
select set_config('test.swm', (select rc.id::text from public.recurring_contracts rc where rc.mandate_reference = 'SWM-STROM'), true);
select public.set_contract_link(t.id, null)
  from public.transactions t where t.recurring_contract_id = current_setting('test.swm')::uuid;
select results_eq(
  format($$ select first_booking_date, last_booking_date, mandate_reference, creditor_id
              from public.recurring_contracts where id = %L $$, current_setting('test.swm')),
  $$ values (null::date, null::date, null::text, null::text) $$,
  'Ohne verknüpfte Abbuchung: keine Termine, kein Mandat'
);

-- ---------------------------------------------------------------------
-- 5. contract_actuals (30–34)
-- ---------------------------------------------------------------------
select results_eq(
  format($$ select debit_count, debits, credit_count, credits from public.contract_actuals(%L, '2026-01-01', '2026-12-31')
             where contract_id = %L $$, tests.get_supabase_uid('v2_alice'), current_setting('test.fit')),
  $$ values (8, 319.20::numeric, 1, 39.90::numeric) $$,
  'Abbuchungen (8 × 39,90) und Gegenbuchung (39,90) je Vertrag'
);
select results_eq(
  format($$ select debit_count, debits from public.contract_actuals(%L, '2026-09-01', '2026-09-30') where contract_id = %L $$,
         tests.get_supabase_uid('v2_alice'), current_setting('test.fit')),
  $$ values (1, 39.90::numeric) $$,
  'Zeitraum begrenzt'
);
select ok(not has_function_privilege('anon', 'public.contract_actuals(uuid, date, date)', 'execute'),
          'anon darf contract_actuals nicht ausführen');

select tests.authenticate_as('v2_bob');
select is_empty(
  format($$ select * from public.contract_actuals(%L, '2026-01-01', '2026-12-31') $$, tests.get_supabase_uid('v2_alice')),
  'Bob sieht keine fremden Summen'
);
select tests.authenticate_as('v2_carol');
select isnt_empty(
  format($$ select * from public.contract_actuals(%L, '2026-01-01', '2026-12-31') $$, tests.get_supabase_uid('v2_alice')),
  'Beraterin sieht die Summen der Mandantin'
);

-- ---------------------------------------------------------------------
-- 6. Mandantentrennung beim Verknüpfen (35–41)
-- ---------------------------------------------------------------------
select tests.authenticate_as('v2_bob');
insert into public.transactions (account_id, booking_date, amount, currency, counterparty_name, purpose, mandate_reference)
values ('7d000000-0000-4000-8000-0000000000b1', '2026-09-20', 39.90, 'EUR', 'Fitnessstudio Kraftwerk', 'Bob Gutschrift', 'FIT-NEU'),
       ('7d000000-0000-4000-8000-0000000000b1', '2026-09-21', -39.90, 'EUR', 'Fitnessstudio Kraftwerk', 'Bob Beitrag', 'FIT-NEU');
select public.refresh_contracts();
select is_empty($$ select 1 from public.transactions where recurring_contract_id is not null $$,
                'Bobs Buchungen mit gleichem Mandat landen nicht bei Alices Vertrag');
select is_empty($$ select 1 from public.recurring_contracts $$, 'Bob sieht keine fremden Verträge');
select is(
  (select mandate_reference from public.transactions where purpose = 'Bob Beitrag'), 'FIT-NEU',
  'Bob sieht eigenes Mandat'
);
select is_empty($$ select 1 from public.transactions where purpose = 'Rücklastschrift' $$, 'Bob sieht Alices Buchungen nicht');

select tests.authenticate_as('v2_carol');
select is(
  (select mandate_reference from public.recurring_contracts where id = current_setting('test.fit')::uuid), 'FIT-NEU',
  'Beraterin liest Mandat des Vertrags'
);
select set_config('test.fit_links',
  (select count(*)::text from public.transactions where recurring_contract_id = current_setting('test.fit')::uuid), true);
select lives_ok($$ select public.refresh_contracts() $$, 'Erkennung der Beraterin läuft nur auf eigenen Daten');
select is(
  (select count(*)::text from public.transactions where recurring_contract_id = current_setting('test.fit')::uuid),
  current_setting('test.fit_links'), 'Verknüpfungen der Mandantin unverändert'
);

select * from finish();
rollback;
