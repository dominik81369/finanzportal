-- =====================================================================
--  supabase/tests/categorization_b1.test.sql
--  PR B1: Gegenpartei-Schlüssel und -Gedächtnis, Gruppenansicht,
--  eigene Konten mit Zielkategorie, wiederkehrende Buchungen, Qualität
--  (Migrationen 20261008100000, 20261008100100)
--  Ausführen: supabase test db   (setzt 00000-test-helpers.sql voraus)
-- =====================================================================

begin;

select plan(46);

select tests.create_supabase_user('b1_alice', 'b1-alice@example.test');
select tests.create_supabase_user('b1_bob',   'b1-bob@example.test');

select tests.authenticate_as_service_role();
insert into public.accounts (id, user_id, name, type, currency, provider) values
  ('4c000000-0000-4000-8000-000000000001', tests.get_supabase_uid('b1_alice'), 'Giro', 'checking', 'EUR', 'csv');

create temp table cat as
select
  (select id from public.categories where user_id = tests.get_supabase_uid('b1_alice') and default_key = 'groceries')           as groceries,
  (select id from public.categories where user_id = tests.get_supabase_uid('b1_alice') and default_key = 'leisure_travel')      as leisure,
  (select id from public.categories where user_id = tests.get_supabase_uid('b1_alice') and default_key = 'savings_investments') as savings,
  (select id from public.categories where user_id = tests.get_supabase_uid('b1_alice') and default_key = 'transfer')            as transfer,
  (select id from public.categories where user_id = tests.get_supabase_uid('b1_alice') and default_key = 'housing')             as housing,
  (select id from public.categories where user_id = tests.get_supabase_uid('b1_alice') and default_key = 'shopping')            as shopping;
grant select on cat to authenticated, service_role;

select tests.authenticate_as('b1_alice');
select public.load_standard_rules();

create function pg_temp.imp(p_rows jsonb) returns jsonb language sql as $$
  select public.import_transactions('4c000000-0000-4000-8000-000000000001', p_rows);
$$;
create function pg_temp.tx(p_purpose text) returns uuid language sql as $$
  select id from public.transactions where user_id = auth.uid() and purpose = p_purpose;
$$;
create function pg_temp.state(p_purpose text) returns text language sql as $$
  select coalesce(c.default_key, '-') || ':' || coalesce(t.categorization_source::text, '-')
    from public.transactions t left join public.categories c on c.id = t.category_id
   where t.user_id = auth.uid() and t.purpose = p_purpose;
$$;
grant execute on function pg_temp.imp(jsonb), pg_temp.tx(text), pg_temp.state(text) to authenticated;

-- ---------------------------------------------------------------------
-- 1. Gegenpartei-Schlüssel
-- ---------------------------------------------------------------------
select is(private.counterparty_name_key('MUSTERMANN, DOMINIK'), 'dominik mustermann', 'Name: Reihenfolge egal');
select is(private.counterparty_name_key('Dominik Mustermann'), 'dominik mustermann', 'Name: gleiche Schreibweise → gleicher Schlüssel');
select is(private.counterparty_name_key('Stadtwerke München GmbH'), 'muenchen stadtwerke', 'Name: ohne Rechtsform, Umlaut gefaltet');
select is(private.counterparty_name_key('Herr Dr. Max Muster'), 'max muster', 'Name: ohne Anrede und Titel');
select is(private.counterparty_key('de02 1203 0000 0000 2020 51', 'Egal', null),
  'i:' || md5('DE02120300000000202051'), 'IBAN vor Name, nur als Hash');
select is(private.counterparty_key(null, 'PayPal Europe S.a.r.l. et Cie S.C.A', 'PP.1234.PP . Zalando SE, Ihr Einkauf bei Zalando SE'),
  'm:zalando', 'PayPal: Händler aus dem Verwendungszweck ist der Schlüssel');
