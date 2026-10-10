-- =====================================================================
--  20261016100100_pdf_import.sql
--  PDF-Import (N26): Kontoauszug mit Hauptkonto und Spaces
--
--  1. accounts.iban: vollständige IBAN eines Kontos (je Nutzer eindeutig).
--     Ordnet die Abschnitte eines Kontoauszugs ihren Konten zu.
--  2. Kategorie „Privatentnahme“ (Einnahmen, Schlüssel private_withdrawal)
--     für neue und bestehende Nutzer.
--  3. Kartenkategorien der Bank: Regeln mit origin = bank_category auf die
--     Buchungsart (z. B. „Mastercard • Lebensmittel“) → eigene Kategorie.
--     Je Nutzer gespeichert und änderbar (Startwerte siehe
--     private.bank_category_templates, ergänzt mit „Standardregeln
--     laden“); sie greifen nach eigenen Regeln,
--     Gegenpartei-Gedächtnis, eigenen Konten und Standardregeln (Marken),
--     vor dem Lernverfahren.
--  4. Standardregeln: Corendon und Mietwagen → Freizeit & Reisen,
--     Gutschrift mit „Miete“ im Verwendungszweck → Mieteinnahmen.
--  5. Import: gemeinsamer Kern für CSV und PDF (private.import_batch_run);
--     public.import_statement() importiert alle Abschnitte eines Auszugs in
--     einer Transaktion (alles oder nichts):
--       - Saldenprüfung je Abschnitt (alter Stand + Buchungen = neuer Stand),
--       - Duplikatschlüssel Datum + Betrag + Gegenpartei + Verwendungszweck
--         + laufender Zähler gleicher Buchungen im Abschnitt,
--       - „vermutlich vorhanden“: gleiche Buchung (Datum + Betrag) aus einer
--         anderen Quelle im Zielkonto wird übersprungen,
--       - IBANs der Abschnitte werden eigene Konten (Umbuchung),
--       - Anfangsbestand aus dem ältesten Auszug, Abgleich des Kontostands.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. IBAN am Konto
-- ---------------------------------------------------------------------
alter table public.accounts
  add column iban text
    constraint accounts_iban_format check (iban ~ '^[A-Z]{2}[0-9]{2}[0-9A-Z]{11,30}$');

comment on column public.accounts.iban is
  'Vollständige IBAN des Kontos (Großbuchstaben, ohne Leerzeichen), je Nutzer eindeutig. Ordnet die Abschnitte '
  'eines PDF-Kontoauszugs dem Konto zu.';

create unique index accounts_user_iban_key on public.accounts (user_id, iban) where iban is not null;

