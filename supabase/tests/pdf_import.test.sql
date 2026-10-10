-- =====================================================================
--  supabase/tests/pdf_import.test.sql
--  PDF-Import (N26): accounts.iban, Kategorie „Privatentnahme“,
--  Kartenkategorien (Regeln origin bank_category, nach Standardregeln),
--  neue Standardregeln (Corendon, Mietwagen, Miete als Gutschrift),
--  public.import_statement() – Vorschau, Import mehrerer Konten,
--  Duplikate mit laufendem Zähler, vorläufiger → Monatsauszug, früherer
--  Monat (Anfangsbestand), Saldenprüfung, „vermutlich vorhanden“, eigene
--  IBANs (auch rückwirkend), Fehler ohne Teilimport, Mandantentrennung
--  (Migration 20261016100100)
--  Ausführen: supabase test db   (setzt 00000-test-helpers.sql voraus)
--
--  Identitäten
--    pi_alice – Nutzerin mit C24-Konto (CSV) und altem manuellem Konto
--    pi_bob   – anderer Nutzer
--    pi_carol – Beraterin, aktive Verbindung zu Alice
-- =====================================================================

begin;

select plan(71);

select tests.create_supabase_user('pi_alice', 'pi-alice@example.test');
select tests.create_supabase_user('pi_bob',   'pi-bob@example.test');
select tests.create_supabase_user('pi_carol', 'pi-carol@example.test');

select tests.authenticate_as_service_role();
update public.profiles set role = 'advisor' where user_id = tests.get_supabase_uid('pi_carol');
insert into public.advisor_clients (advisor_id, user_id, status, invited_email, accepted_at) values
  (tests.get_supabase_uid('pi_carol'), tests.get_supabase_uid('pi_alice'), 'active', 'pi-alice@example.test', now());

-- C24 (CSV) mit Überweisung an den Space; altes manuelles N26-Konto.
insert into public.accounts (id, user_id, name, type, provider, currency) values
  ('9a000000-0000-4000-8000-0000000000c1', tests.get_supabase_uid('pi_alice'), 'C24',       'checking', 'csv',    'EUR'),
  ('9a000000-0000-4000-8000-0000000000c2', tests.get_supabase_uid('pi_alice'), 'Altes N26', 'checking', 'manual', 'EUR');
insert into public.transactions (user_id, account_id, booking_date, amount, currency, counterparty_name,
                                 counterparty_iban, purpose, source) values
  (tests.get_supabase_uid('pi_alice'), '9a000000-0000-4000-8000-0000000000c1', '2026-09-01', -94.89, 'EUR',
   'Max Mustermann', 'DE22100110010000000002', null, 'csv_import'),
  (tests.get_supabase_uid('pi_alice'), '9a000000-0000-4000-8000-0000000000c2', '2026-09-03', -13.21, 'EUR',
   'PENNY MARKT', null, 'Karte', 'manual');

create function pg_temp.cat(p_key text) returns uuid language sql as $$
  select id from public.categories where user_id = tests.get_supabase_uid('pi_alice') and default_key = p_key;
$$;
create function pg_temp.key_of(p_counterparty text, p_date date default null) returns text language sql as $$
  select coalesce(c.default_key, 'none')
    from public.transactions t left join public.categories c on c.id = t.category_id
   where t.user_id = tests.get_supabase_uid('pi_alice') and t.counterparty_name = p_counterparty
     and (p_date is null or t.booking_date = p_date)
   order by t.booking_date, t.created_at limit 1;
$$;
create function pg_temp.r(p_date date, p_amount numeric, p_counterparty text, p_type text default null,
                          p_iban text default null, p_purpose text default null) returns jsonb language sql as $$
  select jsonb_strip_nulls(jsonb_build_object('booking_date', p_date, 'value_date', p_date, 'amount', p_amount,
    'currency', 'EUR', 'counterparty', p_counterparty, 'transaction_type', p_type, 'counterparty_iban', p_iban,
    'purpose', p_purpose));