select is(private.counterparty_key(null, 'secupay AG', 'Bestellung 4711 Bergfreunde'),
  'm:bergfreunde', 'secupay ist Zahlungsvermittler');
select is(private.counterparty_key(null, 'Mangopay SA', 'Ihr Einkauf'), null, 'Vermittler ohne Händler → kein Schlüssel');
select is(private.counterparty_key(null, null, 'Kartenzahlung ALDI SÜD 1234'), 'm:aldi sued', 'Ohne Empfänger: Händler aus dem Zweck');

select pg_temp.imp($j$[{"booking_date": "2026-08-01", "amount": -1, "counterparty": "Herr Dr. Max Muster", "purpose": "Schlüsseltest"}]$j$);
select is((select counterparty_key from public.transactions where id = pg_temp.tx('Schlüsseltest')), 'n:max muster',
  'Trigger setzt den Schlüssel beim Einfügen');

-- ---------------------------------------------------------------------
-- 2. Gedächtnis
-- ---------------------------------------------------------------------
select pg_temp.imp($j$[
  {"booking_date": "2026-08-02", "amount": -300, "counterparty": "Depot", "purpose": "Sparplan Aug", "counterparty_iban": "DE02120300000000202051"},
  {"booking_date": "2026-08-03", "amount": -20, "counterparty": "Lisa Lang", "purpose": "Kino Aug"},
  {"booking_date": "2026-08-04", "amount": -25, "counterparty": "Lisa Lang", "purpose": "Kino Sep"},
  {"booking_date": "2026-08-05", "amount": -10, "counterparty": "Tom Tal", "purpose": "Tom 1"},
  {"booking_date": "2026-08-06", "amount": -11, "counterparty": "Tom Tal", "purpose": "Tom 2"},
  {"booking_date": "2026-08-07", "amount": -42, "counterparty": "REWE Markt", "purpose": "Wein"},
  {"booking_date": "2026-08-08", "amount": -43, "counterparty": "REWE Markt", "purpose": "Sekt"}
]$j$::jsonb);
select is(pg_temp.state('Wein'), 'groceries:rule', 'Vorher: Standardregel „rewe“');

select public.set_transaction_category(pg_temp.tx('Sparplan Aug'), (select savings from cat));
select public.set_transaction_category(pg_temp.tx('Kino Aug'), (select leisure from cat));
select public.set_transaction_category(pg_temp.tx('Tom 1'), (select leisure from cat));
select public.set_transaction_category(pg_temp.tx('Tom 2'), (select shopping from cat));
select public.set_transaction_category(pg_temp.tx('Wein'), (select leisure from cat));
select public.set_transaction_category(pg_temp.tx('Sekt'), (select leisure from cat));
-- Gelernte Händlerregeln aus den Korrekturen beiseite, damit nur das
-- Gedächtnis wirkt.
delete from public.categorization_rules where user_id = auth.uid() and origin = 'learned';

select pg_temp.imp($j$[
  {"booking_date": "2026-09-02", "amount": -300, "counterparty": "Depot GmbH", "purpose": "Sparplan Sep", "counterparty_iban": "DE02 1203 0000 0000 2020 51"},
  {"booking_date": "2026-09-03", "amount": -22, "counterparty": "LANG, LISA", "purpose": "Kino Okt"},
  {"booking_date": "2026-09-05", "amount": -12, "counterparty": "Tom Tal", "purpose": "Tom 3"},
  {"booking_date": "2026-09-07", "amount": -44, "counterparty": "REWE Markt", "purpose": "Bier"}
]$j$::jsonb);
select is(pg_temp.state('Sparplan Sep'), 'savings_investments:learned', 'IBAN: 1 manuelle Zuordnung genügt');
select is(pg_temp.state('Kino Okt'), '-:-', 'Name: 1 manuelle Zuordnung genügt nicht');
select is(pg_temp.state('Tom 3'), '-:-', 'Uneindeutige Gegenpartei (2 Kategorien) → keine Zuordnung');
select is(pg_temp.state('Bier'), 'leisure_travel:learned', 'Name ab 2 gleichen Zuordnungen; Gedächtnis vor Standardregel');

