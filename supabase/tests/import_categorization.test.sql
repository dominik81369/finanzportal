-- =====================================================================
--  supabase/tests/import_categorization.test.sql
--  CSV-Import, Duplikate, Regeln, Lernen aus Korrekturen
--  (Migration 20261002170000)
--  Ausführen: supabase test db   (setzt 00000-test-helpers.sql voraus)
--
--  Identitäten
--    ic_alice – Nutzerin mit Standardkategorien
--    ic_bob   – anderer Nutzer
--    ic_carol – Beraterin von Alice (aktiv, nur lesend)
-- =====================================================================

begin;

select plan(45);

select tests.create_supabase_user('ic_alice', 'ic-alice@example.test');
select tests.create_supabase_user('ic_bob',   'ic-bob@example.test');
select tests.create_supabase_user('ic_carol', 'ic-carol@example.test');

select tests.authenticate_as_service_role();
update public.profiles set role = 'advisor' where user_id = tests.get_supabase_uid('ic_carol');
insert into public.advisor_clients (advisor_id, user_id, status, invited_email, accepted_at) values
  (tests.get_supabase_uid('ic_carol'), tests.get_supabase_uid('ic_alice'), 'active', 'ic-alice@example.test', now());
insert into public.accounts (id, user_id, name, type, currency, provider, provider_account_id) values
  ('1c000000-0000-4000-8000-000000000001', tests.get_supabase_uid('ic_alice'), 'Giro',      'checking', 'EUR', 'manual',     null),
  ('1c000000-0000-4000-8000-000000000002', tests.get_supabase_uid('ic_alice'), 'Bank sync', 'checking', 'EUR', 'gocardless', 'ext-ic'),
  ('1c000000-0000-4000-8000-000000000003', tests.get_supabase_uid('ic_bob'),   'Bob Giro',  'checking', 'EUR', 'manual',     null);

create temp table cat as
select
  (select id from public.categories where user_id = tests.get_supabase_uid('ic_alice') and default_key = 'groceries')           as groceries,
  (select id from public.categories where user_id = tests.get_supabase_uid('ic_alice') and default_key = 'shopping')            as shopping,
  (select id from public.categories where user_id = tests.get_supabase_uid('ic_alice') and default_key = 'subscriptions_media') as subscriptions,
  (select id from public.categories where user_id = tests.get_supabase_uid('ic_alice') and default_key = 'education')           as education,
  (select id from public.categories where user_id = tests.get_supabase_uid('ic_bob')   and default_key = 'shopping')            as bob_shopping;
grant select on cat to authenticated, service_role;

-- ---------------------------------------------------------------------
-- 1. Normalisierung und Händlername (1–5)
-- ---------------------------------------------------------------------
select tests.authenticate_as('ic_alice');
select is(private.normalize_booking_text('  REWE   Markt 12345678 Karte 1234 '), 'rewe markt karte',
  'Normalisierung: klein, Zahlen ab 4 Ziffern entfernt, Leerraum zusammengefasst');
select is(private.extract_merchant('REWE SAGT DANKE 12345678 Karte 1234', null), 'rewe sagt danke',
  'Händlername: Text vor der ersten längeren Zahlenfolge');
select is(private.extract_merchant('SEPA-Lastschrift AMAZON PRIME*AB12 Amzn.com/bill', null), 'amazon prime',
  'Händlername: ohne Buchungsart-Präfix, endet vor dem Code mit Ziffern');
select is(private.extract_merchant('123456789', 'Stadtwerke München GmbH'), 'stadtwerke muenchen gmbh',
  'Händlername: Fallback auf den Empfänger');
select is(private.extract_merchant('1234 5678', null), null, 'Händlername: nichts Brauchbares → NULL');

-- ---------------------------------------------------------------------
-- 2. Regeln anlegen, Spezifität, Reihenfolge (6–15)
-- ---------------------------------------------------------------------

create temp table rule_ids (name text, id uuid);
grant all on rule_ids to authenticated, service_role;
insert into rule_ids select 'amazon', public.create_categorization_rule('Amazon', (select shopping from cat));
insert into rule_ids select 'prime',  public.create_categorization_rule('  AMAZON   Prime ', (select subscriptions from cat));