$$;
create function pg_temp.s(p_iban text, p_account uuid, p_name text, p_opening numeric, p_from date, p_to date,
                          p_rows jsonb, p_closing numeric default null) returns jsonb language sql as $$
  select jsonb_build_object('iban', p_iban, 'account_id', p_account, 'new_account_name', p_name, 'institution', 'N26',
    'opening', p_opening,
    'closing', coalesce(p_closing, p_opening + coalesce((select sum((e ->> 'amount')::numeric) from jsonb_array_elements(p_rows) e), 0)),
    'period_from', p_from, 'period_to', p_to, 'rows', p_rows);
$$;
create function pg_temp.acc(p_iban text) returns uuid language sql as $$
  select id from public.accounts where user_id = tests.get_supabase_uid('pi_alice') and iban = p_iban;
$$;
grant execute on all functions in schema pg_temp to authenticated;

-- Auszug September: Hauptkonto und Space
create temp table st (name text, j jsonb);
grant all on st to authenticated;
insert into st values ('sep', jsonb_build_array(
  pg_temp.s('DE11100110010000000001', null, 'N26 Hauptkonto', 1000, '2026-09-01', '2026-09-30', jsonb_build_array(
    pg_temp.r('2026-09-02', -13.21,   'Penny Markt',            'Mastercard • Lebensmittel'),
    pg_temp.r('2026-09-05', -201.18,  'Corendon Touristik',     'Mastercard • Transport'),
    pg_temp.r('2026-09-06', -5.98,    'Baumarkt Beispiel',      'Mastercard • Wohnen & Energie'),
    pg_temp.r('2026-09-07', -4.00,    'Kiosk Beispiel',         'Mastercard • Freizeit'),
    pg_temp.r('2026-09-08', -36.85,   'C24* MIETWAGEN LAS PAL', 'Mastercard • Transport'),
    pg_temp.r('2026-09-09', -10.00,   'An Ahornweg 2',          null, 'DE22100110010000000002'),
    pg_temp.r('2026-09-19', -10.00,   'Buena Vista',            'Mastercard • Bars & Restaurants'),
    pg_temp.r('2026-09-19', -10.00,   'Buena Vista',            'Mastercard • Bars & Restaurants'),
    pg_temp.r('2026-09-30', 1900.00,  'Gerda Dummy',            'Gutschriften', 'DE44100110010000000044', 'Okt Musterweg Wohnung miete'),
    pg_temp.r('2026-09-30', -1189.99, 'Vermieter KG',           'Belastungen',  'DE55700500000000000055', 'MV 100001 Miete-Wohnen'))),
  pg_temp.s('DE22100110010000000002', null, 'N26 Ahornweg 2', 500, '2026-09-01', '2026-09-30', jsonb_build_array(
    pg_temp.r('2026-09-09', 10.00,    'Von Hauptkonto',         null, 'DE11100110010000000001'),
    pg_temp.r('2026-09-14', -495.03,  'WEG Lindenstrase 46',    'Belastungen', 'DE66120300000000000066', 'Hausgeld Mustermann'),
    pg_temp.r('2026-09-30', 912.00,   'Von Freelancer-Konto',   null, null, 'Privatentnahme')))));

-- ---------------------------------------------------------------------
-- 1. Grundlagen (1–8)
-- ---------------------------------------------------------------------
select has_column('public', 'accounts', 'iban', 'accounts.iban vorhanden');
select throws_ok(
  $$ insert into public.accounts (user_id, name, type, iban)
     values (tests.get_supabase_uid('pi_bob'), 'X', 'checking', 'de12 3456') $$,
  '23514', null, 'IBAN nur in Normalform (Großbuchstaben, ohne Leerzeichen)');
select tests.authenticate_as('pi_bob');
select is(
  (select kind::text || ':' || coalesce(budget_group::text, '-') from public.categories
    where user_id = tests.get_supabase_uid('pi_bob') and default_key = 'private_withdrawal'),
  'income:-', 'Neue Nutzer erhalten „Privatentnahme“ (Einnahmen, ohne 50/30/20-Gruppe)');
select is(
  (select count(*)::int from public.categorization_rules
    where user_id = tests.get_supabase_uid('pi_bob') and origin = 'bank_category'),
  0, 'Neue Nutzer: Kartenkategorien erst mit den Standardregeln');
