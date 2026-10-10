-- =====================================================================
--  supabase/tests/categorization_a2.test.sql
--  PR A2: Korrektur auch auf automatisch zugeordnete Buchungen,
--  Standardregeln abgleichen, eigene Konten erkennen
--  (Migrationen 20261007120000, 20261007120100)
--  Ausführen: supabase test db   (setzt 00000-test-helpers.sql voraus)
-- =====================================================================

begin;

select plan(28);

select tests.create_supabase_user('a2_alice', 'a2-alice@example.test');
select tests.create_supabase_user('a2_bob',   'a2-bob@example.test');

select tests.authenticate_as_service_role();
insert into public.accounts (id, user_id, name, type, currency, provider) values
  ('3c000000-0000-4000-8000-000000000001', tests.get_supabase_uid('a2_alice'), 'Giro', 'checking', 'EUR', 'csv');

create temp table cat as
select
  (select id from public.categories where user_id = tests.get_supabase_uid('a2_alice') and default_key = 'housing')   as housing,
  (select id from public.categories where user_id = tests.get_supabase_uid('a2_alice') and default_key = 'mobility')  as mobility,
  (select id from public.categories where user_id = tests.get_supabase_uid('a2_alice') and default_key = 'transfer')  as transfer,
  (select id from public.categories where user_id = tests.get_supabase_uid('a2_alice') and default_key = 'insurance') as insurance;
grant select on cat to authenticated, service_role;

select tests.authenticate_as('a2_alice');
select public.load_standard_rules();

create function pg_temp.tx(p_purpose text) returns uuid language sql as $$
  select id from public.transactions where user_id = auth.uid() and purpose = p_purpose;
$$;
create function pg_temp.state(p_purpose text) returns text language sql as $$
  select coalesce(c.default_key, '-') || ':' || coalesce(t.categorization_source::text, '-')
    from public.transactions t left join public.categories c on c.id = t.category_id
   where t.user_id = auth.uid() and t.purpose = p_purpose;
$$;
grant execute on function pg_temp.tx(text), pg_temp.state(text) to authenticated;

-- ---------------------------------------------------------------------
-- 1. Korrektur auf automatisch zugeordnete übertragen
-- ---------------------------------------------------------------------
select public.import_transactions('3c000000-0000-4000-8000-000000000001', $j$[
  {"booking_date": "2026-09-01", "amount": -58, "counterparty": "Stadtwerke München GmbH", "purpose": "Abo 1 9876543"},
  {"booking_date": "2026-09-02", "amount": -58, "counterparty": "Stadtwerke München GmbH", "purpose": "Abo 2 9876543"},
  {"booking_date": "2026-09-03", "amount": -58, "counterparty": "Stadtwerke München GmbH", "purpose": "Abo 3 9876543"},
  {"booking_date": "2026-09-04", "amount": -58, "counterparty": "Stadtwerke München GmbH", "purpose": "Abo 4 9876543"}
]$j$::jsonb);
select is(pg_temp.state('Abo 2 9876543'), 'housing:rule', 'Standardregel „stadtwerke“ ordnet Wohnen zu');

-- Abo 4 hat die Nutzerin schon früher manuell als Wohnen bestätigt.
select public.set_transaction_category(pg_temp.tx('Abo 4 9876543'), (select housing from cat));

select is(
  public.set_transaction_category(pg_temp.tx('Abo 1 9876543'), (select mobility from cat)) - 'rule_id',
  '{"changed": true, "similar": 0, "similar_auto": 2, "learned_pattern": "stadtwerke muenchen gmbh"}'::jsonb,
  'Korrektur meldet 2 automatisch anders zugeordnete ähnliche Buchungen'
);
create temp table learned as
select id from public.categorization_rules where user_id = auth.uid() and pattern = 'stadtwerke muenchen gmbh';
grant select on learned to authenticated;

select is(public.apply_categorization_rules((select id from learned)), 0,
  'Ohne Überschreiben: nur Buchungen ohne Kategorie (keine)');
select is(pg_temp.state('Abo 2 9876543'), 'housing:rule', 'Automatische Zuordnung bleibt ohne Überschreiben');
select is(public.apply_categorization_rules((select id from learned), true, true), 2,
  'Vorschau mit Überschreiben: 2');
select is(public.apply_categorization_rules((select id from learned), false, true), 2,
  'Mit Überschreiben: 2 geändert');
select results_eq(
  $$ select pg_temp.state(p) from unnest(array['Abo 1 9876543', 'Abo 2 9876543', 'Abo 3 9876543', 'Abo 4 9876543']) p $$,
  $$ values ('mobility:manual'::text), ('mobility:rule'), ('mobility:rule'), ('housing:manual') $$,
  'Automatische überschrieben, manuelle (Abo 4) bleibt'
);
select is(
  (select r.origin from public.transactions t join public.categorization_rules r on r.id = t.categorization_rule_id
    where t.id = pg_temp.tx('Abo 2 9876543')),
  'learned', 'Regel-ID zeigt auf die gelernte Regel'
);
select is(public.apply_categorization_rules((select id from learned), false, true), 0,
  'Erneut: nichts mehr zu überschreiben');

