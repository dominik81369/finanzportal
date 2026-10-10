-- =====================================================================
--  supabase/tests/spending_report.test.sql
--  Ausgaben-Dashboard: public.spending_report() – Einordnung (Ausgaben,
--  Einnahmen, Gespart/getilgt, Umbuchung nur über eigene IBAN), Verlauf,
--  Hinweise (ohne Kategorie/Sammelkategorie, fremde IBAN mit eigenem
--  Namen), Gegenparteien, größte Buchungen, Prüfungen, Mandantentrennung
--  und Beraterzugriff (Migration 20261015100000)
--  Ausführen: supabase test db   (setzt 00000-test-helpers.sql voraus)
--
--  Identitäten
--    sp_alice – Nutzerin mit Buchungen
--    sp_bob   – anderer Nutzer
--    sp_carol – Beraterin, aktive Verbindung zu Alice
-- =====================================================================

begin;

select plan(28);

select tests.create_supabase_user('sp_alice', 'sp-alice@example.test');
select tests.create_supabase_user('sp_bob',   'sp-bob@example.test');
select tests.create_supabase_user('sp_carol', 'sp-carol@example.test');

select tests.authenticate_as_service_role();
update public.profiles set first_name = 'Alice', last_name = 'Muster' where user_id = tests.get_supabase_uid('sp_alice');
update public.profiles set role = 'advisor' where user_id = tests.get_supabase_uid('sp_carol');
insert into public.advisor_clients (advisor_id, user_id, status, invited_email, accepted_at) values
  (tests.get_supabase_uid('sp_carol'), tests.get_supabase_uid('sp_alice'), 'active', 'sp-alice@example.test', now());

insert into public.accounts (id, user_id, name, type, currency) values
  ('7f000000-0000-4000-8000-0000000000a1', tests.get_supabase_uid('sp_alice'), 'Giro',     'checking', 'EUR'),
  ('7f000000-0000-4000-8000-0000000000a2', tests.get_supabase_uid('sp_alice'), 'Konto CH', 'checking', 'CHF');

create function pg_temp.cat(p_key text) returns uuid language sql as $$
  select id from public.categories where user_id = tests.get_supabase_uid('sp_alice') and default_key = p_key;
$$;
create function pg_temp.tx(
  p_date date, p_amount numeric, p_key text, p_counterparty text,
  p_iban text default null, p_exclude boolean default false, p_account uuid default '7f000000-0000-4000-8000-0000000000a1'
) returns void language sql as $$
  insert into public.transactions (user_id, account_id, booking_date, amount, currency, category_id, counterparty_name,
                                   counterparty_iban, purpose, exclude_from_budget)
  select tests.get_supabase_uid('sp_alice'), p_account, p_date, p_amount, a.currency,
         case when p_key is null then null else pg_temp.cat(p_key) end, p_counterparty, p_iban, 'Zweck ' || p_counterparty, p_exclude
    from public.accounts a where a.id = p_account;
$$;
create function pg_temp.report(p_bucket text default 'day', p_details boolean default true) returns jsonb language sql as $$
  select public.spending_report(tests.get_supabase_uid('sp_alice'), '2026-09-01', '2026-09-30', p_bucket, p_details, 10);
$$;
grant execute on function pg_temp.report(text, boolean), pg_temp.cat(text) to authenticated;

select pg_temp.tx('2026-09-01',  3000, 'salary',              'Arbeitgeber GmbH');
select pg_temp.tx('2026-09-02', -1000, 'housing',             'Hausverwaltung Schmidt');
select pg_temp.tx('2026-09-03',  -100, 'groceries',           'REWE Markt');
select pg_temp.tx('2026-09-04',    20, 'groceries',           'REWE Markt');
select pg_temp.tx('2026-09-05',   -50, null,                  'Kiosk Eck');
select pg_temp.tx('2026-09-06',    30, null,                  'Unbekannt Zahler');
select pg_temp.tx('2026-09-07',   -40, 'other_expenses',      'Allerlei Laden');
select pg_temp.tx('2026-09-08',    10, 'other_income',        'Flohmarkt');
select pg_temp.tx('2026-09-09',  -300, 'savings_investments', 'Alice Muster Tagesgeld', 'DE02120300000000202051');
select pg_temp.tx('2026-09-10',  -200, 'loan_repayment',      'Bank Kredit');
select pg_temp.tx('2026-09-11',  -500, 'transfer',            'Alice Muster',  'DE02120300000000202051');
select pg_temp.tx('2026-09-12',  -250, 'transfer',            'Alice Muster',  'DE89370400440532013000');
select pg_temp.tx('2026-09-13',   100, 'transfer',            'Muster, Alice', 'DE89370400440532013000');
select pg_temp.tx('2026-09-14',   -60, 'groceries',           'REWE Markt', null, true);
select pg_temp.tx('2026-09-15',  -999, 'leisure_travel',      'Hotel Alpen', null, false, '7f000000-0000-4000-8000-0000000000a2');
select pg_temp.tx('2026-08-15',   -70, 'groceries',           'REWE Markt');