select is((public.load_standard_rules() ->> 'bank_added')::int, 12,
  '„Standardregeln laden“ ergänzt die Startwerte der Kartenkategorien');
select results_eq(
  $$ select r.pattern, r.match_field::text, r.match_type::text, c.default_key
       from public.categorization_rules r join public.categories c on c.id = r.category_id
      where r.user_id = tests.get_supabase_uid('pi_bob') and r.origin = 'bank_category'
        and r.pattern in ('Lebensmittel', 'Bars & Restaurants', 'Transport')
      order by r.pattern $$,
  $$ values ('Bars & Restaurants'::text, 'transaction_type'::text, 'word'::text, 'leisure_travel'::text),
            ('Lebensmittel', 'transaction_type', 'word', 'groceries'),
            ('Transport', 'transaction_type', 'word', 'mobility') $$,
  'Kartenkategorien: Buchungsart, ganzes Wort, Zielkategorie per Schlüssel');
select is(
  (select count(*)::int from private.bank_category_templates() t
    where t.label ~* 'hausgeld|weg|darlehen|miete'),
  0, 'Keine pauschale Zuordnung für Hausgeld, WEG oder Darlehen');
select results_eq(
  $$ select pattern, match_field::text, default_key, direction from private.standard_rule_templates()
      where pattern in ('corendon', 'mietwagen', 'miete') order by pattern $$,
  $$ values ('corendon'::text, 'counterparty_or_purpose'::text, 'leisure_travel'::text, 'out'::text),
            ('miete', 'purpose', 'rental_income', 'in'),
            ('mietwagen', 'counterparty_or_purpose', 'leisure_travel', 'out') $$,
  'Standardregeln: Corendon und Mietwagen → Reisen, Miete (Gutschrift im Zweck) → Mieteinnahmen');
select ok(not has_function_privilege('anon', 'public.import_statement(jsonb, boolean)', 'execute'),
  'anon darf import_statement nicht ausführen');

-- ---------------------------------------------------------------------
-- 2. Vorschau (9–14)
-- ---------------------------------------------------------------------
select tests.authenticate_as('pi_alice');
select public.load_standard_rules();

create temp table res (step text, j jsonb);
grant all on res to authenticated;
insert into res select 'dry', public.import_statement((select j from st where name = 'sep'), true);

select is((select count(*)::int from public.accounts where iban is not null), 0, 'Vorschau legt keine Konten an');
select is((select count(*)::int from public.transactions where source = 'pdf_import'), 0, 'Vorschau schreibt keine Buchungen');
select results_eq(
  $$ select (e ->> 'new')::int, (e ->> 'duplicates')::int, (e ->> 'new_account')::boolean, (e ->> 'opening_set')::boolean,
            (e ->> 'balance')::numeric = (e ->> 'closing')::numeric
       from res, jsonb_array_elements(res.j -> 'sections') e where res.step = 'dry' $$,
  $$ values (10, 0, true, true, true), (3, 0, true, true, true) $$,
  'Vorschau je Konto: neu, Duplikate, neues Konto, Anfangsbestand, Kontostand = Auszug');
select is((select (j ->> 'own_ibans_added')::int from res where step = 'dry'), 2, 'Vorschau: zwei IBANs werden eigene Konten');
select ok((select (j -> 'sections' -> 0 ->> 'categorized')::int from res where step = 'dry') >= 9,
  'Vorschau: interne Umbuchung zählt als zugeordnet');
select is((select count(*)::int from public.categorization_rules where origin = 'own_account'), 0,
  'Vorschau legt keine eigenen Konten an');

-- ---------------------------------------------------------------------
-- 3. Import September (15–32)
-- ---------------------------------------------------------------------
insert into res select 'sep', public.import_statement((select j from st where name = 'sep'));

select results_eq(
  $$ select name, provider::text, institution_name, iban_last4, opening_balance, balance from public.accounts
      where iban is not null order by iban $$,
  $$ values ('N26 Hauptkonto'::text, 'csv'::text, 'N26'::text, '0001'::text, 1000.00::numeric, 1418.79::numeric),
            ('N26 Ahornweg 2', 'csv', 'N26', '0002', 500.00, 926.97) $$,
  'Konten mit IBAN, Anfangsbestand = alter Kontostand, Saldo = neuer Kontostand');