select results_eq(
  $$ select pattern, priority::int, origin from public.categorization_rules order by priority, char_length(pattern) desc $$,
  $$ values ('amazon prime'::text, 1, 'manual'::text), ('amazon', 1, 'manual') $$,
  'Muster normalisiert gespeichert; spezifischere Regel erhält die Priorität der allgemeineren'
);
select is(
  private.match_category_rule(tests.get_supabase_uid('ic_alice'), null, -8.99, null, 'AMAZON PRIME*XY34 Amzn.com'),
  (select subscriptions from cat),
  '„Amazon Prime“ wird vor „Amazon“ geprüft'
);
select is(
  private.match_category_rule(tests.get_supabase_uid('ic_alice'), null, -20, 'AMAZON EU S.A.R.L.', 'Bestellung 3028111234567'),
  (select shopping from cat),
  'Allgemeine Regel greift für andere Amazon-Buchungen (Treffer im Empfänger)'
);
select is(
  private.match_category_rule(tests.get_supabase_uid('ic_alice'), null, -5, null, 'Bäckerei Schmidt'),
  null,
  'Ohne Treffer bleibt die Buchung unkategorisiert'
);
select throws_ok(
  $$ select public.create_categorization_rule('12345678', (select shopping from cat)) $$,
  '22023', 'invalid_pattern', 'Muster nur aus Ziffern → invalid_pattern'
);
select throws_ok(
  $$ select public.create_categorization_rule('amazon', (select shopping from cat)) $$,
  '23505', 'rule_exists', 'Gleiches Muster doppelt → rule_exists'
);
select throws_ok(
  $$ select public.create_categorization_rule('ikea', (select bob_shopping from cat)) $$,
  'P0002', 'category_not_found', 'Fremde Kategorie → category_not_found'
);

-- Nutzer stellt „Amazon“ bewusst vor „Amazon Prime“.
select lives_ok(
  $$ select public.reorder_categorization_rules(array[
       (select id from rule_ids where name = 'amazon'), (select id from rule_ids where name = 'prime')]) $$,
  'Reihenfolge anpassen'
);
select is(
  private.match_category_rule(tests.get_supabase_uid('ic_alice'), null, -8.99, null, 'AMAZON PRIME*XY34'),
  (select shopping from cat),
  'Nach Umsortieren gewinnt die vom Nutzer vorgezogene Regel'
);
select throws_ok(
  $$ select public.reorder_categorization_rules(array[(select id from rule_ids where name = 'amazon')]) $$,
  '22023', 'invalid_order', 'Unvollständige Reihenfolge → invalid_order'
);
-- Zurück zur Spezifitätsreihenfolge für die weiteren Tests.
select public.reorder_categorization_rules(array[
  (select id from rule_ids where name = 'prime'), (select id from rule_ids where name = 'amazon')]);

-- ---------------------------------------------------------------------
-- 3. Import: Vorschau, Import, Duplikate (16–26)
-- ---------------------------------------------------------------------
create temp table batch as select $j$[
  {"booking_date": "2026-09-01", "value_date": "2026-09-01", "amount": -8.99,  "counterparty": "AMAZON EU", "purpose": "AMAZON PRIME*AB12 Amzn.com/bill"},
  {"booking_date": "2026-09-02", "amount": -42.50, "counterparty": "REWE Markt GmbH", "purpose": "REWE SAGT DANKE 12345678 Karte 1234"},
  {"booking_date": "2026-09-03", "amount": 3000,   "counterparty": "Arbeitgeber AG", "purpose": "Gehalt September"},
  {"booking_date": "2026-09-04", "amount": -3.20,  "counterparty": "Café", "purpose": "Kaffee"},
  {"booking_date": "2026-09-04", "amount": -3.20,  "counterparty": "Café", "purpose": "  KAFFEE "}
]$j$::jsonb as rows;
grant select on batch to authenticated, service_role;

select is(
  public.import_transactions('1c000000-0000-4000-8000-000000000001', (select rows from batch), true)
    - 'account_id' - 'balance',
  '{"currency": "EUR", "total": 5, "new": 5, "enriched": 0, "duplicates": 0, "categorized": 1, "dry_run": true}'::jsonb,
  'Vorschau (dry run): 5 neu, 1 per Regel kategorisiert'
);
select is((select count(*)::int from public.transactions), 0, 'Vorschau schreibt nichts');