select tests.authenticate_as('sp_alice');
select public.add_own_account_identifier('iban', 'DE02120300000000202051');

-- ---------------------------------------------------------------------
-- 1. Einordnung und Summen (1–9)
-- ---------------------------------------------------------------------
create temp table r as select pg_temp.report() as j;
grant select on r to authenticated;
create function pg_temp.class_sum(p_currency text, p_class text) returns numeric language sql as $$
  select coalesce(sum((e ->> 'amount')::numeric), 0)
    from r, jsonb_array_elements(r.j -> 'categories') e
   where e ->> 'currency' = p_currency and e ->> 'class' = p_class;
$$;
grant execute on function pg_temp.class_sum(text, text) to authenticated;

select is(-pg_temp.class_sum('EUR', 'expense'), 1420::numeric,
  'Ausgaben 1.420: Miete, Lebensmittel netto (Erstattung mindert), ohne Kategorie, Sammelkategorie, Umbuchung an fremde IBAN');
select is(pg_temp.class_sum('EUR', 'income'), 3140::numeric,
  'Einnahmen 3.140: Gehalt, Gutschrift ohne Kategorie, Sammelkategorie, Gutschrift von fremder IBAN');
select is(-pg_temp.class_sum('EUR', 'saved'), 500::numeric,
  'Gespart/getilgt 500: Sparen & Investieren (auch auf eigene IBAN) und Kredittilgung');
select is((select (e ->> 'amount')::numeric || '|' || (e ->> 'count')
             from r, jsonb_array_elements(r.j -> 'categories') e
            where e ->> 'category_id' = pg_temp.cat('groceries')::text),
  '-80.00|2', 'Kategorie Lebensmittel netto mit Anzahl; ausgenommene Buchung und Vormonat zählen nicht');
select is((select string_agg(e ->> 'class' || ':' || (e ->> 'amount'), ',' order by e ->> 'class')
             from r, jsonb_array_elements(r.j -> 'categories') e
            where e ->> 'category_id' is null),
  'expense:-50.00,income:30.00', 'Ohne Kategorie: Abbuchung als Ausgabe, Gutschrift als Einnahme');
select is((r.j -> 'transfers'), '[{"count": 1, "inflow": 0, "outflow": 500, "currency": "EUR"}]'::jsonb,
  'Umbuchung nur über die erfasste eigene IBAN (zählt nirgends)')
  from r;
select is((select string_agg(e ->> 'currency', ',' order by e ->> 'currency')
             from r, jsonb_array_elements(r.j -> 'categories') e where e ->> 'class' = 'expense' and e ->> 'currency' = 'CHF'),
  'CHF', 'Andere Währung getrennt');
select is((select (e ->> 'expenses')::numeric || '|' || (e ->> 'income')::numeric
             from r, jsonb_array_elements(r.j -> 'buckets') e
            where e ->> 'currency' = 'EUR' and e ->> 'bucket' = '2026-09-02'),
  '1000.00|0', 'Verlauf je Tag');
select is((select (e ->> 'expenses')::numeric || '|' || (e ->> 'income')::numeric || '|' || (e ->> 'saved')::numeric
             from jsonb_array_elements(pg_temp.report('week', false) -> 'buckets') e
            where e ->> 'currency' = 'EUR' and e ->> 'bucket' = '2026-08-31'),
  '1130.00|3030.00|0', 'Verlauf je Woche (ab Montag 31.08.)');

-- ---------------------------------------------------------------------
-- 2. Hinweise (10–13)
-- ---------------------------------------------------------------------
select is(r.j -> 'flagged', '[{"count": 4, "income": 40, "currency": "EUR", "expenses": 90}]'::jsonb,
  'Ohne Kategorie und Sammelkategorien „Sonstige Ausgaben/Einnahmen“: 4 Buchungen')
  from r;
select is(r.j -> 'same_holder', '[{"count": 2, "ibans": 1, "inflow": 100, "outflow": 250, "currency": "EUR"}]'::jsonb,
  'Fremde IBAN mit eigenem Namen (aus dem Profil, auch „Nachname, Vorname“): 2 Buchungen, 1 IBAN')
  from r;
select public.add_own_account_identifier('name', 'Alice Beispiel');
select is(pg_temp.report() -> 'same_holder', '[]'::jsonb,
  'Mit Namensregel zählt deren Name statt des Profilnamens');
