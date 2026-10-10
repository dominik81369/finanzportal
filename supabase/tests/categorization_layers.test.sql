-- =====================================================================
--  supabase/tests/categorization_layers.test.sql
--  Kategorisierung in Schichten: manuell > eigene Regeln > Standardregeln;
--  Felder Transaktionstyp/IBAN/Beschreibung, rückwirkend anwenden,
--  zurücksetzen, Kennzahlen, Kapitalertragsteuer
--  (Migrationen 20261007100000, 20261007100100)
--  Ausführen: supabase test db   (setzt 00000-test-helpers.sql voraus)
--
--  Identitäten
--    cl_alice – Nutzerin mit Standardkategorien
--    cl_bob   – anderer Nutzer
-- =====================================================================

begin;

select plan(56);

select tests.create_supabase_user('cl_alice', 'cl-alice@example.test');
select tests.create_supabase_user('cl_bob',   'cl-bob@example.test');

select tests.authenticate_as_service_role();
insert into public.accounts (id, user_id, name, type, currency, provider) values
  ('2c000000-0000-4000-8000-000000000001', tests.get_supabase_uid('cl_alice'), 'Giro',     'checking', 'EUR', 'manual'),
  ('2c000000-0000-4000-8000-000000000002', tests.get_supabase_uid('cl_bob'),   'Bob Giro', 'checking', 'EUR', 'manual');

create temp table cat as
select
  (select id from public.categories where user_id = tests.get_supabase_uid('cl_alice') and default_key = 'groceries')           as groceries,
  (select id from public.categories where user_id = tests.get_supabase_uid('cl_alice') and default_key = 'shopping')            as shopping,
  (select id from public.categories where user_id = tests.get_supabase_uid('cl_alice') and default_key = 'subscriptions_media') as subscriptions,
  (select id from public.categories where user_id = tests.get_supabase_uid('cl_alice') and default_key = 'investment_income')   as investment_income,
  (select id from public.categories where user_id = tests.get_supabase_uid('cl_alice') and default_key = 'capital_gains_tax')   as capital_gains_tax,
  (select id from public.categories where user_id = tests.get_supabase_uid('cl_alice') and default_key = 'housing')             as housing,
  (select id from public.categories where user_id = tests.get_supabase_uid('cl_alice') and default_key = 'rental_income')       as rental_income,
  (select id from public.categories where user_id = tests.get_supabase_uid('cl_alice') and default_key = 'leisure_travel')      as leisure;
grant select on cat to authenticated, service_role;

-- ---------------------------------------------------------------------
-- 1. Kategorie „Kapitalertragsteuer“ (1–3)
-- ---------------------------------------------------------------------
select results_eq(
  format($$ select name, kind::text, budget_group::text from public.categories
             where user_id = %L and default_key = 'capital_gains_tax' $$, tests.get_supabase_uid('cl_alice')),
  $$ values ('Kapitalertragsteuer'::text, 'expense'::text, 'needs'::text) $$,
  'Neue Nutzerin: Kapitalertragsteuer (Ausgabe, Needs)'
);
select is(
  (select name from public.categories where user_id = tests.get_supabase_uid('cl_alice') and default_key = 'investment_income'),
  'Kapitalerträge', 'Kapitalerträge als Einnahmekategorie vorhanden'
);
select col_is_fk('public', 'transactions', array['categorization_rule_id', 'user_id'], 'transactions.categorization_rule_id → Regel');

-- ---------------------------------------------------------------------
-- 2. Normalisierung, Zahlungsvermittler, Händlername (4–10)
-- ---------------------------------------------------------------------
select tests.authenticate_as('cl_alice');
select is(private.normalize_booking_text('Müller Straße ÄÖÜ'), 'mueller strasse aeoeue', 'Umlaute werden gefaltet');
select ok(private.is_payment_processor('PAYPAL (EUROPE) S.A R.L.'), 'PayPal ist Zahlungsvermittler');
select ok(not private.is_payment_processor('Paypalino Pizzeria'), 'Kein Vermittler bei Wortteil');
select is(
  private.extract_merchant('PP.1234.PP . SPOTIFY, Ihr Einkauf bei SPOTIFY AB', 'PayPal Europe S.a.r.l. et Cie S.C.A'),
  'spotify', 'PayPal: Händler aus dem Verwendungszweck, ohne Vermittlernamen'
);
select is(
  private.extract_merchant('1040123456789/PP.5678.PP/. Zalando SE, Ihr Einkauf bei Zalando SE', 'PAYPAL EUROPE'),
  'zalando', 'PayPal: Wiederholungen und Rechtsform entfallen'
);
select is(private.extract_merchant('Klarna Bestellung 12345 IKEA Deutschland', 'Klarna Bank AB'),
  'ikea deutschland', 'Klarna: Händler aus dem Verwendungszweck');