select is(
  public.import_transactions('1c000000-0000-4000-8000-000000000001', (select rows from batch))
    - 'account_id' - 'dry_run',
  '{"currency": "EUR", "total": 5, "new": 5, "enriched": 0, "duplicates": 0, "categorized": 1, "balance": 2942.11}'::jsonb,
  'Import: 5 Buchungen, Saldo 2.942,11 (Kontostand-Trigger)'
);
select results_eq(
  $$ select counterparty_name, source::text, categorization_source::text, category_id
       from public.transactions order by booking_date, created_at, id limit 2 $$,
  $$ values ('AMAZON EU'::text, 'csv_import'::text, 'rule'::text, (select subscriptions from cat)),
            ('REWE Markt GmbH', 'csv_import', null, null::uuid) $$,
  'Quelle csv_import; Regel-Treffer mit categorization_source = rule, sonst unkategorisiert'
);
select is(
  (select count(distinct import_hash)::int from public.transactions where purpose ilike '%kaffee%'),
  2,
  'Zwei gleiche Kaffee-Buchungen in einer Datei bleiben zwei Buchungen (laufende Nummer im Hash)'
);
select is(
  public.import_transactions('1c000000-0000-4000-8000-000000000001', (select rows from batch)) ->> 'duplicates',
  '5',
  'Dieselbe Datei erneut: alle 5 als Duplikat erkannt'
);
select is((select count(*)::int from public.transactions), 5, 'Keine doppelten Buchungen');
select is(
  public.import_transactions('1c000000-0000-4000-8000-000000000001',
    '[{"booking_date": "2026-09-02", "amount": "-42.50", "purpose": "rewe sagt danke 12345678 karte 1234"},
      {"booking_date": "2026-09-05", "amount": "-1.00", "purpose": "Neu"}]'::jsonb) - 'account_id' - 'balance' - 'dry_run',
  '{"currency": "EUR", "total": 2, "new": 1, "enriched": 0, "duplicates": 1, "categorized": 0}'::jsonb,
  'Überlappende Datei: Groß-/Kleinschreibung im Zweck ändert den Hash nicht, nur die neue Zeile kommt dazu'
);
select throws_ok(
  $$ select public.import_transactions('1c000000-0000-4000-8000-000000000001',
       '[{"booking_date": "2026-09-06", "amount": -1}, {"booking_date": "2026-02-30", "amount": -1}]'::jsonb) $$,
  '22023', 'invalid_row', 'Ungültiges Datum → invalid_row'
);
select is((select count(*)::int from public.transactions where booking_date = '2026-09-06'), 0,
  'Fehlerhafte Datei wird gar nicht importiert (alles oder nichts)');
select throws_ok(
  $$ select public.import_transactions('1c000000-0000-4000-8000-000000000001',
       '[{"booking_date": "2026-09-06", "amount": -1.005}]'::jsonb) $$,
  '22023', 'invalid_row', 'Mehr als zwei Nachkommastellen → invalid_row'
);

-- ---------------------------------------------------------------------
-- 4. Konten (27–32)
-- ---------------------------------------------------------------------
select throws_ok(
  $$ select public.import_transactions('1c000000-0000-4000-8000-000000000002', (select rows from batch)) $$,
  '22023', 'account_not_importable', 'Synchronisiertes Konto → account_not_importable'
);
select throws_ok(
  $$ select public.import_transactions('1c000000-0000-4000-8000-000000000003', (select rows from batch)) $$,
  'P0002', 'account_not_found', 'Fremdes Konto → account_not_found'
);
select throws_ok(
  $$ select public.import_transactions('1c000000-0000-4000-8000-000000000001',
       (select jsonb_agg(jsonb_build_object('booking_date', '2026-09-01', 'amount', -1)) from generate_series(1, 5001))) $$,
  '22023', 'too_many_rows', 'Mehr als 5000 Zeilen → too_many_rows'
);
select is(
  (public.import_transactions(null, (select rows from batch), true, 'Import DKB', 'CHF') ->> 'account_id'),
  null,
  'Vorschau mit neuem Konto legt kein Konto an'
);
select is(
  public.import_transactions(null, (select rows from batch), false, 'Import DKB', 'CHF') ->> 'new',
  '5',
  'Import in ein neues Konto'
);
select results_eq(
  $$ select a.provider::text, a.currency::text, (select count(*)::int from public.transactions t where t.account_id = a.id and t.currency = 'CHF')
       from public.accounts a where a.name = 'Import DKB' $$,
  $$ values ('csv'::text, 'CHF'::text, 5) $$,
  'Neues Konto: Provider csv, Währung CHF, Buchungen in Kontowährung'
);

