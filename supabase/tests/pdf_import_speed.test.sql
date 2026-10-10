-- =====================================================================
--  supabase/tests/pdf_import_speed.test.sql
--  PDF-Import mit vielen vorhandenen Buchungen unter einem Zeitlimit
--  (Migration 20261017100000): Neue eigene IBANs werden nur auf Buchungen
--  mit diesen IBANs angewendet, nicht auf alle – sonst überschritt der
--  echte Import das Zeitlimit der Rolle authenticated (SQLSTATE 57014),
--  während der Probelauf durchlief. Ebenso „Eigenes Konto hinzufügen“
--  (IBAN) und „Zielkategorie ändern“.
--  Ausführen: supabase test db   (setzt 00000-test-helpers.sql voraus)
-- =====================================================================

begin;

select plan(9);

select tests.create_supabase_user('ps_alice', 'ps-alice@example.test');
-- Testdaten als Eigentümer der Datenbank anlegen (ohne RLS, mit Zugriff auf
-- private.*); der Import selbst läuft unten als angemeldete Nutzerin.

-- C24-Konto mit 2.000 offenen Buchungen; 30 davon an das N26-Hauptkonto
-- (zwei davon manuell unterschiedlich bestätigt – so entsteht kein
-- Gegenpartei-Gedächtnis für die IBAN, das vor eigenen Konten greifen würde),
-- 10 an ein weiteres eigenes Konto.
insert into public.accounts (id, user_id, name, type, provider, currency) values
  ('9b000000-0000-4000-8000-0000000000c1', tests.get_supabase_uid('ps_alice'), 'C24', 'checking', 'csv', 'EUR');
insert into public.transactions (user_id, account_id, booking_date, amount, currency, counterparty_name, counterparty_iban,
                                 purpose, transaction_type, source)
select tests.get_supabase_uid('ps_alice'), '9b000000-0000-4000-8000-0000000000c1',
       date '2025-01-01' + (g % 600), -(5 + g % 300), 'EUR',
       (array['REWE Markt', 'Deutsche Bahn', 'Netflix', 'Stadtwerke', 'Kino Center', 'Max Muster'])[1 + g % 6],
       case when g % 66 = 0 then 'DE11100110010000000001'
            when g % 199 = 0 then 'DE99500240240000000099' end,
       'Beleg ' || g || ' Karte ' || (g % 97), 'Kartenzahlung', 'csv_import'
  from generate_series(1, 2000) g;
update public.transactions t
   set category_id = (select id from public.categories where user_id = tests.get_supabase_uid('ps_alice') and default_key = m.key),
       categorization_source = 'manual'
  from (select x.id, case when row_number() over (order by x.booking_date) = 1 then 'groceries' else 'shopping' end as key
          from public.transactions x
         where x.counterparty_iban = 'DE11100110010000000001' and x.user_id = tests.get_supabase_uid('ps_alice')
         order by x.booking_date limit 2) m
 where t.id = m.id;

-- Standardregeln und Kartenkategorien wie nach „Standardregeln laden“,
-- ohne sie hier auf die 2.000 Buchungen anzuwenden.
insert into public.categorization_rules
  (user_id, category_id, pattern, match_type, match_field, amount_min, amount_max, priority, origin)
select tests.get_supabase_uid('ps_alice'), c.id, t.pattern, t.match_type, t.match_field,
       case when t.direction = 'in' then 0.01 end, case when t.direction = 'out' then -0.01 end, t.priority, 'standard'
  from private.standard_rule_templates() t
  join public.categories c on c.user_id = tests.get_supabase_uid('ps_alice') and c.default_key = t.default_key;
select private.seed_bank_category_rules(tests.get_supabase_uid('ps_alice'));

select tests.authenticate_as('ps_alice');
set local statement_timeout = '4s';

-- Eigenes Konto (IBAN) auf der Regeln-Seite: vor dem Import, damit das
-- Lernverfahren (läuft nach jedem Import) die Buchungen noch nicht berührt hat.
select is(
  (public.add_own_account_identifier('iban', 'DE99500240240000000099') ->> 'applied')::int,
  10, 'Eigenes Konto (IBAN) hinzufügen: unter dem Zeitlimit, 10 Buchungen zugeordnet');
select is(
  public.set_own_account_category(
    (select id from public.categorization_rules where origin = 'own_account' and pattern = 'DE99500240240000000099'),
    (select id from public.categories where user_id = auth.uid() and default_key = 'savings_investments')),
  10, 'Zielkategorie ändern: unter dem Zeitlimit, 10 Buchungen neu zugeordnet');
select is(
  (select count(*)::int from public.transactions t join public.categories c on c.id = t.category_id
    where t.counterparty_iban = 'DE99500240240000000099' and c.default_key = 'savings_investments'),
  10, 'Neue Zielkategorie angewendet');


select lives_ok(
  $$ select public.import_statement(jsonb_build_array(
       jsonb_build_object('iban', 'DE11100110010000000001', 'account_id', null, 'new_account_name', 'N26 Hauptkonto', 'institution', 'N26',
         'opening', 100, 'closing', 90, 'period_from', '2026-10-01', 'period_to', '2026-10-08',
         'rows', jsonb_build_array(jsonb_build_object('booking_date', '2026-10-02', 'amount', -10, 'currency', 'EUR',
           'counterparty', 'An Ahornweg 2', 'counterparty_iban', 'DE22100110010000000002'))),
       jsonb_build_object('iban', 'DE22100110010000000002', 'account_id', null, 'new_account_name', 'N26 Ahornweg 2', 'institution', 'N26',
         'opening', 0, 'closing', 10, 'period_from', '2026-10-01', 'period_to', '2026-10-08',
         'rows', jsonb_build_array(jsonb_build_object('booking_date', '2026-10-02', 'amount', 10, 'currency', 'EUR',
           'counterparty', 'Von Hauptkonto', 'counterparty_iban', 'DE11100110010000000001'))))) $$,
  'Echter Import mit 2.000 vorhandenen Buchungen bleibt unter dem Zeitlimit');
select is((select count(*)::int from public.accounts where institution_name = 'N26'), 2, 'Zwei N26-Konten angelegt');
select is(
  (select count(*)::int from public.transactions t join public.categories c on c.id = t.category_id
    where t.counterparty_iban = 'DE11100110010000000001' and c.default_key = 'transfer'),
  29, 'Vorhandene Überweisungen an die neue eigene IBAN → Umbuchung (28 auf C24 + Gegenbuchung im Space)');
select results_eq(
  $$ select c.default_key from public.transactions t join public.categories c on c.id = t.category_id
      where t.counterparty_iban = 'DE11100110010000000001' and t.categorization_source = 'manual' order by 1 $$,
  $$ values ('groceries'::text), ('shopping') $$,
  'Manuell bestätigte Buchungen bleiben unverändert');
select is(
  (select count(*)::int from public.transactions where account_id = '9b000000-0000-4000-8000-0000000000c1'
     and counterparty_iban is null and categorization_source = 'rule'),
  0, 'Buchungen ohne die neuen IBANs werden von den neuen Regeln nicht angefasst');

select ok(not has_function_privilege('anon', 'private.apply_own_iban_rules(uuid, uuid[])', 'execute'),
  'anon darf private.apply_own_iban_rules nicht ausführen');

select * from finish();
rollback;