select is(private.extract_merchant('Ihr Einkauf', 'PayPal'), null, 'PayPal ohne erkennbaren Händler → NULL');

-- ---------------------------------------------------------------------
-- 3. Standardregeln laden (11–14)
-- ---------------------------------------------------------------------
select cmp_ok((public.load_standard_rules() ->> 'added')::int, '>', 150, 'Standardregeln geladen');
select is(public.load_standard_rules(), '{"added": 0, "removed": 0, "reset": 0, "applied": 0, "bank_added": 0}'::jsonb,
  'Erneutes Laden ist idempotent');
select is(
  (select count(*)::int from public.categorization_rules r
     join private.standard_rule_templates() t on t.pattern = r.pattern and t.match_field = r.match_field
    where r.user_id = auth.uid() and r.origin = 'standard' and r.priority = t.priority and r.match_type = 'word'),
  (select count(*)::int from public.categorization_rules where user_id = auth.uid() and origin = 'standard'),
  'Standardregeln: Herkunft standard, ganzes Wort, Priorität aus dem Regelset'
);
select is(
  (select count(*)::int from public.categorization_rules where user_id <> auth.uid()), 0,
  'Andere Nutzer sehen/erhalten keine Regeln'
);

-- ---------------------------------------------------------------------
-- 4. Abgleich: Felder, Wort, Richtung, Reihenfolge (15–25)
-- ---------------------------------------------------------------------
create temp table m (label text, amount numeric, counterparty text, purpose text,
                     description text, ttype text, iban text);
grant all on m to authenticated, service_role;
insert into m values
  ('rewe',      -42.50, 'REWE Markt GmbH', 'REWE SAGT DANKE 12345678', null, null, null),
  ('waldi',     -10,    'Waldi Hundesalon', 'Rechnung', null, null, null),
  ('aldi',      -12,    null, 'Kartenzahlung ALDI SÜD 1234', null, null, null),
  ('zins_typ',  12.34,  null, null, null, 'Zinszahlung', null),
  ('kest',      -3.10,  null, 'Steuerabrechnung Zinsgutschrift', null, null, null),
  ('mvg',       -58,    'Stadtwerke München GmbH', 'MVG Deutschlandticket Oktober', null, null, null),
  ('swm',       -80,    'Stadtwerke München GmbH', 'Abschlag Strom', null, null, null),
  ('prime',     -8.99,  'AMAZON EU', 'Amazon Prime Mitgliedschaft', null, null, null),
  ('desc',      -15.99, null, null, 'Netflix Monatsabo', null, null),
  ('nothing',   -5,     'Kiosk', 'Zeitung', null, null, null);

create function pg_temp.match_key(p_label text) returns text language sql as $$
  select c.default_key
    from m
    cross join lateral private.match_rule(auth.uid(), null, m.amount, m.counterparty, m.purpose,
                                          m.description, m.ttype, m.iban) r
    join public.categories c on c.id = r.category_id
   where m.label = p_label;
$$;
grant execute on function pg_temp.match_key(text) to authenticated;

select is(pg_temp.match_key('rewe'),      'groceries',           'REWE → Lebensmittel');
select is(pg_temp.match_key('waldi'),     null,                  'Wort-Treffer: „aldi“ trifft „Waldi“ nicht');
select is(pg_temp.match_key('aldi'),      'groceries',           'ALDI SÜD im Verwendungszweck → Lebensmittel');
select is(pg_temp.match_key('zins_typ'),  'investment_income',   'Transaktionstyp „Zinszahlung“ → Kapitalerträge');
select is(pg_temp.match_key('kest'),      'capital_gains_tax',   'Steuerabrechnung Zinsgutschrift (Abbuchung) → Kapitalertragsteuer');
select is(pg_temp.match_key('mvg'),       'mobility',            'MVG geht vor „Stadtwerke“ (Priorität 90 vor 110)');
select is(pg_temp.match_key('swm'),       'housing',             'Stadtwerke ohne Nahverkehrsbezug → Wohnen');
select is(pg_temp.match_key('prime'),     'subscriptions_media', 'Längeres Standardmuster gewinnt (amazon prime vor amazon)');
select is(pg_temp.match_key('desc'),      'subscriptions_media', 'Beschreibung wird durchsucht');
select is(pg_temp.match_key('nothing'),   null,                  'Kein Treffer → keine Kategorie');

