-- =====================================================================
--  supabase/tests/categorization_b2.test.sql
--  PR B2: Wortmerkmale, Naive Bayes (Laplace), Schwelle, Prüfgrenze,
--  Prüfliste, kein Selbsttraining, Genauigkeit an zurückgehaltenen Daten
--  (Migration 20261009100000)
--  Ausführen: supabase test db   (setzt 00000-test-helpers.sql voraus)
-- =====================================================================

begin;

select plan(39);

select tests.create_supabase_user('b2_alice', 'b2-alice@example.test');
select tests.create_supabase_user('b2_bob',   'b2-bob@example.test');

select tests.authenticate_as_service_role();
insert into public.accounts (id, user_id, name, type, currency, provider) values
  ('5c000000-0000-4000-8000-000000000001', tests.get_supabase_uid('b2_alice'), 'Giro', 'checking', 'EUR', 'csv'),
  ('5c000000-0000-4000-8000-000000000002', tests.get_supabase_uid('b2_bob'),   'Giro', 'checking', 'EUR', 'csv');

create temp table cat as
select c.default_key as key, c.id
  from public.categories c
 where c.user_id = tests.get_supabase_uid('b2_alice')
   and c.default_key in ('groceries', 'mobility', 'leisure_travel', 'health', 'housing', 'shopping');
grant select on cat to authenticated, service_role;

-- ---------------------------------------------------------------------
-- 1. Wortmerkmale (1–10)
-- ---------------------------------------------------------------------
select tests.authenticate_as('b2_alice');
select is(private.bayes_words('REWE SAGT DANKE 12345678 Karte 1234 01.09.2026 18:45'),
  array['rewe', 'sagt', 'danke', 'karte'], 'Zahlen, Datum und Uhrzeit fallen weg');
select is(private.bayes_words('AMAZON PRIME*AB12CD Amzn.com/bill'),
  array['amazon', 'prime', 'amzn', 'bill'], 'Gemischter Code ab12cd und Web-Rest com fallen weg');
select is(private.bayes_words('McFit24 Check24 Beitrag'), array['mcfit', 'check', 'beitrag'],
  'Buchstaben + Ziffern am Ende: Buchstaben bleiben (mcfit24 → mcfit)');
select is(private.bayes_words('Müller & Söhne RE 2026-0815'), array['mueller', 'soehne', 're'],
  'Umlaute ausgeschrieben, „re“ bleibt');
select is(private.bayes_words('Erstattung LU89 7510 0001 2345 6789 003 EREF+ABC SVWZ+Danke'),
  array['erstattung', 'abc', 'danke'], 'IBAN (mit Leerzeichen) und SEPA-Kürzel fallen weg');
select is(private.bayes_words('Spotify AB Inc Co et Cie SA SAS BV NV UG OHG eV'), array['spotify'],
  'Rechtsformen als Stoppwörter');
select is(private.bayes_words('o2 und 1&1'), array['o2'], 'Kurze Namen mit Ziffer bleiben, reine Zahlen nicht');
select is(
  private.bayes_base_features('REWE Markt GmbH', 'REWE SAGT DANKE 12345678', null, 'Kartenzahlung', -42.5),
  array['rewe', 'markt', 'sagt', 'danke', 't:kartenzahlung', 's:aus', 'p:rewe_markt'],
  'Basismerkmale: Wörter je einmal, t:, s:, p:'
);
select ok(
  not exists (select 1 from unnest(private.bayes_base_features('PayPal (Europe) S.a.r.l. et Cie., S.C.A.',
              'PP.1234.PP . SPOTIFY, Ihr Einkauf bei SPOTIFY AB', null, 'Lastschrift', -10.99)) f where f like 'p:%'),
  'Kein p: bei Zahlungsvermittlern'
);
select is(private.bayes_features(array['x'], 'monthly', 'DE89 3704 0044 0532 0130 00', -1200, true),
  array['x', 'r:monthly', 'i:' || left(md5('DE89370400440532013000'), 12), 'b:>1000'],
  'r: immer, i: (gehasht) und b: nur bei mehrdeutigem Händler');