select is((select count(*)::int from public.transactions where source = 'pdf_import'), 13, '13 Buchungen importiert (Quelle pdf_import)');
select is((select count(*)::int from public.transactions where counterparty_name = 'Buena Vista'), 2,
  'Zwei gleiche Buchungen am selben Tag bleiben zwei');
select results_eq(
  $$ select r.pattern, c.default_key from public.categorization_rules r join public.categories c on c.id = r.category_id
      where r.origin = 'own_account' order by r.pattern $$,
  $$ values ('DE11100110010000000001'::text, 'transfer'::text), ('DE22100110010000000002', 'transfer') $$,
  'IBANs des Auszugs sind eigene Konten (Umbuchung)');
select is((select (j ->> 'own_ibans_added')::int from res where step = 'sep'), 2, 'Ergebnis: zwei eigene IBANs ergänzt');
select is(pg_temp.key_of('Penny Markt'), 'groceries', 'Kartenkategorie Lebensmittel (bzw. Marke) → Lebensmittel');
select is(pg_temp.key_of('Corendon Touristik'), 'leisure_travel', 'Marke vor Kartenkategorie: Corendon → Freizeit & Reisen statt Transport');
select is(pg_temp.key_of('C24* MIETWAGEN LAS PAL'), 'leisure_travel', 'Mietwagen → Freizeit & Reisen statt Transport');
select is(pg_temp.key_of('Baumarkt Beispiel'), 'housing', 'Kartenkategorie Wohnen & Energie → Wohnen');
select is(pg_temp.key_of('Kiosk Beispiel'), 'leisure_travel', 'Kartenkategorie Freizeit → Freizeit & Reisen');
select is(
  (select r.origin from public.transactions t join public.categorization_rules r on r.id = t.categorization_rule_id
    where t.counterparty_name = 'Kiosk Beispiel'),
  'bank_category', 'Zuordnung über die Regel der Kartenkategorie');
select is(pg_temp.key_of('Gerda Dummy'), 'rental_income', 'Gutschrift mit „Miete“ im Zweck → Mieteinnahmen');
select isnt(pg_temp.key_of('Vermieter KG'), 'rental_income', 'Abbuchung „Miete-Wohnen“ ist keine Mieteinnahme');
select is(pg_temp.key_of('WEG Lindenstrase 46'), 'none', 'Hausgeld/WEG: keine pauschale Zuordnung');
select is(pg_temp.key_of('An Ahornweg 2'), 'transfer', 'Interne Buchung „An Space“ → Umbuchung');
select is(pg_temp.key_of('Von Hauptkonto'), 'transfer', 'Interne Buchung „Von Hauptkonto“ → Umbuchung');
select is(pg_temp.key_of('Max Mustermann'), 'transfer', 'Gegenseite auf dem C24-Konto rückwirkend als Umbuchung erkannt');
select is(
  (public.spending_report(tests.get_supabase_uid('pi_alice'), '2026-09-01', '2026-09-30', 'day') -> 'transfers' -> 0 ->> 'count')::int,
  3, 'Ausgaben-Dashboard: drei Umbuchungen über eigene IBANs zählen nicht');

-- ---------------------------------------------------------------------
-- 4. Erneuter Import, vorläufiger → Monatsauszug, früherer Monat (33–44)
-- ---------------------------------------------------------------------
-- Ziel: die Konten mit dieser IBAN (ein neues Konto wäre „iban_in_use“).
insert into res select 'again', public.import_statement(jsonb_build_array(
  jsonb_set((select j -> 0 from st where name = 'sep'), '{account_id}', to_jsonb(pg_temp.acc('DE11100110010000000001'))),
  jsonb_set((select j -> 1 from st where name = 'sep'), '{account_id}', to_jsonb(pg_temp.acc('DE22100110010000000002')))));
select results_eq(
  $$ select (e ->> 'new')::int, (e ->> 'duplicates')::int, (e ->> 'opening_set')::boolean
       from res, jsonb_array_elements(res.j -> 'sections') e where res.step = 'again' $$,
  $$ values (0, 10, false), (0, 3, false) $$,
  'Erneuter Import: nichts neu, alles Duplikat, Anfangsbestand bleibt');