-- Eigene Regel schlägt Standardregel (Schicht 2 vor 3), auch bei höherer Priorität.
create temp table own (name text, id uuid);
grant all on own to authenticated, service_role;
insert into own select 'rewe', public.create_categorization_rule('rewe', (select leisure from cat), 'counterparty_or_purpose', 'word');
update public.categorization_rules set priority = 1000 where id = (select id from own where name = 'rewe');
select is(pg_temp.match_key('rewe'), 'leisure_travel', 'Eigene Regel schlägt Standardregel');

-- ---------------------------------------------------------------------
-- 5. Eigene Regeln mit Feld, Typ, Richtung (26–31)
-- ---------------------------------------------------------------------
insert into own select 'iban', public.create_categorization_rule('de89 3704 0044 0532 0130 00', (select housing from cat),
  'counterparty_iban', 'equals', 'out');
select is((select pattern from public.categorization_rules where id = (select id from own where name = 'iban')),
  'DE89370400440532013000', 'IBAN-Muster: groß, ohne Leerzeichen');
select is(
  (select c.default_key from private.match_rule(auth.uid(), null, -700, 'Vermieter', 'Oktober', null, null,
     'DE89370400440532013000') r join public.categories c on c.id = r.category_id),
  'housing', 'Regel auf Gegenkonto-IBAN greift'
);
select is(
  (select count(*)::int from private.match_rule(auth.uid(), null, 700, 'Vermieter', 'Oktober', null, null,
     'DE89370400440532013000')), 0, 'Richtung „out“: Eingang trifft nicht'
);
select throws_ok(
  $$ select public.create_categorization_rule('x', (select housing from cat)) $$,
  '22023', 'invalid_pattern', 'Zu kurzes Muster → invalid_pattern'
);
select throws_ok(
  $$ select public.create_categorization_rule('kiosk', (select housing from cat), 'counterparty', 'contains', 'sideways') $$,
  '22023', 'invalid_direction', 'Unbekannte Richtung → invalid_direction'
);
select throws_ok(
  $$ select public.create_categorization_rule('DE89 3704 0044 0532 0130 00', (select housing from cat),
       'counterparty_iban', 'equals', 'out') $$,
  '23505', 'rule_exists', 'Gleiche Regel doppelt → rule_exists'
);

-- ---------------------------------------------------------------------
-- 6. Import: Typ, IBAN, Beschreibung, Regel-ID (32–35)
-- ---------------------------------------------------------------------
select is(
  public.import_transactions('2c000000-0000-4000-8000-000000000001', $j$[
    {"booking_date": "2026-10-01", "amount": 12.34, "transaction_type": "Zinszahlung", "purpose": "Tagesgeld"},
    {"booking_date": "2026-10-01", "amount": -700, "counterparty": "Vermieter", "purpose": "Oktober",
     "counterparty_iban": "DE89 3704 0044 0532 0130 00"},
    {"booking_date": "2026-10-02", "amount": -9, "counterparty": "Kiosk", "purpose": "Zeitung", "counterparty_iban": "12345"},
    {"booking_date": "2026-10-03", "amount": -20, "counterparty": "Spielhalle", "purpose": "Automat", "description": "Netflix Geschenkkarte"}
  ]$j$::jsonb) ->> 'categorized',
  '3', 'Import: 3 von 4 Zeilen per Regel kategorisiert'
);
select results_eq(
  $$ select t.transaction_type, t.counterparty_iban, t.description from public.transactions t
      where t.user_id = auth.uid() order by t.booking_date, t.amount $$,
  $$ values (null::text, 'DE89370400440532013000'::text, null::text), ('Zinszahlung', null, null),
            (null, null, null), (null, null, 'Netflix Geschenkkarte') $$,
  'Import speichert Typ, IBAN (ungültige verworfen) und Beschreibung'
);
select is(
  (select t.categorization_rule_id from public.transactions t where t.user_id = auth.uid() and t.amount = -700),
  (select id from own where name = 'iban'), 'Import speichert die Regel-ID („Warum diese Kategorie?“)'
);
select is(
  (select r.origin from public.transactions t join public.categorization_rules r on r.id = t.categorization_rule_id
    where t.user_id = auth.uid() and t.transaction_type = 'Zinszahlung'),
  'standard', 'Zinszahlung per Standardregel zugeordnet'
);