-- ---------------------------------------------------------------------
-- 5. Lernen aus Korrekturen (33–41)
-- ---------------------------------------------------------------------
create temp table tx as
select
  (select id from public.transactions where account_id = '1c000000-0000-4000-8000-000000000001' and purpose like 'REWE%')   as rewe,
  (select id from public.transactions where account_id = '1c000000-0000-4000-8000-000000000001' and purpose like 'AMAZON%') as amazon;
grant select on tx to authenticated, service_role;

select is(
  public.set_transaction_category((select rewe from tx), (select groceries from cat)) - 'rule_id',
  '{"changed": true, "similar": 1, "similar_auto": 0, "learned_pattern": "rewe sagt danke"}'::jsonb,
  'Kategorie gesetzt → Regel „rewe sagt danke“ gelernt'
);
select results_eq(
  $$ select category_id, categorization_source::text from public.transactions where id = (select rewe from tx) $$,
  $$ values ((select groceries from cat), 'manual'::text) $$,
  'Buchung trägt die Kategorie, Quelle manual'
);
select results_eq(
  $$ select origin, category_id from public.categorization_rules where pattern = 'rewe sagt danke' $$,
  $$ values ('learned'::text, (select groceries from cat)) $$,
  'Gelernte Regel mit origin = learned'
);
select is(
  public.import_transactions('1c000000-0000-4000-8000-000000000001',
    '[{"booking_date": "2026-10-02", "amount": -17.30, "purpose": "REWE SAGT DANKE 99887766 Karte 5555"}]'::jsonb) ->> 'categorized',
  '1',
  'Folgende Buchung mit abweichender Nummer wird automatisch zugeordnet'
);
select is(
  (select category_id from public.transactions where booking_date = '2026-10-02'),
  (select groceries from cat),
  '… und zwar als Lebensmittel'
);

-- Korrektur einer per Regel zugeordneten Buchung: spezifischere Regel entsteht.
select is(
  public.set_transaction_category((select amazon from tx), (select education from cat)) ->> 'learned_pattern',
  'amazon prime',
  'Korrektur einer per Regel zugeordneten Buchung: Händlername „amazon prime“'
);
select is(
  private.match_category_rule(tests.get_supabase_uid('ic_alice'), null, -8.99, null, 'PAYPAL*AMAZON PRIME*QQ99 Amzn.com/bill'),
  (select education from cat),
  'Vorhandene Regel „amazon prime“ übernimmt die korrigierte Kategorie; greift trotz anderem Code'
);
select lives_ok(
  $$ select public.set_transaction_category((select amazon from tx), (select shopping from cat)) $$,
  'Erneute Korrektur derselben Buchung'
);
select results_eq(
  $$ select count(*)::int, min(category_id::text) from public.categorization_rules where pattern = 'amazon prime' $$,
  $$ values (1, (select shopping from cat)::text) $$,
  'Gleicher Händler: vorhandene gelernte Regel wird aktualisiert statt verdoppelt'
);

-- ---------------------------------------------------------------------
-- 6. Manuelle Buchungen, Fremde, Rechte (42–45)
-- ---------------------------------------------------------------------
select is(
  public.set_transaction_category(
    public.create_manual_transaction(p_booking_date => '2026-09-10', p_amount => -5, p_counterparty_name => 'Kiosk 12345',
                                     p_account_id => '1c000000-0000-4000-8000-000000000001'),
    (select groceries from cat)) ->> 'learned_pattern',
  null,
  'Manuell erfasste Buchung: Kategorie ändern lernt keine Regel'
);

select tests.authenticate_as('ic_carol');
select throws_ok(
  $$ select public.import_transactions('1c000000-0000-4000-8000-000000000001', (select rows from batch)) $$,
  'P0002', 'account_not_found', 'Beraterin kann nicht in das Konto der Mandantin importieren'
);
select throws_ok(
  $$ select public.set_transaction_category((select rewe from tx), null) $$,
  'P0002', 'transaction_not_found', 'Beraterin kann Kategorien der Mandantin nicht ändern'
);

select tests.authenticate_as_service_role();
select ok(
  not has_function_privilege('anon', 'public.import_transactions(uuid, jsonb, boolean, text, text)', 'execute')
  and not has_function_privilege('anon', 'public.set_transaction_category(uuid, uuid)', 'execute')
  and not has_function_privilege('anon', 'public.create_categorization_rule(text, uuid, public.rule_match_field, public.rule_match_type, text)', 'execute')
  and not has_function_privilege('anon', 'public.reorder_categorization_rules(uuid[])', 'execute'),
  'anon darf keine der neuen Funktionen ausführen'
);

select * from finish();
rollback;