-- ---------------------------------------------------------------------
-- 2. Trainingsdaten (synthetisch, ohne Standardregel-Händler)
-- ---------------------------------------------------------------------
-- Händlernamen aus Kopfwort (je Kategorie) und kategorieübergreifendem
-- Namensteil – viele Kombinationen kommen im Training nicht vor. Jede
-- siebte Buchung enthält ein Wort aus einer anderen Kategorie (Rauschen).
create temp table vocab (key text, heads text[], words text[]);
insert into vocab values
  ('groceries',      array['Hofladen', 'Wochenmarkt', 'Baeckerei', 'Metzgerei', 'Bioladen'],
                     array['Gemuese', 'Brot', 'Obst', 'Wurst', 'Kaese', 'Einkauf']),
  ('mobility',       array['Tankstelle', 'Parkhaus', 'Stadtbus', 'Taxi', 'Fahrradwerkstatt'],
                     array['Tanken', 'Parken', 'Fahrschein', 'Fahrt', 'Reparatur', 'Diesel']),
  ('leisure_travel', array['Kino', 'Pension', 'Bowlingcenter', 'Theater', 'Eisdiele'],
                     array['Tickets', 'Uebernachtung', 'Vorstellung', 'Eintritt', 'Urlaub', 'Abend']),
  ('health',         array['Praxis', 'Physiotherapie', 'Augenoptik', 'Zahnlabor', 'Hoergeraete'],
                     array['Behandlung', 'Rezept', 'Brille', 'Therapie', 'Zuzahlung', 'Termin']),
  ('housing',        array['Hausverwaltung', 'Wohnbau', 'Schornsteinfeger', 'Hausmeisterdienst', 'Energieversorger'],
                     array['Miete', 'Nebenkosten', 'Abschlag', 'Kehrung', 'Hausgeld', 'Wohnung']),
  ('shopping',       array['Kaufhaus', 'Modehaus', 'Buchladen', 'Elektro', 'Spielwaren'],
                     array['Jacke', 'Buch', 'Kabel', 'Spielzeug', 'Geschenk', 'Schuhe']);
grant select on vocab to authenticated, service_role;

-- 6 Kategorien × 30 Buchungen, manuell zugeordnet.
select tests.authenticate_as_service_role();
insert into public.transactions (user_id, account_id, booking_date, amount, currency, counterparty_name, purpose,
                                 transaction_type, source, category_id, categorization_source)
select tests.get_supabase_uid('b2_alice'), '5c000000-0000-4000-8000-000000000001',
       date '2026-01-01' + (g * 3 + v.ord::int) % 300,
       -round((5 + (g * 37 + v.ord::int * 11) % 180)::numeric, 2), 'EUR',
       v.heads[1 + (g % 5)] || ' ' || (array['Huber', 'Mueller', 'Zentrum', 'Nord', 'Sued', 'Schmidt', 'Am Markt'])[1 + ((g * 3 + v.ord::int) % 7)],
       v.words[1 + (g % 6)] || ' '
         || case when g % 7 = 3 then o.words[1 + (g % 6)] else v.words[1 + ((g + 2) % 6)] end
         || ' Nr ' || (100000 + g * 17),
       'Kartenzahlung', 'csv_import', c.id, 'manual'
  from (select vocab.*, row_number() over (order by vocab.key) as ord from vocab) v
  join cat c on c.key = v.key
  cross join generate_series(0, 29) g
  -- „falsches“ Wort aus der nächsten Kategorie
  join (select vocab.words, row_number() over (order by vocab.key) as ord from vocab) o on o.ord = v.ord % 6 + 1;

select tests.authenticate_as('b2_alice');

select is(private.bayes_build(auth.uid(), false), 180, 'Training: 180 manuelle Buchungen');

-- Zurückgehaltene Daten: Genauigkeit an Buchungen, die nicht im Training waren.
create temp table eval as select public.bayes_evaluate() as r;
grant select on eval to authenticated;
select diag('Holdout-Auswertung: ' || (select r from eval)::text);
select cmp_ok(((select r from eval) ->> 'tested')::int, '>=', 20, 'Holdout: mindestens 20 Testbuchungen (jede fünfte)');
select is(((select r from eval) ->> 'trained')::int + ((select r from eval) ->> 'tested')::int, 180,
  'Holdout: Training und Test überschneiden sich nicht');
select cmp_ok(((select r from eval) ->> 'accuracy')::numeric, '>=', 0.85::numeric,
  'Holdout-Genauigkeit ≥ 85 % (unbekannte Namenskombinationen, Rauschen)');
select cmp_ok(((select r from eval) ->> 'confident_accuracy')::numeric, '>=', 0.95::numeric,
  'Treffer über der Schwelle (automatisch zugeordnet): ≥ 95 % richtig');

-- ---------------------------------------------------------------------
-- 3. Neue Buchungen: Schwelle, Prüfgrenze, Prüfliste (16–27)
-- ---------------------------------------------------------------------
select public.import_transactions('5c000000-0000-4000-8000-000000000001', $j$[
  {"booking_date": "2026-11-01", "amount": -23.40, "counterparty": "Metzgerei Sonnenhof", "purpose": "Wurst Kaese", "transaction_type": "Kartenzahlung"},
  {"booking_date": "2026-11-02", "amount": -61.00, "counterparty": "Tankstelle Linie", "purpose": "Tanken Diesel", "transaction_type": "Kartenzahlung"},
  {"booking_date": "2026-11-03", "amount": -1450.00, "counterparty": "Elektro Mitte", "purpose": "Kabel Geschenk", "transaction_type": "Kartenzahlung"},
  {"booking_date": "2026-11-04", "amount": -12.00, "counterparty": "Unbekannt", "purpose": "Brille Tickets", "transaction_type": "Kartenzahlung"},
  {"booking_date": "2026-11-05", "amount": -9.00, "counterparty": "Niemand", "purpose": "Xyzzy", "transaction_type": "Lastschrift"}
]$j$::jsonb);