-- ---------------------------------------------------------------------
-- 7. Rückwirkend anwenden, manuell bleibt, zurücksetzen, Kennzahlen (36–46)
-- ---------------------------------------------------------------------
-- Ohne Regeln importierte Altbuchungen (Regeln vorübergehend deaktiviert).
update public.categorization_rules set is_active = false where user_id = auth.uid();
select public.import_transactions('2c000000-0000-4000-8000-000000000001', $j$[
  {"booking_date": "2026-09-01", "amount": -30, "counterparty": "EDEKA Center", "purpose": "Einkauf"},
  {"booking_date": "2026-09-02", "amount": -31, "counterparty": "EDEKA Center", "purpose": "Einkauf 2"},
  {"booking_date": "2026-09-03", "amount": -32, "counterparty": "Lidl", "purpose": "Einkauf"},
  {"booking_date": "2026-09-04", "amount": -33, "counterparty": "Bäckerei Lang", "purpose": "Brötchen"}
]$j$::jsonb);
update public.categorization_rules set is_active = true where user_id = auth.uid();

-- Lidl manuell als Shopping (Schicht 1).
select public.set_transaction_category(
  (select id from public.transactions where user_id = auth.uid() and amount = -32), (select shopping from cat));

select is(public.apply_categorization_rules(null, true), 2, 'Vorschau: 2 unkategorisierte Buchungen passen');
select is(public.apply_categorization_rules(), 2, 'Anwenden: 2 Buchungen zugeordnet');
select results_eq(
  $$ select c.default_key, t.categorization_source::text from public.transactions t
       join public.categories c on c.id = t.category_id
      where t.user_id = auth.uid() and t.booking_date between '2026-09-01' and '2026-09-03' order by t.booking_date $$,
  $$ values ('groceries'::text, 'rule'::text), ('groceries', 'rule'), ('shopping', 'manual') $$,
  'Regeln greifen nur bei unkategorisierten Buchungen; manuelle bleibt'
);
select is(public.apply_categorization_rules(), 0, 'Erneut anwenden: nichts mehr zu tun');

-- Bäckerei lernen → ähnliche zählen (nichts weiter offen).
select is(
  public.set_transaction_category((select id from public.transactions where user_id = auth.uid() and amount = -33),
                                  (select groceries from cat)) - 'rule_id',
  '{"changed": true, "similar": 0, "similar_auto": 0, "learned_pattern": "baeckerei lang"}'::jsonb,
  'Manuelle Zuordnung lernt Regel und meldet ähnliche Buchungen'
);

-- Bestätigung einer Regel-Zuordnung (gleiche Kategorie) → manuell.
select is(
  public.set_transaction_category((select id from public.transactions where user_id = auth.uid() and amount = -30),
                                  (select groceries from cat)) ->> 'changed',
  'false', 'Bestätigen ändert die Kategorie nicht'
);
select is(
  (select categorization_source::text || '/' || coalesce(categorization_rule_id::text, '-')
     from public.transactions where user_id = auth.uid() and amount = -30),
  'manual/-', 'Bestätigte Zuordnung gilt als manuell'
);

select is(
  public.categorization_stats(),
  '{"total": 8, "manual": 3, "rule": 1, "standard": 3, "learned": 0, "bayes": 0, "suggested": 0, "uncategorized": 1}'::jsonb,
  'Kennzahlen: manuell / eigene Regel / Standard / offen'
);

select is(public.reset_machine_categorization(), 4, 'Zurücksetzen: 4 maschinelle Zuordnungen entfernt');
select is(
  (select count(*)::int from public.transactions where user_id = auth.uid() and categorization_source = 'manual'), 3,
  'Manuelle Zuordnungen bleiben beim Zurücksetzen'
);

-- Reihenfolge: nur eigene Regeln, Standardregeln bleiben bei 100.
select lives_ok(
  $$ select public.reorder_categorization_rules(array(
       select id from public.categorization_rules
        where user_id = auth.uid() and origin in ('manual', 'learned') order by created_at desc)) $$,
  'Umsortieren betrifft nur eigene Regeln'
);
select is(
  (select count(*)::int from public.categorization_rules r
     join private.standard_rule_templates() t on t.pattern = r.pattern and t.match_field = r.match_field
    where r.user_id = auth.uid() and r.origin = 'standard' and r.priority <> t.priority), 0,
  'Standardregeln behalten ihre Priorität aus dem Regelset'
);

-- Regel löschen: Kategorie bleibt, Regel-ID wird geleert.
select public.apply_categorization_rules();
delete from public.categorization_rules where id = (select id from own where name = 'iban');
select is(
  (select (category_id is not null)::text || '/' || coalesce(categorization_rule_id::text, '-')
     from public.transactions where user_id = auth.uid() and amount = -700),
  'true/-', 'Gelöschte Regel: Kategorie bleibt, Regel-ID wird NULL'
);