-- ---------------------------------------------------------------------
-- 2. Kategorie „Privatentnahme“
-- ---------------------------------------------------------------------
create or replace function private.seed_default_categories(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.categories (user_id, name, kind, color, icon, is_default, sort_order, default_key)
  values
    (p_user_id, 'Gehalt & Lohn',        'income',   '#16a34a', 'banknote',         true,  10, 'salary'),
    (p_user_id, 'Kapitalerträge',       'income',   '#15803d', 'trending-up',      true,  20, 'investment_income'),
    (p_user_id, 'Mieteinnahmen',        'income',   '#166534', 'building-2',       true,  30, 'rental_income'),
    (p_user_id, 'Privatentnahme',       'income',   '#22c55e', 'briefcase',        true,  35, 'private_withdrawal'),
    (p_user_id, 'Sonstige Einnahmen',   'income',   '#4ade80', 'circle-plus',      true,  40, 'other_income'),
    (p_user_id, 'Wohnen',               'expense',  '#2563eb', 'house',            true, 100, 'housing'),
    (p_user_id, 'Lebensmittel',         'expense',  '#f59e0b', 'shopping-cart',    true, 110, 'groceries'),
    (p_user_id, 'Mobilität',            'expense',  '#0ea5e9', 'car',              true, 120, 'mobility'),
    (p_user_id, 'Versicherungen',       'expense',  '#6366f1', 'shield',           true, 130, 'insurance'),
    (p_user_id, 'Gesundheit',           'expense',  '#ef4444', 'heart-pulse',      true, 140, 'health'),
    (p_user_id, 'Freizeit & Reisen',    'expense',  '#ec4899', 'plane',            true, 150, 'leisure_travel'),
    (p_user_id, 'Abos & Medien',        'expense',  '#a855f7', 'tv',               true, 160, 'subscriptions_media'),
    (p_user_id, 'Shopping',             'expense',  '#f97316', 'shopping-bag',     true, 170, 'shopping'),
    (p_user_id, 'Bildung',              'expense',  '#14b8a6', 'graduation-cap',   true, 180, 'education'),
    (p_user_id, 'Steuern & Abgaben',    'expense',  '#64748b', 'landmark',         true, 190, 'taxes'),
    (p_user_id, 'Kapitalertragsteuer',  'expense',  '#475569', 'percent',          true, 195, 'capital_gains_tax'),
    (p_user_id, 'Darlehen',             'expense',  '#334155', 'landmark',         true, 196, 'loan'),
    (p_user_id, 'Darlehenszinsen',      'expense',  '#334155', 'percent',          true, 197, 'loan_interest'),
    (p_user_id, 'Sonstige Ausgaben',    'expense',  '#94a3b8', 'ellipsis',         true, 200, 'other_expenses'),
    (p_user_id, 'Sparen & Investieren', 'transfer', '#0f766e', 'piggy-bank',       true, 300, 'savings_investments'),
    (p_user_id, 'Kredittilgung',        'transfer', '#475569', 'receipt',          true, 310, 'loan_repayment'),
    (p_user_id, 'Umbuchung',            'transfer', '#9ca3af', 'arrow-left-right', true, 320, 'transfer')
  on conflict on constraint categories_name_key do nothing;
end;
$$;

-- Bestand (idempotent): gleichnamige Einnahmen-Kategorie ohne Schlüssel
-- erhält den Schlüssel, sonst wird die Kategorie angelegt.
do $$
declare
  v_user uuid;
begin
  for v_user in select distinct c.user_id from public.categories c loop
    if exists (select 1 from public.categories c where c.user_id = v_user and c.default_key = 'private_withdrawal') then
      continue;
    end if;
    update public.categories c
       set default_key = 'private_withdrawal'
     where c.user_id = v_user
       and c.parent_category_id is null
       and c.default_key is null
       and c.kind = 'income'
       and c.name = 'Privatentnahme';
    if not found then
      insert into public.categories (user_id, name, kind, color, icon, is_default, sort_order, default_key)
      values (v_user, 'Privatentnahme', 'income', '#22c55e', 'briefcase', true, 35, 'private_withdrawal')
      on conflict on constraint categories_name_key do nothing;
    end if;
  end loop;
end;
$$;

-- ---------------------------------------------------------------------
-- 3. Kartenkategorien der Bank
-- ---------------------------------------------------------------------
alter table public.categorization_rules drop constraint categorization_rules_origin_check;
alter table public.categorization_rules
  add constraint categorization_rules_origin_check
  check (origin in ('manual', 'learned', 'standard', 'own_account', 'bank_category'));
comment on column public.categorization_rules.origin is
  'manual = vom Nutzer angelegt, learned = aus einer Korrektur gelernt, standard = aus dem Standard-Regelset, '
  'own_account = Erkennung eigener Konten (Name/IBAN → Umbuchung), bank_category = Kartenkategorie der Bank '
  '(Buchungsart, z. B. „Mastercard • Lebensmittel“) → eigene Kategorie.';

-- Startwerte: Bezeichnung der Kartenkategorie (Vergleich „ganzes Wort“ in
-- der Buchungsart) → default_key der eigenen Kategorie. Bewusst ohne
-- Hausgeld, WEG und Darlehen (keine pauschale Zuordnung).
create function private.bank_category_templates()
returns table (label text, default_key text)
language sql
immutable
set search_path = ''
as $$
  select t.label, t.key
    from (values
      ('Lebensmittel',       'groceries'),
      ('Bars & Restaurants', 'leisure_travel'),
      ('Freizeit',           'leisure_travel'),
      ('Reisen',             'leisure_travel'),
      ('Transport',          'mobility'),
      ('Medien & Telekom',   'subscriptions_media'),
      ('Wohnen & Energie',   'housing'),
      ('Shopping',           'shopping'),
      ('Gesundheit',         'health'),
      ('Bildung',            'education'),
      ('Versicherungen',     'insurance'),
      ('Steuern',            'taxes')
    ) as t (label, key);
$$;

comment on function private.bank_category_templates() is
  'Startwerte der Kartenkategorien (N26): Bezeichnung → default_key. Je Nutzer als Regeln (origin bank_category) '
  'angelegt und danach frei änderbar.';

-- Fehlende Startwerte als Regeln anlegen (vorhandene bleiben unverändert).
-- Zusammen mit den Standardregeln (public.load_standard_rules): Ohne die
-- Marken-Regeln würde die Kartenkategorie sonst vor der Marke greifen.
create function private.seed_bank_category_rules(p_user_id uuid)
returns integer
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_count integer;
begin
  insert into public.categorization_rules (user_id, category_id, pattern, match_type, match_field, priority, origin)
  select p_user_id, c.id, t.label, 'word', 'transaction_type', 100, 'bank_category'
    from private.bank_category_templates() t
    join public.categories c on c.user_id = p_user_id and c.default_key = t.default_key
   where not exists (
     select 1 from public.categorization_rules r
      where r.user_id = p_user_id
        and r.origin = 'bank_category'
        and private.normalize_booking_text(r.pattern) = private.normalize_booking_text(t.label)
   );
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;
-- Standardregeln laden: auch die Startwerte der Kartenkategorien ergänzen
-- (vor dem Abgleich, damit sie gleich mit angewendet werden).
create or replace function public.load_standard_rules()
returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_uid  uuid := auth.uid();
  v_bank integer;
  v_row  record;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  v_bank := private.seed_bank_category_rules(v_uid);
  select * into v_row from private.sync_standard_rules(v_uid);
  return jsonb_build_object('added', v_row.added, 'removed', v_row.removed,
                            'reset', v_row.reset, 'applied', v_row.applied, 'bank_added', v_bank);
end;
$$;

comment on function public.load_standard_rules() is
  'Standardregeln mit dem Regelset abgleichen (ergänzen, entfernte löschen und deren automatische '
  'Zuordnungen zurücksetzen), fehlende Startwerte der Kartenkategorien ergänzen und alles auf Buchungen ohne '
  'Kategorie anwenden. Liefert {added, removed, reset, applied, bank_added}.';

-- Regel-Abgleich: Kartenkategorien nach Standardregeln (Marken vor
-- Kartenkategorie, z. B. Corendon = Reisen statt „Transport“).
create or replace function private.match_rule_detail(
  p_user_id          uuid,
  p_account_id       uuid,
  p_amount           numeric,
  p_counterparty     text,
  p_purpose          text,
  p_description      text,
  p_transaction_type text,
  p_iban             text,
  p_origins          text[],
  p_own_names        boolean
)
returns table (rule_id uuid, category_id uuid, origin text)
language sql
stable
set search_path = ''
as $$
  select r.id, r.category_id, r.origin
    from public.categorization_rules r
    cross join lateral (select private.normalize_booking_text(r.pattern) as np) n
   where r.user_id = p_user_id
     and r.is_active
     and r.origin = any (p_origins)
     -- Namensregeln eigener Konten nur auf ausdrücklichen Wunsch (Vorschläge).
     and (p_own_names or not (r.origin = 'own_account' and r.match_field = 'counterparty'))
     and (r.account_id is null or r.account_id = p_account_id)
     and (r.amount_min is null or p_amount >= r.amount_min)
     and (r.amount_max is null or p_amount <= r.amount_max)
     and exists (
       select 1
         from (values
           ('counterparty',      p_counterparty),
           ('purpose',           p_purpose),
           ('description',       p_description),
           ('transaction_type',  p_transaction_type),
           ('counterparty_iban', p_iban)
         ) as f (field, raw)
        cross join lateral (
          select case when f.field = 'counterparty_iban'
                      then lower(replace(f.raw, ' ', ''))
                      else private.normalize_booking_text(f.raw) end as norm,
                 case when f.field = 'counterparty_iban'
                      then lower(replace(r.pattern, ' ', ''))
                      else n.np end as pat
        ) v
        where f.raw is not null
          and case r.match_field::text
                when 'counterparty_or_purpose' then f.field in ('counterparty', 'purpose', 'description')
                when 'any_text' then f.field in ('counterparty', 'purpose', 'description', 'transaction_type')
                else f.field = r.match_field::text
              end
          and case r.match_type::text
                when 'contains'    then v.pat <> '' and position(v.pat in v.norm) > 0
                when 'word'        then v.pat <> '' and position(' ' || v.pat || ' ' in ' ' || v.norm || ' ') > 0
                when 'all_words'   then v.pat <> '' and not exists (
                                          select 1 from regexp_split_to_table(v.pat, ' ') as w (word)
                                           where w.word <> ''
                                             and position(' ' || w.word || ' ' in ' ' || v.norm || ' ') = 0)
                when 'equals'      then v.pat <> '' and v.norm = v.pat
                when 'starts_with' then v.pat <> '' and starts_with(v.norm, v.pat)
                when 'regex'       then case when r.case_sensitive then f.raw ~ r.pattern else f.raw ~* r.pattern end
              end
     )
   order by case r.origin when 'bank_category' then 3 when 'standard' then 2 when 'own_account' then 1 else 0 end,
            r.priority, char_length(n.np) desc, r.created_at, r.id
   limit 1;
$$;

create or replace function private.match_rule(
  p_user_id          uuid,
  p_account_id       uuid,
  p_amount           numeric,
  p_counterparty     text,
  p_purpose          text,
  p_description      text default null,
  p_transaction_type text default null,
  p_iban             text default null
)
returns table (rule_id uuid, category_id uuid)
language sql
stable
set search_path = ''
as $$
  select d.rule_id, d.category_id
    from private.match_rule_detail(p_user_id, p_account_id, p_amount, p_counterparty, p_purpose, p_description,
                                   p_transaction_type, p_iban,
                                   array['manual', 'learned', 'own_account', 'standard', 'bank_category'], false) d;
$$;

-- Schichten: eigene Regeln → Gegenpartei-Gedächtnis → eigene Konten (IBAN)
-- → Standardregeln → Kartenkategorien der Bank.
create or replace function private.classify(
  p_user_id          uuid,
  p_account_id       uuid,
  p_amount           numeric,
  p_counterparty     text,
  p_purpose          text,
  p_description      text,
  p_transaction_type text,
  p_iban             text,
  p_key              text
)
returns table (category_id uuid, source public.categorization_source, rule_id uuid)
language plpgsql
stable
set search_path = ''
as $$
declare
  v_rule     record;
  v_category uuid;
begin
  select * into v_rule
    from private.match_rule_detail(p_user_id, p_account_id, p_amount, p_counterparty, p_purpose, p_description,
                                   p_transaction_type, p_iban, array['manual', 'learned'], false);
  if v_rule.rule_id is not null then
    return query select v_rule.category_id, 'rule'::public.categorization_source, v_rule.rule_id;
    return;
  end if;

  v_category := private.memory_category(p_user_id, p_key);
  if v_category is not null then
    return query select v_category, 'learned'::public.categorization_source, null::uuid;
    return;
  end if;

  select * into v_rule
    from private.match_rule_detail(p_user_id, p_account_id, p_amount, p_counterparty, p_purpose, p_description,
                                   p_transaction_type, p_iban, array['own_account', 'standard', 'bank_category'], false);
  if v_rule.rule_id is not null then
    return query select v_rule.category_id, 'rule'::public.categorization_source, v_rule.rule_id;
  end if;
end;
$$;

comment on function private.classify(uuid, uuid, numeric, text, text, text, text, text, text) is
  'Kategorie nach Schichten: eigene Regeln, Gegenpartei-Gedächtnis (learned), eigene Konten (IBAN), '
  'Standardregeln, Kartenkategorien der Bank. Keine Zeile, wenn nichts passt.';

-- Kennzahlen: Kartenkategorien zählen wie Standardregeln (automatische Vorgabe).
create or replace function public.categorization_stats()
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select jsonb_build_object(
    'total',         count(*),
    'manual',        count(*) filter (where t.category_id is not null
                                       and t.categorization_source is distinct from 'rule'
                                       and t.categorization_source is distinct from 'learned'),
    'rule',          count(*) filter (where t.categorization_source = 'rule'
                                       and coalesce(r.origin, 'manual') not in ('standard', 'bank_category')),
    'standard',      count(*) filter (where t.categorization_source = 'rule'
                                       and r.origin in ('standard', 'bank_category')),
    'learned',       count(*) filter (where t.categorization_source = 'learned' and t.categorization_confidence is null),
    'bayes',         count(*) filter (where t.categorization_source = 'learned' and t.categorization_confidence is not null),
    'suggested',     count(*) filter (where t.category_id is null and t.suggested_category_id is not null),
    'uncategorized', count(*) filter (where t.category_id is null)
  )
    from public.transactions t
    left join public.categorization_rules r on r.id = t.categorization_rule_id
   where t.user_id = (select auth.uid());
$$;

-- Kartenkategorie hinzufügen: Bezeichnung (wie in der Buchungsart, z. B.
-- „Lebensmittel“) → eigene Kategorie; sofort angewendet (auch auf
-- automatisch anders zugeordnete Buchungen, auf die sie jetzt zuerst passt).
create function public.add_bank_category_rule(p_label text, p_category_id uuid)
returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_uid   uuid := auth.uid();
  v_label text := btrim(regexp_replace(coalesce(p_label, ''), '\s+', ' ', 'g'));
  v_id    uuid;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if char_length(v_label) not between 2 and 100 or private.normalize_booking_text(v_label) !~ '[[:alpha:]]{2}' then
    raise exception 'invalid_label' using errcode = '22023';
  end if;
  if not exists (select 1 from public.categories c where c.id = p_category_id and c.user_id = v_uid) then
    raise exception 'category_not_found' using errcode = 'P0002';
  end if;
  if exists (
    select 1 from public.categorization_rules r
     where r.user_id = v_uid and r.origin = 'bank_category'
       and private.normalize_booking_text(r.pattern) = private.normalize_booking_text(v_label)
  ) then
    raise exception 'rule_exists' using errcode = '23505';
  end if;

  insert into public.categorization_rules (user_id, category_id, pattern, match_type, match_field, priority, origin)
  values (v_uid, p_category_id, v_label, 'word', 'transaction_type', 100, 'bank_category')
  returning id into v_id;

  return jsonb_build_object('rule_id', v_id, 'applied', private.apply_rules_for_user(v_uid, v_id, false, true));
end;
$$;

comment on function public.add_bank_category_rule(text, uuid) is
  'Kartenkategorie der Bank → eigene Kategorie (Regel origin bank_category auf die Buchungsart, ganzes Wort). '
  'Liefert {rule_id, applied}. Fehler: invalid_label (22023), category_not_found (P0002), rule_exists (23505).';

-- Zielkategorie einer Kartenkategorie ändern und neu anwenden (automatische
-- Zuordnungen dieser Regel werden angepasst, manuelle nie).
create function public.set_bank_category_rule(p_rule_id uuid, p_category_id uuid)
returns integer
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not exists (select 1 from public.categories c where c.id = p_category_id and c.user_id = v_uid) then
    raise exception 'category_not_found' using errcode = 'P0002';
  end if;
  update public.categorization_rules r
     set category_id = p_category_id
   where r.id = p_rule_id and r.user_id = v_uid and r.origin = 'bank_category';
  if not found then
    raise exception 'rule_not_found' using errcode = 'P0002';
  end if;
  return private.apply_rules_for_user(v_uid, p_rule_id, false, true);
end;
$$;

comment on function public.set_bank_category_rule(uuid, uuid) is
  'Zielkategorie einer Kartenkategorie ändern und auf deren automatische Zuordnungen anwenden. '
  'Fehler: category_not_found, rule_not_found (P0002).';

-- Startwerte für bestehende Nutzer mit Standardregeln (angewendet beim
-- Abgleich der Standardregeln unten).
do $$
declare
  v_user uuid;
begin
  for v_user in select distinct r.user_id from public.categorization_rules r where r.origin = 'standard' loop
    perform private.seed_bank_category_rules(v_user);
  end loop;
end;
$$;

-- ---------------------------------------------------------------------
-- 4. Standardregeln: Reisen, Mieteinnahmen
-- ---------------------------------------------------------------------
create or replace function private.standard_rule_templates()
returns table (
  pattern     text,
  match_field public.rule_match_field,
  match_type  public.rule_match_type,
  default_key text,
  direction   text,
  priority    smallint
)
language sql
immutable
set search_path = ''
as $$
  select t.pattern, t.field::public.rule_match_field, t.type::public.rule_match_type, t.key, t.dir, t.prio::smallint
    from (values
      -- Lebensmittel und Drogerie
      ('rewe',                 'counterparty_or_purpose', 'word', 'groceries', 'out', 100),
      ('edeka',                'counterparty_or_purpose', 'word', 'groceries', 'out', 100),
      ('aldi',                 'counterparty_or_purpose', 'word', 'groceries', 'out', 100),
      ('lidl',                 'counterparty_or_purpose', 'word', 'groceries', 'out', 100),
      ('penny',                'counterparty_or_purpose', 'word', 'groceries', 'out', 100),
      ('netto marken',         'counterparty_or_purpose', 'word', 'groceries', 'out', 100),
      ('netto city',           'counterparty_or_purpose', 'word', 'groceries', 'out', 100),
      ('kaufland',             'counterparty_or_purpose', 'word', 'groceries', 'out', 100),
      ('norma',                'counterparty_or_purpose', 'word', 'groceries', 'out', 100),
      ('tegut',                'counterparty_or_purpose', 'word', 'groceries', 'out', 100),
      ('globus',               'counterparty_or_purpose', 'word', 'groceries', 'out', 100),
      ('marktkauf',            'counterparty_or_purpose', 'word', 'groceries', 'out', 100),
      ('nahkauf',              'counterparty_or_purpose', 'word', 'groceries', 'out', 100),
      ('famila',               'counterparty_or_purpose', 'word', 'groceries', 'out', 100),
      ('alnatura',             'counterparty_or_purpose', 'word', 'groceries', 'out', 100),
      ('denns biomarkt',       'counterparty_or_purpose', 'word', 'groceries', 'out', 100),
      ('bio company',          'counterparty_or_purpose', 'word', 'groceries', 'out', 100),
      ('basic bio',            'counterparty_or_purpose', 'word', 'groceries', 'out', 100),
      ('vollcorner',           'counterparty_or_purpose', 'word', 'groceries', 'out', 100),
      ('picnic',               'counterparty_or_purpose', 'word', 'groceries', 'out', 100),
      ('flink',                'counterparty_or_purpose', 'word', 'groceries', 'out', 100),
      ('dm drogerie',          'counterparty_or_purpose', 'word', 'groceries', 'out', 100),
      ('dm fil',               'counterparty_or_purpose', 'word', 'groceries', 'out', 100),
      ('rossmann',             'counterparty_or_purpose', 'word', 'groceries', 'out', 100),
      ('mueller drogerie',     'counterparty_or_purpose', 'word', 'groceries', 'out', 100),
      ('drogerie mueller',     'counterparty_or_purpose', 'word', 'groceries', 'out', 100),
      ('budni',                'counterparty_or_purpose', 'word', 'groceries', 'out', 100),
      -- Mobilität (Nahverkehr vor „Stadtwerke“: MVG gehört zu den SWM)
      ('mvg',                  'counterparty_or_purpose', 'word', 'mobility',  'out',  90),
      ('mvv',                  'counterparty_or_purpose', 'word', 'mobility',  'out',  90),
      ('bvg',                  'counterparty_or_purpose', 'word', 'mobility',  'out',  90),
      ('hvv',                  'counterparty_or_purpose', 'word', 'mobility',  'out',  90),
      ('rmv',                  'counterparty_or_purpose', 'word', 'mobility',  'out',  90),
      ('vrr',                  'counterparty_or_purpose', 'word', 'mobility',  'out',  90),
      ('vvs',                  'counterparty_or_purpose', 'word', 'mobility',  'out',  90),
      ('kvb',                  'counterparty_or_purpose', 'word', 'mobility',  'out',  90),
      ('vgn',                  'counterparty_or_purpose', 'word', 'mobility',  'out',  90),
      ('vbb',                  'counterparty_or_purpose', 'word', 'mobility',  'out',  90),
      ('deutschlandticket',    'counterparty_or_purpose', 'word', 'mobility',  'out',  90),
      ('deutsche bahn',        'counterparty_or_purpose', 'word', 'mobility',  'out', 100),
      ('db vertrieb',          'counterparty_or_purpose', 'word', 'mobility',  'out', 100),
      ('db fernverkehr',       'counterparty_or_purpose', 'word', 'mobility',  'out', 100),
      ('db regio',             'counterparty_or_purpose', 'word', 'mobility',  'out', 100),
      ('bahn.de',              'counterparty_or_purpose', 'word', 'mobility',  'out', 100),
      ('flixbus',              'counterparty_or_purpose', 'word', 'mobility',  'out', 100),
      ('flixtrain',            'counterparty_or_purpose', 'word', 'mobility',  'out', 100),
      ('aral',                 'counterparty_or_purpose', 'word', 'mobility',  'out', 100),
      ('shell',                'counterparty_or_purpose', 'word', 'mobility',  'out', 100),
      ('esso',                 'counterparty_or_purpose', 'word', 'mobility',  'out', 100),
      ('totalenergies',        'counterparty_or_purpose', 'word', 'mobility',  'out', 100),
      ('jet tankstelle',       'counterparty_or_purpose', 'word', 'mobility',  'out', 100),
      ('agip',                 'counterparty_or_purpose', 'word', 'mobility',  'out', 100),
      ('omv',                  'counterparty_or_purpose', 'word', 'mobility',  'out', 100),
      ('sixt',                 'counterparty_or_purpose', 'word', 'mobility',  'out', 100),
      ('share now',            'counterparty_or_purpose', 'word', 'mobility',  'out', 100),
      ('miles mobility',       'counterparty_or_purpose', 'word', 'mobility',  'out', 100),
      ('free now',             'counterparty_or_purpose', 'word', 'mobility',  'out', 100),
      ('tier mobility',        'counterparty_or_purpose', 'word', 'mobility',  'out', 100),
      ('adac',                 'counterparty_or_purpose', 'word', 'mobility',  'out', 100),
      ('easypark',             'counterparty_or_purpose', 'word', 'mobility',  'out', 100),
      ('contipark',            'counterparty_or_purpose', 'word', 'mobility',  'out', 100),
      ('apcoa',                'counterparty_or_purpose', 'word', 'mobility',  'out', 100),
      -- Telefon, Internet, Rundfunk, Streaming
      ('telekom',              'counterparty_or_purpose', 'word', 'subscriptions_media', 'out', 100),
      ('vodafone',             'counterparty_or_purpose', 'word', 'subscriptions_media', 'out', 100),
      ('o2',                   'counterparty_or_purpose', 'word', 'subscriptions_media', 'out', 100),
      ('telefonica',           'counterparty_or_purpose', 'word', 'subscriptions_media', 'out', 100),
      ('1&1',                  'counterparty_or_purpose', 'word', 'subscriptions_media', 'out', 100),
      ('congstar',             'counterparty_or_purpose', 'word', 'subscriptions_media', 'out', 100),
      ('freenet',              'counterparty_or_purpose', 'word', 'subscriptions_media', 'out', 100),
      ('fraenk',               'counterparty_or_purpose', 'word', 'subscriptions_media', 'out', 100),
      ('pyur',                 'counterparty_or_purpose', 'word', 'subscriptions_media', 'out', 100),
      ('netcologne',           'counterparty_or_purpose', 'word', 'subscriptions_media', 'out', 100),
      ('m net',                'counterparty_or_purpose', 'word', 'subscriptions_media', 'out', 100),
      ('beitragsservice',      'counterparty_or_purpose', 'word', 'subscriptions_media', 'out', 100),
      ('rundfunkbeitrag',      'counterparty_or_purpose', 'word', 'subscriptions_media', 'out', 100),
      ('netflix',              'counterparty_or_purpose', 'word', 'subscriptions_media', 'out', 100),
      ('spotify',              'counterparty_or_purpose', 'word', 'subscriptions_media', 'out', 100),
      ('amazon prime',         'counterparty_or_purpose', 'word', 'subscriptions_media', 'out', 100),
      ('dazn',                 'counterparty_or_purpose', 'word', 'subscriptions_media', 'out', 100),
      ('sky deutschland',      'counterparty_or_purpose', 'word', 'subscriptions_media', 'out', 100),
      ('rtl+',                 'counterparty_or_purpose', 'word', 'subscriptions_media', 'out', 100),
      ('waipu.tv',             'counterparty_or_purpose', 'word', 'subscriptions_media', 'out', 100),
      -- Energie und Wohnen (Stadtwerke betreiben oft auch den Nahverkehr → 110)
      ('stadtwerke',           'counterparty_or_purpose', 'word', 'housing',   'out', 110),
      ('swm',                  'counterparty_or_purpose', 'word', 'housing',   'out', 110),
      ('e.on',                 'counterparty_or_purpose', 'word', 'housing',   'out', 100),
      ('eon energie',          'counterparty_or_purpose', 'word', 'housing',   'out', 100),
      ('vattenfall',           'counterparty_or_purpose', 'word', 'housing',   'out', 100),
      ('enbw',                 'counterparty_or_purpose', 'word', 'housing',   'out', 100),
      ('rheinenergie',         'counterparty_or_purpose', 'word', 'housing',   'out', 100),
      ('mainova',              'counterparty_or_purpose', 'word', 'housing',   'out', 100),
      ('entega',               'counterparty_or_purpose', 'word', 'housing',   'out', 100),
      ('n ergie',              'counterparty_or_purpose', 'word', 'housing',   'out', 100),
      ('eprimo',               'counterparty_or_purpose', 'word', 'housing',   'out', 100),
      ('yello',                'counterparty_or_purpose', 'word', 'housing',   'out', 100),
      ('lichtblick',           'counterparty_or_purpose', 'word', 'housing',   'out', 100),
      ('naturstrom',           'counterparty_or_purpose', 'word', 'housing',   'out', 100),
      ('polarstern',           'counterparty_or_purpose', 'word', 'housing',   'out', 100),
      ('tibber',               'counterparty_or_purpose', 'word', 'housing',   'out', 100),
      ('octopus energy',       'counterparty_or_purpose', 'word', 'housing',   'out', 100),
      -- Versicherungen
      ('allianz',              'counterparty_or_purpose', 'word', 'insurance', 'out', 100),
      ('huk coburg',           'counterparty_or_purpose', 'word', 'insurance', 'out', 100),
      ('huk24',                'counterparty_or_purpose', 'word', 'insurance', 'out', 100),
      ('ergo',                 'counterparty_or_purpose', 'word', 'insurance', 'out', 100),
      ('axa',                  'counterparty_or_purpose', 'word', 'insurance', 'out', 100),
      ('generali',             'counterparty_or_purpose', 'word', 'insurance', 'out', 100),
      ('debeka',               'counterparty_or_purpose', 'word', 'insurance', 'out', 100),
      ('devk',                 'counterparty_or_purpose', 'word', 'insurance', 'out', 100),
      ('signal iduna',         'counterparty_or_purpose', 'word', 'insurance', 'out', 100),
      ('r+v',                  'counterparty_or_purpose', 'word', 'insurance', 'out', 100),
      ('gothaer',              'counterparty_or_purpose', 'word', 'insurance', 'out', 100),
      ('hansemerkur',          'counterparty_or_purpose', 'word', 'insurance', 'out', 100),
      ('provinzial',           'counterparty_or_purpose', 'word', 'insurance', 'out', 100),
      ('lvm',                  'counterparty_or_purpose', 'word', 'insurance', 'out', 100),
      ('wuerttembergische',    'counterparty_or_purpose', 'word', 'insurance', 'out', 100),
      ('barmenia',             'counterparty_or_purpose', 'word', 'insurance', 'out', 100),
      ('continentale',         'counterparty_or_purpose', 'word', 'insurance', 'out', 100),
      ('arag',                 'counterparty_or_purpose', 'word', 'insurance', 'out', 100),
      ('cosmosdirekt',         'counterparty_or_purpose', 'word', 'insurance', 'out', 100),
      -- Gesundheit (Krankenkassen, Versandapotheken, Optiker)
      ('techniker krankenkasse','counterparty_or_purpose','word', 'health',    'out', 100),
      ('aok',                  'counterparty_or_purpose', 'word', 'health',    'out', 100),
      ('barmer',               'counterparty_or_purpose', 'word', 'health',    'out', 100),
      ('dak gesundheit',       'counterparty_or_purpose', 'word', 'health',    'out', 100),
      ('ikk',                  'counterparty_or_purpose', 'word', 'health',    'out', 100),
      ('hkk',                  'counterparty_or_purpose', 'word', 'health',    'out', 100),
      ('kkh',                  'counterparty_or_purpose', 'word', 'health',    'out', 100),
      ('bkk',                  'counterparty_or_purpose', 'word', 'health',    'out', 100),
      ('docmorris',            'counterparty_or_purpose', 'word', 'health',    'out', 100),
      ('shop apotheke',        'counterparty_or_purpose', 'word', 'health',    'out', 100),
      ('fielmann',             'counterparty_or_purpose', 'word', 'health',    'out', 100),
      ('apollo optik',         'counterparty_or_purpose', 'word', 'health',    'out', 100),
      -- Freizeit, Reisen, Essen bestellen, Sport
      ('urban sports',         'counterparty_or_purpose', 'word', 'leisure_travel', 'out', 100),
      ('mcfit',                'counterparty_or_purpose', 'word', 'leisure_travel', 'out', 100),
      ('fitx',                 'counterparty_or_purpose', 'word', 'leisure_travel', 'out', 100),
      ('clever fit',           'counterparty_or_purpose', 'word', 'leisure_travel', 'out', 100),
      ('lieferando',           'counterparty_or_purpose', 'word', 'leisure_travel', 'out', 100),
      ('wolt',                 'counterparty_or_purpose', 'word', 'leisure_travel', 'out', 100),
      ('lufthansa',            'counterparty_or_purpose', 'word', 'leisure_travel', 'out', 100),
      ('eurowings',            'counterparty_or_purpose', 'word', 'leisure_travel', 'out', 100),
      ('condor',               'counterparty_or_purpose', 'word', 'leisure_travel', 'out', 100),
      ('tui',                  'counterparty_or_purpose', 'word', 'leisure_travel', 'out', 100),
      ('booking.com',          'counterparty_or_purpose', 'word', 'leisure_travel', 'out', 100),
      ('cinemaxx',             'counterparty_or_purpose', 'word', 'leisure_travel', 'out', 100),
      ('uci kinowelt',         'counterparty_or_purpose', 'word', 'leisure_travel', 'out', 100),
      ('eventim',              'counterparty_or_purpose', 'word', 'leisure_travel', 'out', 100),
      -- Shopping
      ('zalando',              'counterparty_or_purpose', 'word', 'shopping',  'out', 100),
      ('otto gmbh',            'counterparty_or_purpose', 'word', 'shopping',  'out', 100),
      ('otto.de',              'counterparty_or_purpose', 'word', 'shopping',  'out', 100),
      ('amazon',               'counterparty_or_purpose', 'word', 'shopping',  'out', 100),
      ('ebay',                 'counterparty_or_purpose', 'word', 'shopping',  'out', 100),
      ('about you',            'counterparty_or_purpose', 'word', 'shopping',  'out', 100),
      ('ikea',                 'counterparty_or_purpose', 'word', 'shopping',  'out', 100),
      ('mediamarkt',           'counterparty_or_purpose', 'word', 'shopping',  'out', 100),
      ('media markt',          'counterparty_or_purpose', 'word', 'shopping',  'out', 100),
      ('saturn',               'counterparty_or_purpose', 'word', 'shopping',  'out', 100),
      ('h&m',                  'counterparty_or_purpose', 'word', 'shopping',  'out', 100),
      ('c&a',                  'counterparty_or_purpose', 'word', 'shopping',  'out', 100),
      ('decathlon',            'counterparty_or_purpose', 'word', 'shopping',  'out', 100),
      ('tchibo',               'counterparty_or_purpose', 'word', 'shopping',  'out', 100),
      ('obi',                  'counterparty_or_purpose', 'word', 'shopping',  'out', 100),
      ('hornbach',             'counterparty_or_purpose', 'word', 'shopping',  'out', 100),
      ('bauhaus',              'counterparty_or_purpose', 'word', 'shopping',  'out', 100),
      ('toom',                 'counterparty_or_purpose', 'word', 'shopping',  'out', 100),
      ('douglas',              'counterparty_or_purpose', 'word', 'shopping',  'out', 100),
      ('thalia',               'counterparty_or_purpose', 'word', 'shopping',  'out', 100),
      ('hugendubel',           'counterparty_or_purpose', 'word', 'shopping',  'out', 100),
      ('deichmann',            'counterparty_or_purpose', 'word', 'shopping',  'out', 100),
      ('galeria',              'counterparty_or_purpose', 'word', 'shopping',  'out', 100),
      ('kik',                  'counterparty_or_purpose', 'word', 'shopping',  'out', 100),
      ('tedi',                 'counterparty_or_purpose', 'word', 'shopping',  'out', 100),
      ('notebooksbilliger',    'counterparty_or_purpose', 'word', 'shopping',  'out', 100),
      ('cyberport',            'counterparty_or_purpose', 'word', 'shopping',  'out', 100),
      ('conrad electronic',    'counterparty_or_purpose', 'word', 'shopping',  'out', 100),
      -- Bildung
      ('volkshochschule',      'counterparty_or_purpose', 'word', 'education', 'out', 100),
      ('vhs',                  'counterparty_or_purpose', 'word', 'education', 'out', 100),
      ('studierendenwerk',     'counterparty_or_purpose', 'word', 'education', 'out', 100),
      ('studentenwerk',        'counterparty_or_purpose', 'word', 'education', 'out', 100),
      -- Steuern
      ('finanzamt',            'counterparty_or_purpose', 'word', 'taxes',     'out', 100),
      ('bundeskasse',          'counterparty_or_purpose', 'word', 'taxes',     'out', 100),
      -- Kapitalertragsteuer und Kapitalerträge (eindeutige Bankbegriffe,
      -- oft nur im Transaktionstyp)
      ('kapitalertragsteuer',  'any_text', 'word', 'capital_gains_tax', 'out', 100),
      ('kapitalertragssteuer', 'any_text', 'word', 'capital_gains_tax', 'out', 100),
      ('abgeltungsteuer',      'any_text', 'word', 'capital_gains_tax', 'out', 100),
      ('abgeltungssteuer',     'any_text', 'word', 'capital_gains_tax', 'out', 100),
      ('solidaritaetszuschlag','any_text', 'word', 'capital_gains_tax', 'out', 100),
      ('steuerabrechnung',     'any_text', 'word', 'capital_gains_tax', 'out', 100),
      ('zinszahlung',          'any_text', 'word', 'investment_income', 'in',  100),
      ('zinsgutschrift',       'any_text', 'word', 'investment_income', 'in',  100),
      ('habenzinsen',          'any_text', 'word', 'investment_income', 'in',  100),
      ('dividende',            'any_text', 'word', 'investment_income', 'in',  100),
      ('ertragsgutschrift',    'any_text', 'word', 'investment_income', 'in',  100),
      ('ausschuettung',        'any_text', 'word', 'investment_income', 'in',  100),
      -- Einnahmen
      ('familienkasse',        'counterparty_or_purpose', 'word', 'other_income', 'in', 100),
      -- Sparen und Investieren (Broker)
      ('trade republic',       'counterparty_or_purpose', 'word', 'savings_investments', 'out', 100),
      ('scalable capital',     'counterparty_or_purpose', 'word', 'savings_investments', 'out', 100),
      ('smartbroker',          'counterparty_or_purpose', 'word', 'savings_investments', 'out', 100),
      ('bitpanda',             'counterparty_or_purpose', 'word', 'savings_investments', 'out', 100),
      -- Bargeld und Bankentgelte (eindeutige Buchungsarten)
      ('bargeldauszahlung',    'any_text', 'word', 'transfer',       'out', 100),
      ('geldautomat',          'any_text', 'word', 'transfer',       'out', 100),
      ('kontofuehrungsentgelt','any_text', 'word', 'other_expenses', 'out', 100),
      ('kontofuehrung',        'any_text', 'word', 'other_expenses', 'out', 100),
      ('sollzinsen',           'any_text', 'word', 'other_expenses', 'out', 100),
      -- Reisen vor der Kartenkategorie „Transport“ (PDF-Import)
      ('corendon',             'counterparty_or_purpose', 'word', 'leisure_travel', 'out', 100),
      ('mietwagen',            'counterparty_or_purpose', 'word', 'leisure_travel', 'out', 100),
      -- Mieteinnahmen: Gutschrift mit „Miete“ im Verwendungszweck
      ('miete',                'purpose',                 'word', 'rental_income',  'in',  100)
    ) as t (pattern, field, type, key, dir, prio);
$$;

-- Bestehende Nutzer mit Standardregeln abgleichen.
do $$
declare
  v_user uuid;
begin
  for v_user in
    select distinct r.user_id from public.categorization_rules r where r.origin = 'standard'
  loop
    perform private.sync_standard_rules(v_user);
  end loop;
end;
$$;

-- ---------------------------------------------------------------------
-- 5. Import: gemeinsamer Kern
-- ---------------------------------------------------------------------
-- Arbeitstabelle eines Imports (je Konto), neu angelegt bei jedem Aufruf
-- (Mehrfachaufruf in einer Transaktion: Vorschau + Import, Tests,
-- mehrere Abschnitte eines Auszugs).
create function private.import_batch_prepare()
returns void
language plpgsql
volatile
set search_path = ''
as $$
begin
  if to_regclass('pg_temp.import_batch') is not null then
    drop table pg_temp.import_batch;
  end if;
  create temporary table import_batch (
    ord integer, booking_date date, value_date date, amount numeric(14,2), currency public.currency_code,
    counterparty text, purpose text, transaction_type text, counterparty_iban text, description text,
    mandate_reference text, creditor_id text, import_hash text, category_id uuid, rule_id uuid,
    source public.categorization_source, duplicate boolean not null default false,
    probable boolean not null default false, existing_id uuid, enrich boolean not null default false,
    existing_uncategorized boolean not null default false
  ) on commit drop;
end;
$$;

-- pg_temp.import_batch in ein Konto übernehmen:
--  1. Duplikate (gleicher Schlüssel im Konto); vorhandene Buchungen
--     erhalten fehlende Felder (Anreichern), vorhandene Werte bleiben.
--  2. p_check_foreign: „vermutlich vorhanden“ – je Datum und Betrag so
--     viele neue Zeilen, wie das Konto Buchungen aus anderen Quellen hat
--     (z. B. manuell erfasst oder per CSV importiert), werden übersprungen.
--  3. Kategorie nach Schichten (private.classify) für neue Zeilen und
--     angereicherte Buchungen ohne Kategorie.
--  4. Schreiben (außer p_dry_run).
-- p_account_id NULL: neues Konto in der Vorschau (alles neu).
create function private.import_batch_run(
  p_user_id       uuid,
  p_account_id    uuid,
  p_source        public.transaction_source,
  p_dry_run       boolean,
  p_check_foreign boolean
)
returns table (new_rows integer, duplicates integer, probable integer, categorized integer, enriched integer)
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_new        integer;
  v_duplicates integer;
  v_probable   integer;
  v_categorized integer;
  v_enriched   integer;
begin
  update pg_temp.import_batch b
     set duplicate = true,
         existing_id = t.id,
         enrich = (t.transaction_type is null and b.transaction_type is not null)
               or (t.counterparty_iban is null and b.counterparty_iban is not null)
               or (t.description is null and b.description is not null)
               or (t.mandate_reference is null and b.mandate_reference is not null)
               or (t.creditor_id is null and b.creditor_id is not null),
         existing_uncategorized = t.category_id is null
    from public.transactions t
   where p_account_id is not null
     and t.account_id = p_account_id
     and t.import_hash = b.import_hash;

  if p_check_foreign and p_account_id is not null then
    with fresh as (
      select b.ctid as row_id, b.booking_date, b.amount,
             row_number() over (partition by b.booking_date, b.amount order by b.ord) as n
        from pg_temp.import_batch b
       where not b.duplicate
    ),
    foreign_rows as (
      select t.booking_date, t.amount, count(*) as cnt
        from public.transactions t
       where t.account_id = p_account_id
         and t.source is distinct from p_source
         and exists (select 1 from fresh f where f.booking_date = t.booking_date and f.amount = t.amount)
       group by t.booking_date, t.amount
    )
    update pg_temp.import_batch b
       set probable = true
      from fresh f
      join foreign_rows x on x.booking_date = f.booking_date and x.amount = f.amount and f.n <= x.cnt
     where b.ctid = f.row_id;
  end if;

  update pg_temp.import_batch b
     set category_id = c.category_id, rule_id = c.rule_id, source = c.source
    from pg_temp.import_batch s
    cross join lateral private.classify(p_user_id, p_account_id, s.amount, s.counterparty, s.purpose,
                                        s.description, s.transaction_type, s.counterparty_iban,
                                        private.counterparty_key(s.counterparty_iban, s.counterparty, s.purpose)) c
   where s.ctid = b.ctid
     and ((not b.duplicate and not b.probable) or (b.enrich and b.existing_uncategorized));

  select count(*) filter (where not b.duplicate and not b.probable),
         count(*) filter (where b.duplicate),
         count(*) filter (where b.probable),
         count(*) filter (where b.category_id is not null),
         count(*) filter (where b.enrich)
    into v_new, v_duplicates, v_probable, v_categorized, v_enriched
    from pg_temp.import_batch b;

  if not p_dry_run then
    insert into public.transactions (
      user_id, account_id, booking_date, value_date, amount, currency,
      counterparty_name, purpose, transaction_type, counterparty_iban, description,
      mandate_reference, creditor_id, import_hash, source, category_id, categorization_source, categorization_rule_id,
      auto_category_id, auto_source, auto_rule_id
    )
    select p_user_id, p_account_id, b.booking_date, b.value_date, b.amount, b.currency,
           b.counterparty, b.purpose, b.transaction_type, b.counterparty_iban, b.description,
           b.mandate_reference, b.creditor_id, b.import_hash, p_source, b.category_id, b.source, b.rule_id,
           b.category_id, b.source, b.rule_id
      from pg_temp.import_batch b
     where not b.duplicate and not b.probable
     order by b.ord
    on conflict (account_id, import_hash) where import_hash is not null do nothing;
    get diagnostics v_new = row_count;

    update public.transactions t
       set transaction_type       = coalesce(t.transaction_type, b.transaction_type),
           counterparty_iban      = coalesce(t.counterparty_iban, b.counterparty_iban),
           description            = coalesce(t.description, b.description),
           mandate_reference      = coalesce(t.mandate_reference, b.mandate_reference),
           creditor_id            = coalesce(t.creditor_id, b.creditor_id),
           category_id            = coalesce(t.category_id, b.category_id),
           categorization_source  = case when t.category_id is null and b.category_id is not null
                                         then b.source
                                         else t.categorization_source end,
           categorization_rule_id = case when t.category_id is null and b.category_id is not null
                                         then b.rule_id
                                         else t.categorization_rule_id end,
           auto_category_id       = case when t.category_id is null and t.auto_category_id is null
                                         then b.category_id else t.auto_category_id end,
           auto_source            = case when t.category_id is null and t.auto_category_id is null
                                         then b.source else t.auto_source end,
           auto_rule_id           = case when t.category_id is null and t.auto_category_id is null
                                         then b.rule_id else t.auto_rule_id end
      from pg_temp.import_batch b
     where b.enrich
       and t.id = b.existing_id
       and t.user_id = p_user_id;
    get diagnostics v_enriched = row_count;
  end if;

  return query select v_new, v_duplicates, v_probable, v_categorized, v_enriched;
end;
$$;

comment on function private.import_batch_run(uuid, uuid, public.transaction_source, boolean, boolean) is
  'Gemeinsamer Kern von import_transactions (CSV) und import_statement (PDF): Duplikate, „vermutlich '
  'vorhanden“ (p_check_foreign), Kategorie nach Schichten, Schreiben. Arbeitet auf pg_temp.import_batch.';

-- CSV-/Excel-Import (Schnittstelle unverändert): Schlüssel Datum + Betrag
-- + Verwendungszweck + laufende Nummer gleicher Buchungen in der Datei.
create or replace function public.import_transactions(
  p_account_id           uuid,
  p_rows                 jsonb,
  p_dry_run              boolean default false,
  p_new_account_name     text    default null,
  p_new_account_currency text    default null
)
returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_uid         uuid := auth.uid();
  v_account_id  uuid;
  v_currency    public.currency_code;
  v_provider    public.account_provider;
  v_total       integer;
  v_run         record;
  v_learned     integer := 0;
  v_suggested   integer := 0;
  v_balance     numeric;
  v_name        text := btrim(p_new_account_name);
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' then
    raise exception 'invalid_rows' using errcode = '22023';
  end if;
  v_total := jsonb_array_length(p_rows);
  if v_total = 0 then
    raise exception 'no_rows' using errcode = '22023';
  end if;
  if v_total > 5000 then
    raise exception 'too_many_rows' using errcode = '22023';
  end if;

  if p_account_id is not null then
    select a.id, a.currency, a.provider into v_account_id, v_currency, v_provider
      from public.accounts a
     where a.id = p_account_id and a.user_id = v_uid and a.archived_at is null;
    if not found then
      raise exception 'account_not_found' using errcode = 'P0002';
    end if;
    if v_provider not in ('manual', 'csv') then
      raise exception 'account_not_importable' using errcode = '22023';
    end if;
  else
    if v_name is null or char_length(v_name) not between 1 and 120 then
      raise exception 'invalid_account_name' using errcode = '22023';
    end if;
    begin
      v_currency := coalesce(p_new_account_currency, 'EUR')::public.currency_code;
    exception when others then
      raise exception 'invalid_currency' using errcode = '22023';
    end;
    if not p_dry_run then
      insert into public.accounts (user_id, name, type, provider, currency)
      values (v_uid, v_name, 'checking', 'csv', v_currency)
      returning id into v_account_id;
    end if;
  end if;

  perform private.import_batch_prepare();
  insert into pg_temp.import_batch (ord, booking_date, value_date, amount, currency, counterparty, purpose,
                                    transaction_type, counterparty_iban, description, mandate_reference,
                                    creditor_id, import_hash)
  select r.ord, r.booking_date, r.value_date, r.amount, r.currency, r.counterparty, r.purpose,
         r.transaction_type, r.counterparty_iban, r.description, r.mandate_reference, r.creditor_id,
         private.import_hash(r.booking_date, r.amount, r.purpose,
           row_number() over (
             partition by r.booking_date, r.amount, btrim(regexp_replace(lower(coalesce(r.purpose, '')), '\s+', ' ', 'g'))
             order by r.ord))
    from private.import_rows(p_rows, v_currency) r;

  select * into v_run from private.import_batch_run(v_uid, v_account_id, 'csv_import', p_dry_run, false);

  if not p_dry_run then
    perform private.refresh_recurrence(v_uid);
    -- Schicht 6: Klassifikator für alles, was noch offen ist.
    select b.assigned, b.suggested into v_learned, v_suggested from private.bayes_run(v_uid, true) b;
  end if;

  select a.balance into v_balance from public.accounts a where a.id = v_account_id;

  return jsonb_build_object(
    'account_id',  v_account_id,
    'currency',    v_currency,
    'total',       v_total,
    'new',         v_run.new_rows,
    'duplicates',  v_run.duplicates,
    'categorized', v_run.categorized,
    'enriched',    v_run.enriched,
    'learned',     v_learned,
    'suggested',   v_suggested,
    'balance',     v_balance,
    'dry_run',     p_dry_run
  );
end;
$$;

-- ---------------------------------------------------------------------
-- PDF-Kontoauszug mit mehreren Konten (Hauptkonto, Spaces)
-- ---------------------------------------------------------------------
-- p_sections: [{ iban, account_id | null, new_account_name, institution,
--                opening, closing, period_from, period_to, rows: [...] }]
-- rows wie bei import_transactions. Alle Abschnitte in einer Transaktion;
-- jede Prüfung bricht den ganzen Import ab.
create function public.import_statement(p_sections jsonb, p_dry_run boolean default false)
returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_uid         uuid := auth.uid();
  v_section     record;
  v_account     record;
  v_run         record;
  v_ibans       text[];
  v_targets     uuid[] := '{}';
  v_transfer    uuid;
  v_rule_id     uuid;
  v_new_rules   uuid[] := '{}';
  v_own_missing integer;
  v_result      jsonb := '[]'::jsonb;
  v_account_id  uuid;
  v_account_name text;
  v_new_account boolean;
  v_opening_set boolean;
  v_opening     numeric;
  v_balance     numeric;
  v_internal    integer;
  v_learned     integer := 0;
  v_suggested   integer := 0;
  v_total       integer := 0;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if p_sections is null or jsonb_typeof(p_sections) <> 'array' or jsonb_array_length(p_sections) = 0 then
    raise exception 'invalid_sections' using errcode = '22023';
  end if;
  if jsonb_array_length(p_sections) > 50 then
    raise exception 'too_many_sections' using errcode = '22023';
  end if;

  -- Abschnitte lesen und prüfen
  if to_regclass('pg_temp.statement_sections') is not null then
    drop table pg_temp.statement_sections;
  end if;
  create temporary table statement_sections (
    idx integer, iban text, account_id uuid, new_name text, institution text,
    opening numeric(14,2), closing numeric(14,2), period_from date, period_to date, rows jsonb
  ) on commit drop;

  begin
    insert into pg_temp.statement_sections
    select e.ordinality::integer,
           upper(regexp_replace(coalesce(e.value ->> 'iban', ''), '\s', '', 'g')),
           nullif(e.value ->> 'account_id', '')::uuid,
           nullif(btrim(e.value ->> 'new_account_name'), ''),
           nullif(btrim(e.value ->> 'institution'), ''),
           (e.value ->> 'opening')::numeric,
           (e.value ->> 'closing')::numeric,
           (e.value ->> 'period_from')::date,
           (e.value ->> 'period_to')::date,
           e.value -> 'rows'
      from jsonb_array_elements(p_sections) with ordinality as e;
  exception when others then
    raise exception 'invalid_section' using errcode = '22023';
  end;

  for v_section in select * from pg_temp.statement_sections s order by s.idx loop
    if v_section.iban !~ '^[A-Z]{2}[0-9]{2}[0-9A-Z]{11,30}$'
       or v_section.opening is null or v_section.closing is null
       or v_section.period_from is null or v_section.period_to is null
       or v_section.period_from > v_section.period_to
       or v_section.rows is null or jsonb_typeof(v_section.rows) <> 'array'
       or char_length(v_section.institution) > 120 then
      raise exception 'invalid_section' using errcode = '22023', detail = v_section.idx::text;
    end if;
    v_total := v_total + jsonb_array_length(v_section.rows);
  end loop;
  if v_total > 5000 then
    raise exception 'too_many_rows' using errcode = '22023';
  end if;
  if (select count(distinct s.iban) from pg_temp.statement_sections s) <> (select count(*) from pg_temp.statement_sections) then
    raise exception 'duplicate_section' using errcode = '22023';
  end if;
  select array_agg(s.iban order by s.idx) into v_ibans from pg_temp.statement_sections s;

  -- Saldenprüfung je Abschnitt (Zeilen erst hier vollständig geprüft)
  for v_section in select * from pg_temp.statement_sections s order by s.idx loop
    if v_section.opening + coalesce((select sum(r.amount) from private.import_rows(v_section.rows, 'EUR') r), 0)
       <> v_section.closing then
      raise exception 'balance_mismatch' using errcode = '22023', detail = v_section.iban;
    end if;
  end loop;

  -- Zielkonten prüfen
  for v_section in select * from pg_temp.statement_sections s order by s.idx loop
    if v_section.account_id is not null then
      select a.id, a.iban, a.provider into v_account
        from public.accounts a
       where a.id = v_section.account_id and a.user_id = v_uid and a.archived_at is null;
      if not found then
        raise exception 'account_not_found' using errcode = 'P0002', detail = v_section.iban;
      end if;
      if v_account.provider not in ('manual', 'csv') then
        raise exception 'account_not_importable' using errcode = '22023', detail = v_section.iban;
      end if;
      if v_account.iban is not null and v_account.iban <> v_section.iban then
        raise exception 'iban_mismatch' using errcode = '22023', detail = v_section.iban;
      end if;
      if v_section.account_id = any (v_targets) then
        raise exception 'duplicate_target' using errcode = '22023', detail = v_section.iban;
      end if;
      v_targets := v_targets || v_section.account_id;
    elsif v_section.new_name is null or char_length(v_section.new_name) > 120 then
      raise exception 'invalid_account_name' using errcode = '22023', detail = v_section.iban;
    end if;
    if exists (
      select 1 from public.accounts a
       where a.user_id = v_uid and a.iban = v_section.iban and a.id is distinct from v_section.account_id
    ) then
      raise exception 'iban_in_use' using errcode = '23505', detail = v_section.iban;
    end if;
  end loop;

  -- IBANs der Abschnitte als eigene Konten (Zielkategorie Umbuchung)
  select c.id into v_transfer from public.categories c where c.user_id = v_uid and c.default_key = 'transfer';
  select count(*) into v_own_missing
    from unnest(v_ibans) i (iban)
   where not exists (
     select 1 from public.categorization_rules r
      where r.user_id = v_uid and r.origin = 'own_account' and r.match_field = 'counterparty_iban'
        and upper(r.pattern) = i.iban
   );
  if v_transfer is null then
    v_own_missing := 0;
  elsif not p_dry_run then
    for v_section in select * from pg_temp.statement_sections s order by s.idx loop
      if not exists (
        select 1 from public.categorization_rules r
         where r.user_id = v_uid and r.origin = 'own_account' and r.match_field = 'counterparty_iban'
           and upper(r.pattern) = v_section.iban
      ) then
        insert into public.categorization_rules (user_id, category_id, pattern, match_type, match_field, priority, origin)
        values (v_uid, v_transfer, v_section.iban, 'equals', 'counterparty_iban', 100, 'own_account')
        returning id into v_rule_id;
        v_new_rules := v_new_rules || v_rule_id;
      end if;
    end loop;
  end if;

  -- Abschnitte importieren
  for v_section in select * from pg_temp.statement_sections s order by s.idx loop
    v_account_id := v_section.account_id;
    v_new_account := v_account_id is null;
    if v_new_account and not p_dry_run then
      insert into public.accounts (user_id, name, type, provider, currency, institution_name, iban, iban_last4,
                                   opening_balance)
      values (v_uid, v_section.new_name, 'checking', 'csv', 'EUR', v_section.institution, v_section.iban,
              right(v_section.iban, 4), v_section.opening)
      returning id into v_account_id;
    elsif not v_new_account and not p_dry_run then
      update public.accounts a
         set iban = v_section.iban, iban_last4 = right(v_section.iban, 4)
       where a.id = v_account_id and a.iban is null;
    end if;

    perform private.import_batch_prepare();
    insert into pg_temp.import_batch (ord, booking_date, value_date, amount, currency, counterparty, purpose,
                                      transaction_type, counterparty_iban, description, mandate_reference,
                                      creditor_id, import_hash)
    select r.ord, r.booking_date, r.value_date, r.amount, r.currency, r.counterparty, r.purpose,
           r.transaction_type, r.counterparty_iban, r.description, r.mandate_reference, r.creditor_id,
           private.import_hash(r.booking_date, r.amount, concat_ws(' | ', r.counterparty, r.purpose),
             row_number() over (
               partition by r.booking_date, r.amount,
                            btrim(regexp_replace(lower(concat_ws(' | ', r.counterparty, r.purpose)), '\s+', ' ', 'g'))
               order by r.ord))
      from private.import_rows(v_section.rows, 'EUR') r;

    select * into v_run from private.import_batch_run(v_uid, v_account_id, 'pdf_import', p_dry_run, true);

    -- Vorschau: Umbuchungen zwischen den Konten des Auszugs gelten als
    -- zugeordnet (die Regeln für die eigenen IBANs entstehen erst beim Import).
    v_internal := 0;
    if p_dry_run and v_transfer is not null then
      select count(*) into v_internal
        from pg_temp.import_batch b
       where not b.duplicate and not b.probable and b.category_id is null
         and b.counterparty_iban = any (v_ibans);
    end if;

    -- Anfangsbestand: Ist dies der früheste Auszug des Kontos, gilt sein
    -- alter Kontostand (auch beim Nachimport eines früheren Monats).
    v_opening_set := false;
    if v_new_account then
      v_opening := v_section.opening;
      v_opening_set := true;
    else
      select a.opening_balance into v_opening from public.accounts a where a.id = v_account_id;
      if not exists (
        select 1 from public.transactions t
         where t.account_id = v_account_id and t.booking_date < v_section.period_from
      ) and v_opening is distinct from v_section.opening then
        v_opening := v_section.opening;
        v_opening_set := true;
        if not p_dry_run then
          update public.accounts a set opening_balance = v_section.opening where a.id = v_account_id;
        end if;
      end if;
    end if;

    -- Kontostand der App zum Ende des Auszugs (Vorschau: hochgerechnet)
    v_balance := v_opening
      + coalesce((select sum(t.amount)
                    from public.transactions t
                    join public.accounts a on a.id = t.account_id
                   where t.account_id = v_account_id
                     and t.currency = a.currency
                     and t.booking_date <= v_section.period_to), 0)
      + case when p_dry_run
             then coalesce((select sum(b.amount) from pg_temp.import_batch b
                             where not b.duplicate and not b.probable and b.booking_date <= v_section.period_to), 0)
             else 0 end;

    v_account_name := null;
    select a.name into v_account_name from public.accounts a where a.id = v_account_id;

    v_result := v_result || jsonb_build_object(
      'iban',          v_section.iban,
      'account_id',    v_account_id,
      'account_name',  coalesce(v_account_name, v_section.new_name),
      'new_account',   v_new_account,
      'total',         jsonb_array_length(v_section.rows),
      'new',           v_run.new_rows,
      'duplicates',    v_run.duplicates,
      'probable',      v_run.probable,
      'probable_rows', coalesce((
        select jsonb_agg(jsonb_build_object('booking_date', b.booking_date, 'amount', b.amount,
                                            'counterparty', b.counterparty) order by b.ord)
          from (select * from pg_temp.import_batch b where b.probable order by b.ord limit 20) b), '[]'::jsonb),
      'categorized',   v_run.categorized + v_internal,
      'enriched',      v_run.enriched,
      'opening_set',   v_opening_set,
      'closing',       v_section.closing,
      'balance',       v_balance
    );
  end loop;

  if not p_dry_run then
    -- Neue eigene IBANs auch auf vorhandene Buchungen anwenden (z. B. die
    -- Gegenseite auf einem anderen Konto).
    foreach v_rule_id in array v_new_rules loop
      perform private.apply_rules_for_user(v_uid, v_rule_id, false, true);
    end loop;
    perform private.refresh_recurrence(v_uid);
    select b.assigned, b.suggested into v_learned, v_suggested from private.bayes_run(v_uid, true) b;
  end if;

  return jsonb_build_object(
    'sections',       v_result,
    'own_ibans_added', case when p_dry_run then v_own_missing else coalesce(array_length(v_new_rules, 1), 0) end,
    'learned',        v_learned,
    'suggested',      v_suggested,
    'dry_run',        p_dry_run
  );
end;
$$;

comment on function public.import_statement(jsonb, boolean) is
  'PDF-Kontoauszug (mehrere Konten) in einer Transaktion importieren: Saldenprüfung je Abschnitt, Zielkonto per '
  'account_id oder neu (mit IBAN und Anfangsbestand), Duplikate (Datum, Betrag, Gegenpartei, Zweck, laufende '
  'Nummer), „vermutlich vorhanden“ (gleiche Buchung aus anderer Quelle), IBANs als eigene Konten. Fehler: '
  'invalid_sections, invalid_section, too_many_sections, too_many_rows, duplicate_section, balance_mismatch, '
  'account_not_importable, iban_mismatch, duplicate_target, invalid_account_name, invalid_row (22023), '
  'account_not_found (P0002), iban_in_use (23505); DETAIL nennt die IBAN bzw. den Abschnitt.';

-- ---------------------------------------------------------------------
-- Rechte
-- ---------------------------------------------------------------------
revoke all on function private.bank_category_templates()                       from public, anon;
revoke all on function private.seed_bank_category_rules(uuid)                  from public, anon;
revoke all on function private.import_batch_prepare()                          from public, anon;
revoke all on function private.import_batch_run(uuid, uuid, public.transaction_source, boolean, boolean)
  from public, anon;
revoke all on function public.add_bank_category_rule(text, uuid)               from public, anon;
revoke all on function public.set_bank_category_rule(uuid, uuid)               from public, anon;
revoke all on function public.import_statement(jsonb, boolean)                 from public, anon;
grant execute on function private.bank_category_templates()                    to authenticated;
grant execute on function private.seed_bank_category_rules(uuid)               to authenticated;
grant execute on function private.import_batch_prepare()                       to authenticated;
grant execute on function private.import_batch_run(uuid, uuid, public.transaction_source, boolean, boolean)
  to authenticated;
grant execute on function public.add_bank_category_rule(text, uuid)            to authenticated;
grant execute on function public.set_bank_category_rule(uuid, uuid)            to authenticated;
grant execute on function public.import_statement(jsonb, boolean)              to authenticated;

commit;