select public.set_transaction_category(pg_temp.tx('Kino Sep'), (select leisure from cat));
select is(public.apply_categorization_rules(), 1, 'Nach 2. Zuordnung: Gedächtnis ordnet „Kino Okt“ zu');
select is(pg_temp.state('Kino Okt'), 'leisure_travel:learned', 'Namensvariante „LANG, LISA“ = „Lisa Lang“');

-- Kein Selbsttraining: gelernte Zuordnungen zählen nicht fürs Gedächtnis.
select is((select manual_count from private.memory_lookup(auth.uid(), 'n:lang lisa')), 2,
  'Gedächtnis zählt nur manuelle Zuordnungen');

-- Eigene Regel geht vor Gedächtnis.
select public.create_categorization_rule('rewe markt', (select groceries from cat), 'counterparty', 'word');
select pg_temp.imp($j$[{"booking_date": "2026-09-08", "amount": -45, "counterparty": "REWE Markt", "purpose": "Brot"}]$j$);
select is(pg_temp.state('Brot'), 'groceries:rule', 'Eigene Regel schlägt Gedächtnis');

-- ---------------------------------------------------------------------
-- 3. Gruppenansicht
-- ---------------------------------------------------------------------
select pg_temp.imp($j$[
  {"booking_date": "2026-09-10", "amount": -50, "counterparty": "Fitness Studio Nord", "purpose": "Beitrag 1"},
  {"booking_date": "2026-09-11", "amount": -50, "counterparty": "Fitness Studio Nord", "purpose": "Beitrag 2"},
  {"booking_date": "2026-09-12", "amount": -50, "counterparty": "FITNESS STUDIO NORD GMBH", "purpose": "Beitrag 3"},
  {"booking_date": "2026-09-13", "amount": -100, "counterparty": "DOMINIK MAXIMILIAN", "purpose": "Umbuchung A"},
  {"booking_date": "2026-09-14", "amount": -80, "counterparty": "Dominik", "purpose": "Umbuchung B"}
]$j$::jsonb);
select public.set_transaction_category(pg_temp.tx('Umbuchung A'), (select savings from cat));

select is(
  (select group_key || '|' || tx_count || '|' || total from public.uncategorized_groups() limit 1),
  'n:fitness nord studio|3|-150.00', 'Größte Gruppe zuerst (Rechtsform zusammengeführt)'
);
select is(
  (select suggestion_source || '|' || suggestion_detail from public.uncategorized_groups() where group_key = 'n:lang lisa'),
  null, 'Zugeordnete Gruppe erscheint nicht mehr'
);
select is(
  (select suggestion_source || '|' || (suggestion_category_id = (select savings from cat))::text
     from public.uncategorized_groups() where group_key = 'n:dominik'),
  'variant|true', 'Namensvariante „Dominik“ ↔ „DOMINIK MAXIMILIAN“ nur als Vorschlag'
);
select is(pg_temp.state('Umbuchung B'), '-:-', 'Variante wird nicht automatisch zugeordnet');
select is(
  (select suggestion_source from public.uncategorized_groups() where group_key = 'n:tal tom'),
  null, 'Uneindeutiges Gedächtnis → kein Vorschlag'
);

select throws_ok($$ select public.categorize_group('n:fitness nord studio', gen_random_uuid()) $$,
  'P0002', 'category_not_found', 'Fremde/unbekannte Kategorie → category_not_found');