select is((select count(*)::int from public.transactions where source = 'pdf_import'), 13, 'Erneuter Import doppelt nichts');

insert into st values ('okt_v', jsonb_build_array(
  pg_temp.s('DE11100110010000000001', pg_temp.acc('DE11100110010000000001'), null, 1418.79, '2026-10-01', '2026-10-08', jsonb_build_array(
    pg_temp.r('2026-10-02', -19.99, 'CAYA GMBH',      'Mastercard • Medien & Telekom'),
    pg_temp.r('2026-10-05', -48.99, 'Energie Muster', 'Lastschriften', 'DE77370400440000000077', 'REF-1')))));
insert into st values ('okt', jsonb_build_array(
  pg_temp.s('DE11100110010000000001', pg_temp.acc('DE11100110010000000001'), null, 1418.79, '2026-10-01', '2026-10-31', jsonb_build_array(
    pg_temp.r('2026-10-02', -19.99, 'CAYA GMBH',      'Mastercard • Medien & Telekom'),
    pg_temp.r('2026-10-05', -48.99, 'Energie Muster', 'Lastschriften', 'DE77370400440000000077', 'REF-1'),
    pg_temp.r('2026-10-17', -10.00, 'Buena Vista',    'Mastercard • Bars & Restaurants'),
    pg_temp.r('2026-10-17', -10.00, 'Buena Vista',    'Mastercard • Bars & Restaurants'),
    pg_temp.r('2026-10-20', -89.00, 'Corendon Touristik', 'Mastercard • Transport')))));
insert into res select 'okt_v', public.import_statement((select j from st where name = 'okt_v'));
insert into res select 'okt', public.import_statement((select j from st where name = 'okt'));
select results_eq(
  $$ select res.step, (e ->> 'new')::int, (e ->> 'duplicates')::int, (e ->> 'balance')::numeric = (e ->> 'closing')::numeric
       from res, jsonb_array_elements(res.j -> 'sections') e where res.step in ('okt_v', 'okt') order by res.step desc $$,
  $$ values ('okt_v'::text, 2, 0, true), ('okt', 3, 2, true) $$,
  'Vorläufiger Auszug, dann Monatsauszug: nur die neuen Buchungen, Kontostand stimmt');
select is((select count(*)::int from public.transactions where counterparty_name = 'Buena Vista' and booking_date = '2026-10-17'), 2,
  'Monatsauszug: zwei gleiche Buchungen am selben Tag bleiben zwei');
select is(pg_temp.key_of('CAYA GMBH'), 'subscriptions_media', 'Kartenkategorie Medien & Telekom → Abos & Medien');

insert into st values ('aug', jsonb_build_array(
  pg_temp.s('DE11100110010000000001', pg_temp.acc('DE11100110010000000001'), null, 900, '2026-08-01', '2026-08-31', jsonb_build_array(
    pg_temp.r('2026-08-15', 100.00, 'Erstattung Beispiel', 'Gutschriften', 'DE88370400440000000088', 'Erstattung')))));
insert into res select 'aug', public.import_statement((select j from st where name = 'aug'));
select results_eq(
  $$ select (e ->> 'new')::int, (e ->> 'opening_set')::boolean, (e ->> 'balance')::numeric
       from res, jsonb_array_elements(res.j -> 'sections') e where res.step = 'aug' $$,
  $$ values (1, true, 1000.00::numeric) $$,
  'Früherer Monat: Anfangsbestand rückt nach vorne, Kontostand zum Monatsende = Auszug');
select results_eq(
  $$ select opening_balance, balance from public.accounts where iban = 'DE11100110010000000001' $$,
  $$ values (900.00::numeric, 1240.81::numeric) $$,
  'Hauptkonto: Anfangsbestand August, Saldo = Ende Oktober');

-- Lücke: Auszug Dezember ohne November → Hinweis über den Kontostand (Vorschau)
insert into st values ('dez', jsonb_build_array(
  pg_temp.s('DE11100110010000000001', pg_temp.acc('DE11100110010000000001'), null, 1500, '2026-12-01', '2026-12-31', jsonb_build_array(
    pg_temp.r('2026-12-01', -5.00, 'Kiosk Beispiel', 'Mastercard • Freizeit')))));