create function pg_temp.state(p_purpose text) returns text language sql as $$
  select coalesce(c.default_key, '-') || ':' || coalesce(t.categorization_source::text, '-')
    from public.transactions t left join public.categories c on c.id = t.category_id
   where t.user_id = auth.uid() and t.purpose = p_purpose;
$$;
create function pg_temp.suggestion(p_purpose text) returns text language sql as $$
  select coalesce(c.default_key, '-')
    from public.transactions t left join public.categories c on c.id = t.suggested_category_id
   where t.user_id = auth.uid() and t.purpose = p_purpose;
$$;
grant execute on function pg_temp.state(text), pg_temp.suggestion(text) to authenticated;

select is(pg_temp.state('Wurst Kaese'), 'groceries:learned', 'Sicherer Treffer automatisch (learned)');
select cmp_ok((select categorization_confidence from public.transactions where user_id = auth.uid() and purpose = 'Wurst Kaese'),
  '>=', 0.9::numeric, 'Sicherheit gespeichert (≥ Schwelle)');
select is(pg_temp.state('Tanken Diesel'), 'mobility:learned', 'Zweiter sicherer Treffer');
select is(pg_temp.state('Kabel Geschenk'), '-:-', 'Hoher Betrag (≥ 1.000) nie automatisch');
select is(pg_temp.suggestion('Kabel Geschenk'), 'shopping', '… sondern als Vorschlag in der Prüfliste');
select is(pg_temp.state('Brille Tickets'), '-:-', 'Unsicher (Wörter aus zwei Kategorien) → nicht automatisch');
select cmp_ok((select suggestion_confidence from public.transactions where user_id = auth.uid() and purpose = 'Brille Tickets'),
  '<', 0.9::numeric, 'Vorschlag mit geringer Sicherheit');
select is(pg_temp.suggestion('Xyzzy'), '-', 'Keine bekannten Wörter → kein Vorschlag');
select is(
  (select auto_source::text || '|' || (auto_confidence is not null)::text from public.transactions
    where user_id = auth.uid() and purpose = 'Wurst Kaese'),
  'learned|true', 'Erste automatische Zuordnung für die Treffsicherheit gemerkt'
);
select is((public.categorization_stats() ->> 'bayes')::int, 2, 'Kennzahlen: 2 vom Klassifikator');
select is((public.categorization_stats() ->> 'suggested')::int, 2, 'Kennzahlen: 2 Vorschläge');

-- Prüfgrenze und Schwelle sind einstellbar.
select throws_ok($$ select public.save_categorization_settings(0.3, 1000) $$, '22023', 'invalid_settings',
  'Schwelle unter 0,5 abgelehnt');
select lives_ok($$ select public.save_categorization_settings(0.9, 2000) $$, 'Prüfgrenze 2.000 gespeichert');
select is(public.apply_categorization_rules(), 1, 'Mit höherer Prüfgrenze: hoher Betrag jetzt automatisch');
select is(pg_temp.state('Kabel Geschenk'), 'shopping:learned', 'Hoher Betrag zugeordnet');

-- ---------------------------------------------------------------------
-- 4. Prüfliste bestätigen, kein Selbsttraining (28–33)
-- ---------------------------------------------------------------------
select is(
  public.confirm_suggestions(array(select id from public.transactions where user_id = auth.uid() and purpose = 'Brille Tickets')),
  1, 'Vorschlag bestätigt'
);
select matches(pg_temp.state('Brille Tickets'), '^(health|leisure_travel):manual$', 'Bestätigt = manuell (vorgeschlagene Kategorie)');
select is(
  (select suggested_category_id from public.transactions where user_id = auth.uid() and purpose = 'Brille Tickets'),
  null, 'Mit Kategorie kein Vorschlag mehr'
);
select is(private.bayes_build(auth.uid(), false), 181, 'Bestätigter Vorschlag trainiert mit (181)');
-- Gelernte Zuordnungen (auch absichtlich falsche) trainieren nicht.
update public.transactions set category_id = (select id from cat where key = 'housing')
 where user_id = auth.uid() and purpose = 'Wurst Kaese';
update public.transactions set categorization_source = 'learned'
 where user_id = auth.uid() and purpose = 'Wurst Kaese';
select is(private.bayes_build(auth.uid(), false), 181, 'learned-Zuordnungen sind kein Training');
select is(
  (select count(*)::int from pg_temp.bayes_train b join public.transactions t on t.id = b.id where t.purpose = 'Wurst Kaese'),
  0, 'Insbesondere nicht die gelernte Buchung'
);

-- ---------------------------------------------------------------------
-- 5. Andere Nutzer (34–36)
-- ---------------------------------------------------------------------
select tests.authenticate_as('b2_bob');
select is(private.bayes_build(auth.uid(), false), 0, 'Bob: kein Training aus Alices Daten');
select is(public.refresh_suggestions(), 0, 'Bob: keine Vorschläge');
select is(
  public.confirm_suggestions(array(select id from public.transactions where purpose = 'Xyzzy')), 0,
  'Bob kann Alices Vorschläge nicht übernehmen'
);

select * from finish();
rollback;