select is(public.categorize_group('n:fitness nord studio', (select leisure from cat)), 3, 'Ganze Gruppe zugeordnet');
select is(
  (select string_agg(distinct categorization_source::text, ',') from public.transactions
    where user_id = auth.uid() and counterparty_key = 'n:fitness nord studio'),
  'manual', 'Gruppenzuordnung ist manuell'
);
select pg_temp.imp($j$[{"booking_date": "2026-10-10", "amount": -50, "counterparty": "Fitness Studio Nord", "purpose": "Beitrag 4"}]$j$);
select is(pg_temp.state('Beitrag 4'), 'leisure_travel:learned', 'Gruppenzuordnung füttert das Gedächtnis');

-- ---------------------------------------------------------------------
-- 4. Eigene Konten: Zielkategorie je IBAN, Namen nur Vorschlag
-- ---------------------------------------------------------------------
select pg_temp.imp($j$[
  {"booking_date": "2026-09-20", "amount": -200, "counterparty": "Tagesgeld", "purpose": "TG 1", "counterparty_iban": "DE89370400440532013000"},
  {"booking_date": "2026-09-21", "amount": -70, "counterparty": "Erika Beispiel", "purpose": "Eigenes Konto Name"}
]$j$::jsonb);
select is(
  public.add_own_account_identifier('iban', 'DE89 3704 0044 0532 0130 00', (select savings from cat)) - 'rule_id',
  '{"applied": 1, "suggested": 0}'::jsonb, 'IBAN mit Zielkategorie Sparen sofort angewendet'
);
select is(pg_temp.state('TG 1'), 'savings_investments:rule', 'Eigenes Konto → Sparen & Investieren');
select is(
  public.set_own_account_category(
    (select id from public.categorization_rules where user_id = auth.uid() and pattern = 'DE89370400440532013000'),
    (select transfer from cat)),
  1, 'Zielkategorie geändert und neu angewendet'
);
select is(pg_temp.state('TG 1'), 'transfer:rule', 'Jetzt Umbuchung');
select is(public.add_own_account_identifier('name', 'Erika Beispiel') - 'rule_id',
  '{"applied": 0, "suggested": 1}'::jsonb, 'Name: nur Vorschlag');
select is(
  (select suggestion_source from public.uncategorized_groups() where group_key = 'n:beispiel erika'),
  'own_name', 'Gruppenansicht schlägt eigenes Konto vor'
);
select is(pg_temp.state('Eigenes Konto Name'), '-:-', 'Name ordnet nicht automatisch zu');

-- ---------------------------------------------------------------------
-- 5. Wiederkehrende Buchungen
-- ---------------------------------------------------------------------
select pg_temp.imp($j$[
  {"booking_date": "2026-05-01", "amount": -49.90, "counterparty": "Handyvertrag Ost", "purpose": "Rech 5"},
  {"booking_date": "2026-06-01", "amount": -49.90, "counterparty": "Handyvertrag Ost", "purpose": "Rech 6"},
  {"booking_date": "2026-07-02", "amount": -52.10, "counterparty": "Handyvertrag Ost", "purpose": "Rech 7"},
  {"booking_date": "2026-08-01", "amount": -49.90, "counterparty": "Handyvertrag Ost", "purpose": "Rech 8"},
  {"booking_date": "2026-08-15", "amount": -199.00, "counterparty": "Handyvertrag Ost", "purpose": "Neues Handy"},
  {"booking_date": "2026-05-03", "amount": -5, "counterparty": "Bäcker Zufall", "purpose": "Z1"},
  {"booking_date": "2026-05-05", "amount": -5, "counterparty": "Bäcker Zufall", "purpose": "Z2"},
  {"booking_date": "2026-07-20", "amount": -5, "counterparty": "Bäcker Zufall", "purpose": "Z3"}
]$j$::jsonb);
select results_eq(
  $$ select coalesce(recurrence, '-') from public.transactions
      where user_id = auth.uid() and purpose in ('Rech 5', 'Rech 7', 'Neues Handy', 'Z1') order by booking_date $$,
  $$ values ('monthly'::text), ('-'), ('monthly'), ('-') $$,
  'Monatlich erkannt (Betrag ±10 %), Einmalbetrag und unregelmäßige Buchungen nicht'
);
select is(
  (select recurrence from public.uncategorized_groups() where group_key = 'n:handyvertrag ost'),
  'monthly', 'Gruppenansicht zeigt den Rhythmus'
);