insert into res select 'dez', public.import_statement((select j from st where name = 'dez'), true);
select results_eq(
  $$ select (e ->> 'opening_set')::boolean, (e ->> 'balance')::numeric, (e ->> 'closing')::numeric
       from res, jsonb_array_elements(res.j -> 'sections') e where res.step = 'dez' $$,
  $$ values (false, 1235.81::numeric, 1495.00::numeric) $$,
  'Fehlender Auszug dazwischen: Kontostand weicht vom Auszug ab (Hinweis statt Abbruch)');

-- ---------------------------------------------------------------------
-- 5. Fehler ohne Teilimport (45–53)
-- ---------------------------------------------------------------------
create temp table counts as select (select count(*) from public.transactions) as tx, (select count(*) from public.accounts) as acc;
grant select on counts to authenticated;

select throws_ok(
  $$ select public.import_statement(jsonb_build_array(
       pg_temp.s('DE91100110010000000091', null, 'Neu A', 0, '2026-09-01', '2026-09-30',
                 jsonb_build_array(pg_temp.r('2026-09-02', -1.00, 'A'))),
       pg_temp.s('DE92100110010000000092', null, 'Neu B', 0, '2026-09-01', '2026-09-30',
                 jsonb_build_array(pg_temp.r('2026-09-02', -1.00, 'B')), 5))) $$,
  '22023', 'balance_mismatch', 'Saldo eines Kontos passt nicht → Abbruch');
select ok((select tx = (select count(*) from public.transactions) and acc = (select count(*) from public.accounts) from counts),
  'Nach dem Abbruch: keine Buchungen, keine Konten (auch nicht vom korrekten Abschnitt)');
select throws_ok(
  $$ select public.import_statement(jsonb_build_array(
       pg_temp.s('DE11100110010000000001', null, 'Doppelt', 0, '2026-09-01', '2026-09-30', '[]'::jsonb))) $$,
  '23505', 'iban_in_use', 'Neues Konto für eine vorhandene IBAN → iban_in_use');
select throws_ok(
  $$ select public.import_statement(jsonb_build_array(
       pg_temp.s('DE22100110010000000002', pg_temp.acc('DE11100110010000000001'), null, 0, '2026-09-01', '2026-09-30', '[]'::jsonb))) $$,
  '22023', 'iban_mismatch', 'Zielkonto mit anderer IBAN → iban_mismatch');
select throws_ok(
  $$ select public.import_statement(jsonb_build_array(
       pg_temp.s('DE91100110010000000091', '9a000000-0000-4000-8000-0000000000c2', null, 0, '2026-09-01', '2026-09-30', '[]'::jsonb),
       pg_temp.s('DE92100110010000000092', '9a000000-0000-4000-8000-0000000000c2', null, 0, '2026-09-01', '2026-09-30', '[]'::jsonb))) $$,
  '22023', 'duplicate_target', 'Zwei Abschnitte auf dasselbe Konto → duplicate_target');
select throws_ok(
  $$ select public.import_statement(jsonb_build_array(
       pg_temp.s('DE91100110010000000091', null, 'A', 0, '2026-09-01', '2026-09-30', '[]'::jsonb),
       pg_temp.s('DE91100110010000000091', null, 'B', 0, '2026-09-01', '2026-09-30', '[]'::jsonb))) $$,
  '22023', 'duplicate_section', 'Dieselbe IBAN zweimal → duplicate_section');
select throws_ok(
  $$ select public.import_statement(jsonb_build_array(
       pg_temp.s('DE91100110010000000091', null, null, 0, '2026-09-01', '2026-09-30', '[]'::jsonb))) $$,
  '22023', 'invalid_account_name', 'Neues Konto ohne Namen → invalid_account_name');
select throws_ok(
  $$ select public.import_statement('[{"iban": "kein", "opening": 0, "closing": 0, "period_from": "2026-09-01",
                                      "period_to": "2026-09-30", "rows": []}]'::jsonb) $$,
  '22023', 'invalid_section', 'Ungültige IBAN → invalid_section');