select public.add_own_account_identifier('iban', 'DE89370400440532013000');
select is((select (e ->> 'outflow')::numeric || '|' || (e ->> 'count')
             from jsonb_array_elements(pg_temp.report() -> 'transfers') e where e ->> 'currency' = 'EUR'),
  '750.00|3', 'Nach Erfassen der IBAN als eigenes Konto: Umbuchung statt Ausgabe');

-- ---------------------------------------------------------------------
-- 3. Gegenparteien und größte Buchungen (14–18)
-- ---------------------------------------------------------------------
create temp table d as select pg_temp.report() as j;
grant select on d to authenticated;
select is((select string_agg(e ->> 'label' || ':' || (e ->> 'expenses') || ':' || (e ->> 'count'), ', '
                             order by (e ->> 'expenses')::numeric desc)
             from d, jsonb_array_elements(d.j -> 'counterparties') e where e ->> 'currency' = 'EUR'),
  'Hausverwaltung Schmidt:1000.00:1, REWE Markt:80.00:1, Kiosk Eck:50.00:1, Allerlei Laden:40.00:1',
  'Top-Gegenparteien nach Ausgaben (netto), ohne Umbuchungen, Gespartes und Einnahmen');
select is((select string_agg((e ->> 'amount') || ' ' || (e ->> 'counterparty'), ', ' order by (e ->> 'amount')::numeric)
             from d, jsonb_array_elements(d.j -> 'largest') e where e ->> 'currency' = 'EUR'),
  '-1000.00 Hausverwaltung Schmidt, -100.00 REWE Markt, -50.00 Kiosk Eck, -40.00 Allerlei Laden',
  'Größte Abbuchungen unter den Ausgaben');
select is((select count(*)::integer from d, jsonb_array_elements(d.j -> 'largest') e where e ->> 'currency' = 'CHF'), 1,
  'Größte Buchungen je Währung');
select is((select jsonb_array_length(public.spending_report(tests.get_supabase_uid('sp_alice'), '2026-09-01', '2026-09-30', 'day', true, 2) -> 'largest')),
  3, 'Höchstens p_limit je Währung (2 EUR + 1 CHF)');
select is((select (pg_temp.report('day', false) -> 'counterparties') || (pg_temp.report('day', false) -> 'largest')), '[]'::jsonb,
  'Ohne Details keine Gegenparteien und Buchungen');

-- ---------------------------------------------------------------------
-- 4. Prüfungen (19–22)
-- ---------------------------------------------------------------------
select throws_ok($$ select public.spending_report(tests.get_supabase_uid('sp_alice'), '2026-09-30', '2026-09-01', 'day') $$,
  '22023', 'invalid_period', 'Ende vor Beginn');
select throws_ok($$ select public.spending_report(tests.get_supabase_uid('sp_alice'), '2020-01-01', '2026-09-01', 'month') $$,
  '22023', 'invalid_period', 'Höchstens gut fünf Jahre');
select throws_ok($$ select public.spending_report(tests.get_supabase_uid('sp_alice'), '2025-01-01', '2026-09-01', 'day') $$,
  '22023', 'invalid_bucket', 'Tage nur bis gut ein Jahr');
select throws_ok($$ select public.spending_report(tests.get_supabase_uid('sp_alice'), '2026-01-01', '2026-09-01', 'quarter') $$,
  '22023', 'invalid_bucket', 'Unbekannte Teilzeiträume abgelehnt');

-- ---------------------------------------------------------------------
-- 5. Mandantentrennung und Beraterzugriff (23–28)
-- ---------------------------------------------------------------------
select tests.authenticate_as('sp_bob');
select is(pg_temp.report() -> 'categories', '[]'::jsonb, 'Bob sieht keine fremden Summen');
select is(pg_temp.report() -> 'largest', '[]'::jsonb, 'Bob sieht keine fremden Buchungen');
select tests.authenticate_as('sp_carol');
select is((select -sum((e ->> 'amount')::numeric) from jsonb_array_elements(pg_temp.report() -> 'categories') e
            where e ->> 'currency' = 'EUR' and e ->> 'class' = 'expense'),
  1170::numeric, 'Beraterin liest die Auswertung der Mandantin');
select is(jsonb_array_length(pg_temp.report() -> 'largest') > 0, true, 'Beraterin sieht die größten Buchungen');
select ok(not has_function_privilege('anon', 'public.spending_report(uuid, date, date, text, boolean, integer)', 'execute'),
  'anon darf spending_report nicht ausführen');
select ok(not has_function_privilege('anon', 'private.spending_transactions(uuid, date, date)', 'execute'),
  'anon darf private.spending_transactions nicht ausführen');

select * from finish();
rollback;