-- ---------------------------------------------------------------------
-- 6. Qualität
-- ---------------------------------------------------------------------
select public.load_standard_rules();
select pg_temp.imp($j$[
  {"booking_date": "2026-10-01", "amount": -1, "counterparty": "Aral 1", "purpose": "q1"},
  {"booking_date": "2026-10-02", "amount": -2, "counterparty": "Aral 2", "purpose": "q2"},
  {"booking_date": "2026-10-03", "amount": -3, "counterparty": "Aral 3", "purpose": "q3"},
  {"booking_date": "2026-10-04", "amount": -4, "counterparty": "Aral 4", "purpose": "q4"},
  {"booking_date": "2026-10-05", "amount": -5, "counterparty": "Aral 5", "purpose": "q5"}
]$j$::jsonb);
select is(pg_temp.state('q1'), 'mobility:rule', 'Standardregel „aral“');
select public.set_transaction_category(pg_temp.tx('q1'), (select groceries from cat));
select public.set_transaction_category(pg_temp.tx('q2'), (select groceries from cat));
select public.set_transaction_category(pg_temp.tx('q3'), (select housing from cat));
select public.set_transaction_category(pg_temp.tx('q4'), (select groceries from cat));  -- wieder groceries
select public.set_transaction_category(pg_temp.tx('q5'), (select groceries from cat));
select public.set_transaction_category(pg_temp.tx('q5'), (select groceries from cat));
select public.set_transaction_category(pg_temp.tx('q4'), (select groceries from cat));
select public.set_transaction_category(pg_temp.tx('q4'), (select groceries from cat));
-- q5: zurück auf die automatische Kategorie = keine Korrektur
select public.set_transaction_category(pg_temp.tx('q5'),
  (select id from public.categories where user_id = auth.uid() and default_key = 'mobility'));

select is(
  (select hits || '/' || corrected || '/' || flagged from public.rule_quality()
    where pattern = 'aral'),
  '5/4/true', 'Regel „aral“: 5 Treffer, 4 korrigiert → zur Prüfung'
);
select is(
  (select hits || '/' || corrected from public.rule_quality() where origin = 'memory'),
  '4/0', 'Gedächtnis als eigene Zeile: 4 Treffer, keine Korrektur'
);
select ok(
  (public.categorization_quality() ->> 'automated')::int > 0
  and (public.categorization_quality() ->> 'accuracy')::numeric < 1,
  'Kennzahlen: Automatisierungsquote und Treffsicherheit'
);
select lives_ok(
  $$ select public.set_rule_active((select rule_id from public.rule_quality() where pattern = 'aral'), false) $$,
  'Regel deaktivieren'
);
select is(
  (select is_active from public.categorization_rules where user_id = auth.uid() and origin = 'standard' and pattern = 'aral'),
  false, 'Regel ist deaktiviert'
);

select public.reset_machine_categorization();
select is(
  (select count(*)::int from public.transactions where user_id = auth.uid()
     and auto_category_id is not null and categorization_source is distinct from 'manual'),
  0, 'Zurücksetzen entfernt automatische Zuordnungen samt Herkunft'
);

-- ---------------------------------------------------------------------
-- 7. Andere Nutzer
-- ---------------------------------------------------------------------
select tests.authenticate_as('b1_bob');
select is((select count(*)::int from public.uncategorized_groups()), 0, 'Bob sieht keine fremden Gruppen');
select throws_ok(
  $$ select public.categorize_group('n:handyvertrag ost', (select leisure from cat)) $$,
  'P0002', 'category_not_found', 'Bob kann Alices Kategorie nicht nutzen'
);

select * from finish();
rollback;