select throws_ok(
  $$ select public.import_statement('[]'::jsonb) $$,
  '22023', 'invalid_sections', 'Leerer Auszug → invalid_sections');

-- ---------------------------------------------------------------------
-- 6. Vermutlich vorhanden (gleiche Buchung aus anderer Quelle) (54–57)
-- ---------------------------------------------------------------------
insert into res select 'probable', public.import_statement(jsonb_build_array(
  pg_temp.s('DE93100110010000000093', '9a000000-0000-4000-8000-0000000000c2', null, 50, '2026-09-01', '2026-09-30', jsonb_build_array(
    pg_temp.r('2026-09-03', -13.21, 'Penny Markt', 'Mastercard • Lebensmittel'),
    pg_temp.r('2026-09-03', -13.21, 'Penny Markt', 'Mastercard • Lebensmittel'),
    pg_temp.r('2026-09-04', -5.00,  'Baecker Beispiel', 'Mastercard • Lebensmittel')))));
select results_eq(
  $$ select (e ->> 'new')::int, (e ->> 'probable')::int, e -> 'probable_rows' -> 0 ->> 'counterparty'
       from res, jsonb_array_elements(res.j -> 'sections') e where res.step = 'probable' $$,
  $$ values (2, 1, 'Penny Markt'::text) $$,
  'Gleiches Datum und Betrag aus anderer Quelle: einmal übersprungen, die zweite gleiche Buchung ist neu');
select is((select count(*)::int from public.transactions where account_id = '9a000000-0000-4000-8000-0000000000c2'), 3,
  'Konto „Altes N26“: manuelle Buchung + 2 neue');
select is((select iban from public.accounts where id = '9a000000-0000-4000-8000-0000000000c2'), 'DE93100110010000000093',
  'Vorhandenes Konto ohne IBAN erhält die IBAN des Abschnitts');
insert into res select 'probable2', public.import_statement(jsonb_build_array(
  pg_temp.s('DE93100110010000000093', '9a000000-0000-4000-8000-0000000000c2', null, 50, '2026-09-01', '2026-09-30', jsonb_build_array(
    pg_temp.r('2026-09-03', -13.21, 'Penny Markt', 'Mastercard • Lebensmittel'),
    pg_temp.r('2026-09-03', -13.21, 'Penny Markt', 'Mastercard • Lebensmittel'),
    pg_temp.r('2026-09-04', -5.00,  'Baecker Beispiel', 'Mastercard • Lebensmittel')))));
select results_eq(
  $$ select (e ->> 'new')::int, (e ->> 'duplicates')::int, (e ->> 'probable')::int
       from res, jsonb_array_elements(res.j -> 'sections') e where res.step = 'probable2' $$,
  $$ values (0, 2, 1) $$,
  'Erneut: weiterhin einmal „vermutlich vorhanden“, Rest Duplikate');

-- ---------------------------------------------------------------------
-- 7. Kartenkategorien ändern, Privatentnahme-Regel, Kennzahlen (58–67)
-- ---------------------------------------------------------------------
select throws_ok($$ select public.add_bank_category_rule('lebensmittel', pg_temp.cat('shopping')) $$,
  '23505', 'rule_exists', 'Kartenkategorie doppelt (Schreibweise egal) → rule_exists');
select throws_ok($$ select public.add_bank_category_rule('  ', pg_temp.cat('shopping')) $$,
  '22023', 'invalid_label', 'Leere Kartenkategorie → invalid_label');
select is((public.add_bank_category_rule('Familie & Freunde', pg_temp.cat('other_expenses')) ->> 'applied')::int, 0,
  'Neue Kartenkategorie ohne passende Buchung');

-- Eine Buchung „Buena Vista“ manuell bestätigt: bleibt beim Ändern der Zuordnung.
select tests.authenticate_as_service_role();
update public.transactions set categorization_source = 'manual'
 where id = (select id from public.transactions where counterparty_name = 'Buena Vista' and booking_date = '2026-09-19'
              order by created_at limit 1);