-- ---------------------------------------------------------------------
-- 2. Standardregeln abgleichen
-- ---------------------------------------------------------------------
select is(
  (select count(*)::int from public.categorization_rules
    where user_id = auth.uid() and origin = 'standard' and pattern in ('uber', 'starbucks', 'miete', 'versicherung', 'gehalt')
      -- „Miete“ nur als Gutschrift im Verwendungszweck (Mieteinnahmen, 20261016100100)
      and not (pattern = 'miete' and match_field = 'purpose' and amount_min > 0 and amount_max is null)),
  0, 'Keine US-Händler und Allerweltsbegriffe im Regelset'
);
-- Altbestand simulieren: Regel aus dem früheren Regelset mit Zuordnung.
insert into public.categorization_rules (user_id, category_id, pattern, match_type, match_field, amount_max, priority, origin)
values (auth.uid(), (select insurance from cat), 'versicherung', 'contains', 'counterparty_or_purpose', -0.01, 100, 'standard');
select public.import_transactions('3c000000-0000-4000-8000-000000000001', $j$[
  {"booking_date": "2026-09-05", "amount": -30, "counterparty": "Hausrat", "purpose": "Versicherungsbeitrag"}
]$j$::jsonb);
select is(pg_temp.state('Versicherungsbeitrag'), 'insurance:rule', 'Alte Standardregel hat zugeordnet');
update public.categorization_rules set priority = 50
 where user_id = auth.uid() and origin = 'standard' and pattern = 'rewe';

select is(public.load_standard_rules(), '{"added": 0, "removed": 1, "reset": 1, "applied": 0, "bank_added": 0}'::jsonb,
  'Abgleich: veraltete Regel entfernt, ihre Zuordnung zurückgesetzt');
select is(pg_temp.state('Versicherungsbeitrag'), '-:-', 'Buchung ist wieder ohne Kategorie');
select is(
  (select priority::int from public.categorization_rules where user_id = auth.uid() and origin = 'standard' and pattern = 'rewe'),
  100, 'Priorität wird aus dem Regelset angeglichen'
);
select is(
  (select count(*)::int from public.categorization_rules where user_id = auth.uid() and pattern = 'stadtwerke muenchen gmbh'),
  1, 'Eigene (gelernte) Regeln bleiben beim Abgleich'
);
-- Person „Otto“ ist kein Versandhändler.
select is(
  (select count(*)::int from private.match_rule(auth.uid(), null, -20, 'Otto Meier', 'Danke fürs Essen')), 0,
  'Vorname „Otto“ trifft keine Shopping-Regel'
);

-- ---------------------------------------------------------------------
-- 3. Eigene Konten
-- ---------------------------------------------------------------------
select public.import_transactions('3c000000-0000-4000-8000-000000000001', $j$[
  {"booking_date": "2026-09-10", "amount": -500, "counterparty": "MUSTERMANN, DOMINIK MAXIMILIAN", "purpose": "Sparen"},
  {"booking_date": "2026-09-11", "amount": 200,  "counterparty": "Dominik Mustermann", "purpose": "Einkauf REWE zurück"},
  {"booking_date": "2026-09-12", "amount": -40,  "counterparty": "Dominik Otto", "purpose": "Konzertkarte"},
  {"booking_date": "2026-09-13", "amount": -300, "counterparty": "Tagesgeld", "purpose": "Übertrag",
   "counterparty_iban": "DE02120300000000202051"},
  {"booking_date": "2026-09-14", "amount": -25,  "counterparty": "Dominik Mustermann", "purpose": "Rewe Einkauf"}
]$j$::jsonb);
select is(pg_temp.state('Rewe Einkauf'), 'groceries:rule', 'Vorher: Standardregel „rewe“ (automatisch)');
select public.set_transaction_category(pg_temp.tx('Konzertkarte'), (select mobility from cat));

select throws_ok($$ select public.add_own_account_identifier('name', 'Dominik') $$,
  '22023', 'invalid_name', 'Nur Vorname → invalid_name');
select throws_ok($$ select public.add_own_account_identifier('iban', 'DE00 1') $$,
  '22023', 'invalid_iban', 'Ungültige IBAN → invalid_iban');
select throws_ok($$ select public.add_own_account_identifier('konto', 'x') $$,
  '22023', 'invalid_kind', 'Unbekannte Art → invalid_kind');

select is(public.add_own_account_identifier('name', 'Dominik Mustermann') - 'rule_id',
  '{"applied": 0, "suggested": 2}'::jsonb,
  'Name: nichts automatisch, 2 Buchungen ohne Kategorie als Vorschlag');
select results_eq(
  $$ select pg_temp.state(p) from unnest(array['Sparen', 'Einkauf REWE zurück', 'Rewe Einkauf', 'Konzertkarte']) p $$,
  $$ values ('-:-'::text), ('-:-'), ('groceries:rule'), ('mobility:manual') $$,
  'Namens-Treffer ordnen nicht zu (nur Vorschlag); bestehende Zuordnungen bleiben'
);
select is(
  (select match_type::text || '|' || match_field::text || '|' || origin from public.categorization_rules
    where user_id = auth.uid() and pattern = 'dominik mustermann'),
  'all_words|counterparty|own_account', 'Regel: alle Wörter im Empfänger, Herkunft own_account'
);
select is(public.add_own_account_identifier('iban', 'de02 1203 0000 0000 2020 51') ->> 'applied', '1',
  'IBAN: Buchung aufs eigene Tagesgeld als Umbuchung');
select is(pg_temp.state('Übertrag'), 'transfer:rule', 'IBAN-Regel greift');
select throws_ok($$ select public.add_own_account_identifier('name', 'dominik  MUSTERMANN') $$,
  '23505', 'rule_exists', 'Doppelter Name → rule_exists');
select lives_ok(
  $$ select public.reorder_categorization_rules(array(
       select id from public.categorization_rules where user_id = auth.uid() and origin in ('manual', 'learned'))) $$,
  'Umsortieren ohne eigene Konten und Standardregeln'
);

select tests.authenticate_as('a2_bob');
select is(
  (select count(*)::int from public.categorization_rules where origin = 'own_account'), 0,
  'Bob sieht Alices Regeln nicht'
);

select * from finish();
rollback;