-- ---------------------------------------------------------------------
-- 8. Erneuter Import ergänzt alte Buchungen (Import vor diesen Spalten)
-- ---------------------------------------------------------------------
create temp table c24 as select $j$[
  {"booking_date": "2026-08-01", "amount": 5.55, "counterparty": "C24 Bank", "purpose": "Tagesgeld August",
   "transaction_type": "Zinszahlung"},
  {"booking_date": "2026-08-02", "amount": -20, "counterparty": "Kiosk am Eck", "purpose": "Zeitschrift",
   "counterparty_iban": "DE02 1203 0000 0000 2020 51", "description": "Kartenzahlung Filiale"},
  {"booking_date": "2026-08-03", "amount": -7, "counterparty": "Kiosk am Eck", "purpose": "Getränke"}
]$j$::jsonb as rows;
grant select on c24 to authenticated, service_role;
-- So wie vor #21 gespeichert: ohne Typ, IBAN, Beschreibung, ohne Kategorie.
select public.import_transactions('2c000000-0000-4000-8000-000000000001',
  (select jsonb_agg(e - 'transaction_type' - 'counterparty_iban' - 'description') from jsonb_array_elements((select rows from c24)) e));
-- Eine davon hat der Nutzer schon manuell zugeordnet (Schicht 1).
select public.set_transaction_category(
  (select id from public.transactions where user_id = auth.uid() and purpose = 'Zeitschrift'), (select leisure from cat));

select is(
  public.import_transactions('2c000000-0000-4000-8000-000000000001', (select rows from c24), true)
    - 'account_id' - 'balance' - 'currency' - 'dry_run' - 'learned' - 'suggested',
  '{"total": 3, "new": 0, "duplicates": 3, "enriched": 2, "categorized": 1}'::jsonb,
  'Vorschau erneuter Import: 3 Duplikate, 2 werden ergänzt, 1 danach per Regel kategorisiert'
);
select is(
  (select count(*)::int from public.transactions where user_id = auth.uid() and purpose = 'Tagesgeld August'
     and transaction_type is not null), 0,
  'Vorschau schreibt nichts'
);
select is(
  public.import_transactions('2c000000-0000-4000-8000-000000000001', (select rows from c24)) ->> 'enriched',
  '2', 'Erneuter Import ergänzt 2 vorhandene Buchungen'
);
select results_eq(
  $$ select t.transaction_type, t.counterparty_iban, t.description, c.default_key, t.categorization_source::text
       from public.transactions t left join public.categories c on c.id = t.category_id
      where t.user_id = auth.uid() and t.booking_date between '2026-08-01' and '2026-08-03' order by t.booking_date $$,
  $$ values ('Zinszahlung'::text, null::text, null::text, 'investment_income'::text, 'rule'::text),
            (null, 'DE02120300000000202051', 'Kartenzahlung Filiale', 'leisure_travel', 'manual'),
            (null, null, null, null, null) $$,
  'Typ/IBAN/Beschreibung ergänzt; Zinszahlung jetzt per Standardregel; manuelle Kategorie bleibt'
);
select is(
  (select count(*)::int from public.transactions where user_id = auth.uid() and booking_date between '2026-08-01' and '2026-08-03'), 3,
  'Keine doppelten Buchungen'
);
select is(
  public.import_transactions('2c000000-0000-4000-8000-000000000001', (select rows from c24)) ->> 'enriched',
  '0', 'Dritter Import: nichts mehr zu ergänzen'
);
-- Vorhandene Werte werden nie überschrieben.
select public.import_transactions('2c000000-0000-4000-8000-000000000001', $j$[
  {"booking_date": "2026-08-01", "amount": 5.55, "counterparty": "C24 Bank", "purpose": "Tagesgeld August",
   "transaction_type": "Anderer Typ", "description": "neu"}
]$j$::jsonb);
select is(
  (select transaction_type || '|' || description from public.transactions where user_id = auth.uid() and purpose = 'Tagesgeld August'),
  'Zinszahlung|neu', 'Vorhandener Typ bleibt, nur leere Felder werden gefüllt'
);

-- Andere Nutzer: kein Zugriff.
select tests.authenticate_as('cl_bob');
select is(public.apply_categorization_rules(), 0, 'Bob: keine Regeln, keine fremden Buchungen');

select * from finish();
rollback;