select tests.authenticate_as('pi_alice');
select is(
  public.set_bank_category_rule(
    (select id from public.categorization_rules where origin = 'bank_category' and pattern = 'Bars & Restaurants'),
    pg_temp.cat('groceries')),
  3, 'Zuordnung geändert: automatische Zuordnungen dieser Kartenkategorie neu (3)');
select results_eq(
  $$ select c.default_key, count(*)::int from public.transactions t join public.categories c on c.id = t.category_id
      where t.counterparty_name = 'Buena Vista' group by c.default_key order by c.default_key $$,
  $$ values ('groceries'::text, 3), ('leisure_travel', 1) $$,
  'Manuell bestätigte Buchung bleibt unverändert');
select throws_ok(
  $$ select public.set_bank_category_rule(
       (select id from public.categorization_rules where origin = 'own_account' limit 1), pg_temp.cat('groceries')) $$,
  'P0002', 'rule_not_found', 'Nur Kartenkategorien über set_bank_category_rule');
select ok((select (public.categorization_stats() ->> 'standard')::int) >= 5,
  'Kennzahlen: Kartenkategorien zählen zu den Standardregeln');

-- Regel „Freelancer-Konto“ → Privatentnahme (wie im Cloud-Skript)
select tests.authenticate_as_service_role();
insert into public.categorization_rules (user_id, category_id, pattern, match_type, match_field, amount_min, priority, origin)
values (tests.get_supabase_uid('pi_alice'), pg_temp.cat('private_withdrawal'), 'Freelancer-Konto', 'word', 'counterparty',
        0.01, 1, 'manual');
select tests.authenticate_as('pi_alice');
select ok(public.apply_categorization_rules() >= 1, 'Regel angewendet');
select is(pg_temp.key_of('Von Freelancer-Konto'), 'private_withdrawal', '„Von Freelancer-Konto“ → Privatentnahme (Einnahme)');
select is(
  (select (e ->> 'class') from jsonb_array_elements(
     public.spending_report(tests.get_supabase_uid('pi_alice'), '2026-09-01', '2026-09-30', 'day') -> 'categories') e
    where e ->> 'category_id' = pg_temp.cat('private_withdrawal')::text),
  'income', 'Dashboard: Privatentnahme zählt als Einnahme');

-- ---------------------------------------------------------------------
-- 8. Mandantentrennung (68–74)
-- ---------------------------------------------------------------------
select tests.authenticate_as('pi_bob');
select throws_ok(
  $$ select public.import_statement(jsonb_build_array(
       pg_temp.s('DE94100110010000000094', '9a000000-0000-4000-8000-0000000000c1', null, 0, '2026-09-01', '2026-09-30', '[]'::jsonb))) $$,
  'P0002', 'account_not_found', 'Bob kann nicht in Alices Konto importieren');
select is((select count(*)::int from public.accounts where iban is not null), 0, 'Bob sieht keine IBANs von Alice');
select throws_ok(
  $$ select public.add_bank_category_rule('Neu', pg_temp.cat('groceries')) $$,
  'P0002', 'category_not_found', 'Bob kann keine Kartenkategorie auf Alices Kategorie anlegen');
select is(
  (select count(*)::int from public.categorization_rules where origin = 'bank_category' and user_id <> auth.uid()), 0,
  'Bob sieht keine fremden Kartenkategorien');

select tests.authenticate_as('pi_carol');
select is((select count(*)::int from public.accounts where iban like 'DE%'), 3, 'Beraterin liest Alices Konten mit IBAN');
select throws_ok(
  $$ select public.import_statement(jsonb_build_array(
       pg_temp.s('DE95100110010000000095', pg_temp.acc('DE11100110010000000001'), null, 0, '2026-09-01', '2026-09-30', '[]'::jsonb))) $$,
  'P0002', 'account_not_found', 'Beraterin kann nicht in Alices Konto importieren');
select throws_ok(
  $$ select public.set_bank_category_rule(
       (select id from public.categorization_rules where origin = 'bank_category' and pattern = 'Lebensmittel'
          and user_id = tests.get_supabase_uid('pi_alice')),
       pg_temp.cat('shopping')) $$,
  'P0002', 'category_not_found', 'Beraterin ändert keine Kartenkategorien');

select * from finish();
rollback;
