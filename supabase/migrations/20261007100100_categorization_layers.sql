-- =====================================================================
--  20261007100100_categorization_layers.sql
--
--  Kategorisierung in Schichten (PR A: Schichten 1–4):
--
--    1. Manuelle Zuordnungen werden nie überschrieben: Regeln wirken nur auf
--       Buchungen ohne Kategorie; Zurücksetzen betrifft nur maschinell
--       vergebene (categorization_source = 'rule').
--    2. Eigene Regeln (origin manual/learned) vor …
--    3. … dem Standard-Regelset (origin standard, per „Standardregeln
--       laden“ übernommen, einzeln löschbar; Priorität bleibt 100).
--    4. Regeln auf weitere Felder: Transaktionstyp, Gegenkonto-IBAN,
--       Beschreibung, beliebiger Text; Typ „ganzes Wort“; Richtung über
--       amount_min/amount_max (nur Eingänge/Ausgänge).
--
--  Dazu:
--  - transactions: transaction_type, counterparty_iban, description (aus dem
--    Import) und categorization_rule_id („Warum diese Kategorie?“).
--  - Normalisierung faltet Umlaute (ä→ae …), damit „Müller“ = „Mueller“.
--  - Gelernte Regeln lauten nie auf Zahlungsvermittler (PayPal, Klarna …);
--    der Händler kommt dann aus dem Verwendungszweck. Sonst gilt der
--    Empfänger vor dem Verwendungszweck („Einkauf“ ist kein Händler), außer
--    der Zweck nennt dieselbe Marke genauer („amazon prime“).
--  - Eigene Regeln werden ohne die Standardregeln sortiert.
--  - apply_categorization_rules(): rückwirkend auf unkategorisierte
--    Buchungen (alle Regeln oder eine bestimmte, auch als Zählung).
--  - reset_machine_categorization(), categorization_stats().
--  - Neue Standardkategorie „Kapitalertragsteuer“ (Ausgabe, Needs) und
--    Nachtrag für bestehende Nutzer, inkl. „Kapitalerträge“ falls fehlend.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. Spalten
-- ---------------------------------------------------------------------
alter table public.transactions
  add column transaction_type     text check (char_length(transaction_type) <= 100),
  add column counterparty_iban    text check (counterparty_iban ~ '^[A-Z]{2}[0-9]{2}[0-9A-Z]{11,30}$'),
  add column description          text check (char_length(description) <= 1000),
  add column categorization_rule_id uuid;

-- Regel und Buchung gehören demselben Nutzer (wie bei Kategorien).
alter table public.categorization_rules
  add constraint categorization_rules_id_user_id_key unique (id, user_id);
alter table public.transactions
  add constraint transactions_categorization_rule_fkey
    foreign key (categorization_rule_id, user_id)
    references public.categorization_rules (id, user_id)
    on delete set null (categorization_rule_id);

comment on column public.transactions.transaction_type is
  'Transaktionstyp/Buchungsart laut Bank (Umsatztyp, Buchungsart, Vorgang, Buchungstext).';
comment on column public.transactions.counterparty_iban is 'IBAN des Gegenkontos (Großbuchstaben, ohne Leerzeichen).';
comment on column public.transactions.description is
  'Beschreibung, nur wenn die Bank sie zusätzlich zum Verwendungszweck liefert.';
comment on column public.transactions.categorization_rule_id is
  'Regel, die die Kategorie vergeben hat (categorization_source = rule) – für „Warum diese Kategorie?“.';

create index transactions_categorization_rule_idx
  on public.transactions (categorization_rule_id) where categorization_rule_id is not null;
create index transactions_user_uncategorized_idx
  on public.transactions (user_id) where category_id is null;

alter table public.categorization_rules drop constraint categorization_rules_origin_check;
alter table public.categorization_rules
  add constraint categorization_rules_origin_check check (origin in ('manual', 'learned', 'standard'));
comment on column public.categorization_rules.origin is
  'manual = vom Nutzer angelegt, learned = aus einer Korrektur gelernt, standard = aus dem Standard-Regelset.';

-- ---------------------------------------------------------------------
-- 2. Normalisierung mit Umlaut-Faltung
-- ---------------------------------------------------------------------
create or replace function private.normalize_booking_text(p_text text)
returns text
language sql
immutable
parallel safe
set search_path = ''
as $$
  select btrim(regexp_replace(regexp_replace(regexp_replace(
           replace(replace(replace(replace(lower(coalesce(p_text, '')),
             'ä', 'ae'), 'ö', 'oe'), 'ü', 'ue'), 'ß', 'ss'),
           '[^[:alnum:]&.+@ ]+', ' ', 'g'),   -- Trennzeichen wie * / - , ; zu Leerraum
           '\d{4,}', ' ', 'g'),               -- Karten-/Transaktionsnummern
           '\s+', ' ', 'g'));
$$;

comment on function private.normalize_booking_text(text) is
  'Kleinschreibung, Umlaute ausgeschrieben, Sonderzeichen außer & . + @ zu Leerraum, '
  'Zahlenfolgen ab 4 Ziffern entfernt, Leerraum zusammengefasst.';

-- ---------------------------------------------------------------------
-- 3. Zahlungsvermittler und Händlername
-- ---------------------------------------------------------------------
-- Normalisierte Namen (Wortfolgen). Bei diesen Vermittlern steht der
-- eigentliche Händler im Verwendungszweck.
create or replace function private.is_payment_processor(p_text text)
returns boolean
language sql
immutable
parallel safe
set search_path = ''
as $$
  -- Ganze Wörter; „pp.“ (PayPal-Kürzel) darf direkt weitergehen.
  select (' ' || private.normalize_booking_text(p_text) || ' ') ~ (
    ' (pp\.|(paypal|klarna|sofort|stripe|sumup|apple pay|google pay|amazon payments|adyen|mollie|'
    || 'giropay|paydirekt|unzer|payone|computop|wirecard|zettle|izettle|worldline|nexi|concardis|'
    || 'vr pay|ratepay|afterpay|riverty|mangopay|checkout\.com|paysafe|skrill) )');
$$;

-- Händlerkandidat aus einem Text: vor der ersten Zahlenfolge ab 4 Ziffern,
-- ohne Buchungsart-Präfix, bis zum ersten Wort mit Ziffern (Code).
create or replace function private.merchant_candidate(p_text text)
returns text
language plpgsql
immutable
parallel safe
set search_path = ''
as $$
declare
  v_merchant text;
begin
  v_merchant := private.normalize_booking_text(
    coalesce(substring(coalesce(p_text, '') from '^(.*?)\d{4,}'), coalesce(p_text, '')));
  -- Buchungsart-Präfixe („SEPA-Lastschrift“, „Kartenzahlung“ …) vorn entfernen.
  v_merchant := regexp_replace(v_merchant,
    '^((sepa|lastschrift|basislastschrift|folgelastschrift|erstlastschrift|kartenzahlung|kartenumsatz|'
    || 'ueberweisung|gutschrift|dauerauftrag|einzug|abbuchung|zahlung|visa|mastercard|'
    || 'girocard|debitk|ec|pos|lastschrifteinzug)( |$))+', '');
  -- Führende Wörter bis zum ersten Wort mit Ziffern (Buchungscode wie
  -- „ab12“) – das erste Wort darf Ziffern haben („1&1“, „o2“).
  v_merchant := (
    select string_agg(w.word, ' ' order by w.position)
      from unnest(regexp_split_to_array(v_merchant, ' ')) with ordinality as w (word, position)
     where w.position <= 4
       and w.word <> ''
       and not exists (
         select 1 from unnest(regexp_split_to_array(v_merchant, ' ')) with ordinality as e (word, position)
          where e.position > 1 and e.position <= w.position and e.word ~ '[0-9]'
       )
  );
  v_merchant := btrim(left(coalesce(v_merchant, ''), 60));
  return case when char_length(v_merchant) >= 3 and v_merchant ~ '[[:alpha:]]' then v_merchant end;
end;
$$;

create or replace function private.extract_merchant(p_purpose text, p_counterparty text)
returns text
language plpgsql
immutable
parallel safe
set search_path = ''
as $$
declare
  v_merchant          text;
  v_from_purpose      text;
  v_from_counterparty text;
  v_processor boolean := private.is_payment_processor(p_counterparty)
                         or private.is_payment_processor(left(coalesce(p_purpose, ''), 40));
begin
  -- Zahlungsvermittler: Händler aus dem ganzen Verwendungszweck – ohne
  -- Vermittler, Codes und Füllwörter („Ihr Einkauf bei SPOTIFY“ → spotify).
  if v_processor then
    v_merchant := private.normalize_booking_text(p_purpose);
    -- Wörter ohne Ziffern, mit Buchstaben, ohne Vermittler-/Füllwörter;
    -- Wiederholungen („Zalando … bei Zalando“) nur einmal.
    v_merchant := (
      select string_agg(d.word, ' ' order by d.position)
        from (
          select distinct on (w.word) w.word, w.position
            from unnest(regexp_split_to_array(v_merchant, ' ')) with ordinality as w (word, position)
           where w.word ~ '[[:alpha:]]'
             and w.word !~ '[0-9]'
             and char_length(w.word) > 1
             and w.word !~ '(^|\.)pp(\.|$)'
             and w.word !~ (
               '^(paypal|klarna|sofort|stripe|sumup|apple|google|pay|amazon|payments|adyen|mollie|'
               || 'giropay|paydirekt|unzer|payone|computop|wirecard|zettle|izettle|worldline|nexi|'
               || 'concardis|ratepay|afterpay|riverty|ihr|ihre|einkauf|bei|bestellung|zahlung|kauf|'
               || 'von|an|fuer|bank|europe|s\.a\.r\.l\.?|sarl|s\.c\.a\.?|sca|et|cie|ab|gmbh|ag|se|ltd|inc|bv|nv|'
               || 'sa|sas|co|kg|ug|ohg|ev|mbh|lastschrift|sepa|online|shop|kartenzahlung|kartenumsatz|'
               || 'girocard|debitk|visa|mastercard|ec|pos|ueberweisung|gutschrift)$')
           order by w.word, w.position
        ) d
    );
    v_merchant := array_to_string((regexp_split_to_array(coalesce(v_merchant, ''), ' '))[1:3], ' ');
    v_merchant := btrim(left(v_merchant, 60));
    return case when char_length(v_merchant) >= 3 and v_merchant ~ '[[:alpha:]]' then v_merchant end;
  end if;

  -- Empfänger vor Verwendungszweck („Einkauf“, „Rechnung“ sind kein
  -- Händler); der Zweck gewinnt nur, wenn er dieselbe Marke genauer nennt
  -- (Empfänger „AMAZON EU“, Zweck „AMAZON PRIME*…“ → amazon prime).
  v_from_purpose      := private.merchant_candidate(p_purpose);
  v_from_counterparty := private.merchant_candidate(p_counterparty);
  if v_from_counterparty is null then
    return v_from_purpose;
  end if;
  if v_from_purpose is not null
     and split_part(v_from_purpose, ' ', 1) = split_part(v_from_counterparty, ' ', 1) then
    return v_from_purpose;
  end if;
  return v_from_counterparty;
end;
$$;

comment on function private.extract_merchant(text, text) is
  'Wahrscheinlicher Händlername für gelernte Regeln. Bei Zahlungsvermittlern (PayPal, Klarna …) aus '
  'dem Verwendungszweck ohne Vermittlernamen, sonst aus dem Empfänger (oder dem Zweck, wenn er dieselbe '
  'Marke genauer nennt bzw. kein Empfänger da ist), jeweils vor der ersten Zahlenfolge ab 4 Ziffern; '
  'NULL wenn nichts Brauchbares.';

-- ---------------------------------------------------------------------
-- 4. Regel-Abgleich über alle Felder
-- ---------------------------------------------------------------------
-- Reihenfolge: eigene Regeln (manual/learned) vor Standardregeln, dann
-- priority, dann längeres Muster, dann ältere Regel.
--   contains     – normalisiertes Muster als Teilstring
--   word         – normalisiertes Muster als ganze Wortfolge
--   equals       – normalisierter Text gleich Muster
--   starts_with  – normalisierter Text beginnt mit Muster
--   regex        – auf den Rohtext
-- IBAN-Felder werden ohne Leerzeichen verglichen.
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
  select r.id, r.category_id
    from public.categorization_rules r
    cross join lateral (select private.normalize_booking_text(r.pattern) as np) n
   where r.user_id = p_user_id
     and r.is_active
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
                when 'equals'      then v.pat <> '' and v.norm = v.pat
                when 'starts_with' then v.pat <> '' and starts_with(v.norm, v.pat)
                when 'regex'       then case when r.case_sensitive then f.raw ~ r.pattern else f.raw ~* r.pattern end
              end
     )
   order by (r.origin = 'standard'), r.priority, char_length(n.np) desc, r.created_at, r.id
   limit 1;
$$;

comment on function private.match_rule(uuid, uuid, numeric, text, text, text, text, text) is
  'Erste passende aktive Regel (eigene vor Standard, priority, längeres Muster, älter): Regel- und Kategorie-ID.';

-- Bisherige Signatur (Import aus #20, Tests) bleibt als Kurzform erhalten.
create or replace function private.match_category_rule(
  p_user_id      uuid,
  p_account_id   uuid,
  p_amount       numeric,
  p_counterparty text,
  p_purpose      text
)
returns uuid
language sql
stable
set search_path = ''
as $$
  select m.category_id from private.match_rule(p_user_id, p_account_id, p_amount, p_counterparty, p_purpose) m;
$$;

-- ---------------------------------------------------------------------
-- 5. Regeln anlegen (mit Feld, Typ und Richtung)
-- ---------------------------------------------------------------------
-- Eigene Regeln (manual/learned) werden untereinander geordnet; Standard-
-- regeln laufen ohnehin danach und bleiben bei Priorität 100.
create or replace function private.priority_for_new_rule(p_user_id uuid, p_pattern text)
returns smallint
language sql
stable
set search_path = ''
as $$
  select least(1000, coalesce(
    (select min(r.priority)
       from public.categorization_rules r
      where r.user_id = p_user_id
        and r.origin <> 'standard'
        and private.normalize_booking_text(r.pattern) <> ''
        and private.normalize_booking_text(r.pattern) <> private.normalize_booking_text(p_pattern)
        and position(private.normalize_booking_text(r.pattern) in private.normalize_booking_text(p_pattern)) > 0),
    (select max(r.priority) + 1 from public.categorization_rules r
      where r.user_id = p_user_id and r.origin <> 'standard'),
    1
  ))::smallint;
$$;

create or replace function public.reorder_categorization_rules(p_ids uuid[])
returns void
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_uid   uuid := auth.uid();
  v_total integer;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  select count(*) into v_total
    from public.categorization_rules r where r.user_id = v_uid and r.origin <> 'standard';
  if p_ids is null
     or cardinality(p_ids) <> v_total
     or v_total > 1000
     or (select count(distinct x) from unnest(p_ids) as x) <> v_total
     or exists (
       select 1 from unnest(p_ids) as x
        where not exists (select 1 from public.categorization_rules r
                           where r.id = x and r.user_id = v_uid and r.origin <> 'standard')
     ) then
    raise exception 'invalid_order' using errcode = '22023';
  end if;

  update public.categorization_rules r
     set priority = o.position
    from unnest(p_ids) with ordinality as o (id, position)
   where r.id = o.id
     and r.user_id = v_uid
     and r.priority is distinct from o.position;
end;
$$;

comment on function public.reorder_categorization_rules(uuid[]) is
  'Alle eigenen Regeln (ohne Standardregeln) in neuer Reihenfolge (priority 1..n). Fehler invalid_order (22023).';

drop function public.create_categorization_rule(text, uuid);

create function public.create_categorization_rule(
  p_pattern     text,
  p_category_id uuid,
  p_match_field public.rule_match_field default 'counterparty_or_purpose',
  p_match_type  public.rule_match_type  default 'contains',
  p_direction   text                    default null
)
returns uuid
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_uid     uuid := auth.uid();
  v_pattern text;
  v_min     numeric;
  v_max     numeric;
  v_id      uuid;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if p_match_type not in ('contains', 'word', 'equals', 'starts_with') then
    raise exception 'invalid_pattern' using errcode = '22023';
  end if;
  v_pattern := case when p_match_field = 'counterparty_iban'
                    then upper(replace(coalesce(p_pattern, ''), ' ', ''))
                    else private.normalize_booking_text(p_pattern) end;
  if char_length(v_pattern) < 2 or char_length(v_pattern) > 200 then
    raise exception 'invalid_pattern' using errcode = '22023';
  end if;
  if p_direction is not null and p_direction not in ('in', 'out') then
    raise exception 'invalid_direction' using errcode = '22023';
  end if;
  v_min := case when p_direction = 'in' then 0.01 end;
  v_max := case when p_direction = 'out' then -0.01 end;
  if not exists (select 1 from public.categories c where c.id = p_category_id and c.user_id = v_uid) then
    raise exception 'category_not_found' using errcode = 'P0002';
  end if;
  if exists (
    select 1 from public.categorization_rules r
     where r.user_id = v_uid
       and r.match_field = p_match_field
       and r.match_type = p_match_type
       and r.amount_min is not distinct from v_min
       and r.amount_max is not distinct from v_max
       and lower(replace(r.pattern, ' ', '')) = lower(replace(v_pattern, ' ', ''))
  ) then
    raise exception 'rule_exists' using errcode = '23505';
  end if;

  insert into public.categorization_rules
    (user_id, category_id, pattern, match_type, match_field, amount_min, amount_max, priority, origin)
  values (v_uid, p_category_id, v_pattern, p_match_type, p_match_field, v_min, v_max,
          private.priority_for_new_rule(v_uid, v_pattern), 'manual')
  returning id into v_id;
  return v_id;
end;
$$;

comment on function public.create_categorization_rule(text, uuid, public.rule_match_field, public.rule_match_type, text) is
  'Eigene Regel anlegen: Feld (Standard: Empfänger/Zweck/Beschreibung), Typ (contains/word/equals/'
  'starts_with), Richtung in/out/NULL. Fehler: invalid_pattern, invalid_direction (22023), '
  'category_not_found (P0002), rule_exists (23505).';

-- ---------------------------------------------------------------------
-- 6. Standard-Regelset
-- ---------------------------------------------------------------------
-- (Muster normalisiert, Feld, Typ, default_key der Kategorie, Richtung)
-- Richtung: 'out' = nur Ausgaben, 'in' = nur Eingänge, NULL = beides.
create or replace function private.standard_rule_templates()
returns table (
  pattern     text,
  match_field public.rule_match_field,
  match_type  public.rule_match_type,
  default_key text,
  direction   text
)
language sql
immutable
set search_path = ''
as $$
  select t.pattern, t.field::public.rule_match_field, t.type::public.rule_match_type, t.key, t.dir
    from (values
      -- Lebensmittel und Drogerie
      ('rewe','counterparty_or_purpose','word','groceries','out'),
      ('edeka','counterparty_or_purpose','word','groceries','out'),
      ('aldi','counterparty_or_purpose','word','groceries','out'),
      ('lidl','counterparty_or_purpose','word','groceries','out'),
      ('penny','counterparty_or_purpose','word','groceries','out'),
      ('kaufland','counterparty_or_purpose','word','groceries','out'),
      ('netto marken','counterparty_or_purpose','word','groceries','out'),
      ('norma','counterparty_or_purpose','word','groceries','out'),
      ('tegut','counterparty_or_purpose','word','groceries','out'),
      ('globus','counterparty_or_purpose','word','groceries','out'),
      ('alnatura','counterparty_or_purpose','word','groceries','out'),
      ('denns biomarkt','counterparty_or_purpose','word','groceries','out'),
      ('bio company','counterparty_or_purpose','word','groceries','out'),
      ('nahkauf','counterparty_or_purpose','word','groceries','out'),
      ('marktkauf','counterparty_or_purpose','word','groceries','out'),
      ('famila','counterparty_or_purpose','word','groceries','out'),
      ('picnic','counterparty_or_purpose','word','groceries','out'),
      ('flink','counterparty_or_purpose','word','groceries','out'),
      ('dm drogerie','counterparty_or_purpose','word','groceries','out'),
      ('rossmann','counterparty_or_purpose','word','groceries','out'),
      ('budni','counterparty_or_purpose','word','groceries','out'),
      -- Mobilität
      ('deutsche bahn','counterparty_or_purpose','word','mobility','out'),
      ('db vertrieb','counterparty_or_purpose','word','mobility','out'),
      ('db fernverkehr','counterparty_or_purpose','word','mobility','out'),
      ('db regio','counterparty_or_purpose','word','mobility','out'),
      ('bahn.de','counterparty_or_purpose','word','mobility','out'),
      ('deutschlandticket','counterparty_or_purpose','contains','mobility','out'),
      ('mvg','counterparty_or_purpose','word','mobility','out'),
      ('bvg','counterparty_or_purpose','word','mobility','out'),
      ('hvv','counterparty_or_purpose','word','mobility','out'),
      ('rmv','counterparty_or_purpose','word','mobility','out'),
      ('vrr','counterparty_or_purpose','word','mobility','out'),
      ('vvs','counterparty_or_purpose','word','mobility','out'),
      ('kvb','counterparty_or_purpose','word','mobility','out'),
      ('flixbus','counterparty_or_purpose','word','mobility','out'),
      ('flixtrain','counterparty_or_purpose','word','mobility','out'),
      ('aral','counterparty_or_purpose','word','mobility','out'),
      ('shell','counterparty_or_purpose','word','mobility','out'),
      ('esso','counterparty_or_purpose','word','mobility','out'),
      ('totalenergies','counterparty_or_purpose','word','mobility','out'),
      ('jet tankstelle','counterparty_or_purpose','word','mobility','out'),
      ('agip','counterparty_or_purpose','word','mobility','out'),
      ('omv','counterparty_or_purpose','word','mobility','out'),
      ('sixt','counterparty_or_purpose','word','mobility','out'),
      ('share now','counterparty_or_purpose','word','mobility','out'),
      ('miles mobility','counterparty_or_purpose','word','mobility','out'),
      ('free now','counterparty_or_purpose','word','mobility','out'),
      ('uber','counterparty_or_purpose','word','mobility','out'),
      ('bolt','counterparty_or_purpose','word','mobility','out'),
      ('lime','counterparty_or_purpose','word','mobility','out'),
      ('adac','counterparty_or_purpose','word','mobility','out'),
      ('easypark','counterparty_or_purpose','word','mobility','out'),
      ('contipark','counterparty_or_purpose','word','mobility','out'),
      ('apcoa','counterparty_or_purpose','word','mobility','out'),
      -- Abos & Medien, Telefon und Internet
      ('netflix','counterparty_or_purpose','word','subscriptions_media','out'),
      ('spotify','counterparty_or_purpose','word','subscriptions_media','out'),
      ('disney+','counterparty_or_purpose','word','subscriptions_media','out'),
      ('disney plus','counterparty_or_purpose','word','subscriptions_media','out'),
      ('amazon prime','counterparty_or_purpose','word','subscriptions_media','out'),
      ('prime video','counterparty_or_purpose','word','subscriptions_media','out'),
      ('dazn','counterparty_or_purpose','word','subscriptions_media','out'),
      ('sky deutschland','counterparty_or_purpose','word','subscriptions_media','out'),
      ('apple.com bill','counterparty_or_purpose','word','subscriptions_media','out'),
      ('youtube premium','counterparty_or_purpose','word','subscriptions_media','out'),
      ('audible','counterparty_or_purpose','word','subscriptions_media','out'),
      ('beitragsservice','counterparty_or_purpose','contains','subscriptions_media','out'),
      ('rundfunkbeitrag','counterparty_or_purpose','contains','subscriptions_media','out'),
      ('telekom','counterparty_or_purpose','word','subscriptions_media','out'),
      ('vodafone','counterparty_or_purpose','word','subscriptions_media','out'),
      ('o2','counterparty_or_purpose','word','subscriptions_media','out'),
      ('telefonica','counterparty_or_purpose','word','subscriptions_media','out'),
      ('1&1','counterparty_or_purpose','word','subscriptions_media','out'),
      ('congstar','counterparty_or_purpose','word','subscriptions_media','out'),
      ('freenet','counterparty_or_purpose','word','subscriptions_media','out'),
      ('pyur','counterparty_or_purpose','word','subscriptions_media','out'),
      ('netcologne','counterparty_or_purpose','word','subscriptions_media','out'),
      -- Wohnen und Energie
      ('miete','counterparty_or_purpose','word','housing','out'),
      ('hausgeld','counterparty_or_purpose','contains','housing','out'),
      ('nebenkosten','counterparty_or_purpose','contains','housing','out'),
      ('stadtwerke','counterparty_or_purpose','contains','housing','out'),
      ('vattenfall','counterparty_or_purpose','word','housing','out'),
      ('e.on','counterparty_or_purpose','word','housing','out'),
      ('eon energie','counterparty_or_purpose','word','housing','out'),
      ('enbw','counterparty_or_purpose','word','housing','out'),
      ('lichtblick','counterparty_or_purpose','word','housing','out'),
      ('naturstrom','counterparty_or_purpose','word','housing','out'),
      ('tibber','counterparty_or_purpose','word','housing','out'),
      ('octopus energy','counterparty_or_purpose','word','housing','out'),
      ('mainova','counterparty_or_purpose','word','housing','out'),
      -- Versicherungen
      ('versicherung','counterparty_or_purpose','contains','insurance','out'),
      ('allianz','counterparty_or_purpose','word','insurance','out'),
      ('huk coburg','counterparty_or_purpose','word','insurance','out'),
      ('huk24','counterparty_or_purpose','word','insurance','out'),
      ('axa','counterparty_or_purpose','word','insurance','out'),
      ('ergo','counterparty_or_purpose','word','insurance','out'),
      ('generali','counterparty_or_purpose','word','insurance','out'),
      ('debeka','counterparty_or_purpose','word','insurance','out'),
      ('devk','counterparty_or_purpose','word','insurance','out'),
      ('signal iduna','counterparty_or_purpose','word','insurance','out'),
      ('r+v','counterparty_or_purpose','word','insurance','out'),
      ('gothaer','counterparty_or_purpose','word','insurance','out'),
      ('hansemerkur','counterparty_or_purpose','word','insurance','out'),
      ('provinzial','counterparty_or_purpose','word','insurance','out'),
      -- Gesundheit
      ('apotheke','counterparty_or_purpose','contains','health','out'),
      ('docmorris','counterparty_or_purpose','word','health','out'),
      ('krankenkasse','counterparty_or_purpose','contains','health','out'),
      ('aok','counterparty_or_purpose','word','health','out'),
      ('barmer','counterparty_or_purpose','word','health','out'),
      ('techniker krankenkasse','counterparty_or_purpose','word','health','out'),
      ('dak','counterparty_or_purpose','word','health','out'),
      ('zahnarzt','counterparty_or_purpose','contains','health','out'),
      ('arztpraxis','counterparty_or_purpose','contains','health','out'),
      ('fielmann','counterparty_or_purpose','word','health','out'),
      -- Freizeit, Reisen, Gastronomie
      ('lufthansa','counterparty_or_purpose','word','leisure_travel','out'),
      ('eurowings','counterparty_or_purpose','word','leisure_travel','out'),
      ('ryanair','counterparty_or_purpose','word','leisure_travel','out'),
      ('easyjet','counterparty_or_purpose','word','leisure_travel','out'),
      ('condor','counterparty_or_purpose','word','leisure_travel','out'),
      ('booking.com','counterparty_or_purpose','word','leisure_travel','out'),
      ('airbnb','counterparty_or_purpose','word','leisure_travel','out'),
      ('expedia','counterparty_or_purpose','word','leisure_travel','out'),
      ('lieferando','counterparty_or_purpose','word','leisure_travel','out'),
      ('wolt','counterparty_or_purpose','word','leisure_travel','out'),
      ('uber eats','counterparty_or_purpose','word','leisure_travel','out'),
      ('mcdonald','counterparty_or_purpose','contains','leisure_travel','out'),
      ('burger king','counterparty_or_purpose','word','leisure_travel','out'),
      ('starbucks','counterparty_or_purpose','word','leisure_travel','out'),
      ('cinemaxx','counterparty_or_purpose','word','leisure_travel','out'),
      ('uci kinowelt','counterparty_or_purpose','word','leisure_travel','out'),
      ('eventim','counterparty_or_purpose','word','leisure_travel','out'),
      ('mcfit','counterparty_or_purpose','word','leisure_travel','out'),
      ('fitx','counterparty_or_purpose','word','leisure_travel','out'),
      ('urban sports','counterparty_or_purpose','word','leisure_travel','out'),
      ('clever fit','counterparty_or_purpose','word','leisure_travel','out'),
      ('steam','counterparty_or_purpose','word','leisure_travel','out'),
      ('playstation','counterparty_or_purpose','word','leisure_travel','out'),
      ('nintendo','counterparty_or_purpose','word','leisure_travel','out'),
      -- Shopping
      ('amazon','counterparty_or_purpose','word','shopping','out'),
      ('zalando','counterparty_or_purpose','word','shopping','out'),
      ('otto','counterparty_or_purpose','word','shopping','out'),
      ('ikea','counterparty_or_purpose','word','shopping','out'),
      ('mediamarkt','counterparty_or_purpose','word','shopping','out'),
      ('media markt','counterparty_or_purpose','word','shopping','out'),
      ('saturn','counterparty_or_purpose','word','shopping','out'),
      ('h&m','counterparty_or_purpose','word','shopping','out'),
      ('primark','counterparty_or_purpose','word','shopping','out'),
      ('decathlon','counterparty_or_purpose','word','shopping','out'),
      ('ebay','counterparty_or_purpose','word','shopping','out'),
      ('about you','counterparty_or_purpose','word','shopping','out'),
      ('tchibo','counterparty_or_purpose','word','shopping','out'),
      ('obi','counterparty_or_purpose','word','shopping','out'),
      ('hornbach','counterparty_or_purpose','word','shopping','out'),
      ('bauhaus','counterparty_or_purpose','word','shopping','out'),
      ('toom','counterparty_or_purpose','word','shopping','out'),
      ('douglas','counterparty_or_purpose','word','shopping','out'),
      ('thalia','counterparty_or_purpose','word','shopping','out'),
      ('deichmann','counterparty_or_purpose','word','shopping','out'),
      ('tk maxx','counterparty_or_purpose','word','shopping','out'),
      ('temu','counterparty_or_purpose','word','shopping','out'),
      ('shein','counterparty_or_purpose','word','shopping','out'),
      ('aliexpress','counterparty_or_purpose','word','shopping','out'),
      -- Bildung
      ('volkshochschule','counterparty_or_purpose','contains','education','out'),
      ('vhs','counterparty_or_purpose','word','education','out'),
      ('udemy','counterparty_or_purpose','word','education','out'),
      ('coursera','counterparty_or_purpose','word','education','out'),
      ('studierendenwerk','counterparty_or_purpose','contains','education','out'),
      ('studentenwerk','counterparty_or_purpose','contains','education','out'),
      ('semesterbeitrag','counterparty_or_purpose','contains','education','out'),
      -- Steuern
      ('finanzamt','counterparty_or_purpose','contains','taxes','out'),
      ('kfz steuer','counterparty_or_purpose','word','taxes','out'),
      ('bundeskasse','counterparty_or_purpose','contains','taxes','out'),
      -- Kapitalertragsteuer (Steuerabrechnung zur Zinsgutschrift o. ä.)
      ('kapitalertragsteuer','any_text','contains','capital_gains_tax','out'),
      ('kapitalertragssteuer','any_text','contains','capital_gains_tax','out'),
      ('abgeltungsteuer','any_text','contains','capital_gains_tax','out'),
      ('abgeltungssteuer','any_text','contains','capital_gains_tax','out'),
      ('steuerabrechnung','any_text','contains','capital_gains_tax','out'),
      ('solidaritaetszuschlag','any_text','contains','capital_gains_tax','out'),
      -- Kapitalerträge (Zinszahlung: Verwendungszweck oft leer, nur Typ gefüllt)
      ('zinszahlung','any_text','contains','investment_income','in'),
      ('zinsgutschrift','any_text','contains','investment_income','in'),
      ('zinsertrag','any_text','contains','investment_income','in'),
      ('zinsen','any_text','word','investment_income','in'),
      ('habenzinsen','any_text','contains','investment_income','in'),
      ('dividende','any_text','contains','investment_income','in'),
      ('ertragsgutschrift','any_text','contains','investment_income','in'),
      ('ausschuettung','any_text','contains','investment_income','in'),
      ('kupon','any_text','word','investment_income','in'),
      -- Gehalt, Mieteinnahmen, sonstige Einnahmen
      ('gehalt','counterparty_or_purpose','contains','salary','in'),
      ('lohn','counterparty_or_purpose','word','salary','in'),
      ('bezuege','counterparty_or_purpose','word','salary','in'),
      ('miete','counterparty_or_purpose','word','rental_income','in'),
      ('kindergeld','counterparty_or_purpose','contains','other_income','in'),
      ('elterngeld','counterparty_or_purpose','contains','other_income','in'),
      -- Sparen, Kredit, Umbuchung, Bankentgelte
      ('trade republic','counterparty_or_purpose','word','savings_investments','out'),
      ('scalable capital','counterparty_or_purpose','word','savings_investments','out'),
      ('sparplan','counterparty_or_purpose','contains','savings_investments','out'),
      ('bitpanda','counterparty_or_purpose','word','savings_investments','out'),
      ('tilgung','counterparty_or_purpose','contains','loan_repayment','out'),
      ('darlehen','counterparty_or_purpose','contains','loan_repayment','out'),
      ('umbuchung','any_text','contains','transfer',null),
      ('uebertrag','any_text','word','transfer',null),
      ('bargeldauszahlung','any_text','contains','transfer','out'),
      ('geldautomat','any_text','contains','transfer','out'),
      ('kontofuehrung','any_text','contains','other_expenses','out'),
      ('sollzinsen','any_text','contains','other_expenses','out'),
      ('zinsen','any_text','word','other_expenses','out')
    ) as t (pattern, field, type, key, dir);
$$;

comment on function private.standard_rule_templates() is
  'Standard-Regelset für verbreitete deutsche Händler und Buchungsarten (über load_standard_rules()).';

-- Standardregeln für den angemeldeten Nutzer übernehmen. Idempotent: bereits
-- vorhandene (gleiches Muster, Feld, Typ, Richtung) werden übersprungen;
-- fehlt die Zielkategorie (umbenannt/gelöscht), entfällt die Regel.
create or replace function public.load_standard_rules()
returns integer
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_uid   uuid := auth.uid();
  v_count integer;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;

  insert into public.categorization_rules
    (user_id, category_id, pattern, match_type, match_field, amount_min, amount_max, priority, origin)
  select v_uid, c.id, t.pattern, t.match_type, t.match_field,
         case when t.direction = 'in' then 0.01 end,
         case when t.direction = 'out' then -0.01 end,
         100, 'standard'
    from private.standard_rule_templates() t
    join public.categories c on c.user_id = v_uid and c.default_key = t.default_key
   where not exists (
     select 1 from public.categorization_rules r
      where r.user_id = v_uid
        and r.pattern = t.pattern
        and r.match_field = t.match_field
        and r.match_type = t.match_type
        and r.amount_min is not distinct from (case when t.direction = 'in' then 0.01 end)
        and r.amount_max is not distinct from (case when t.direction = 'out' then -0.01 end)
   );
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- ---------------------------------------------------------------------
-- 7. Regeln rückwirkend anwenden, zurücksetzen, Kennzahlen
-- ---------------------------------------------------------------------
-- Nur Buchungen OHNE Kategorie (Schicht 1). p_rule_id: nur Treffer dieser
-- Regel (z. B. „N ähnliche Buchungen gefunden, auch zuordnen?“).
-- p_dry_run: nur zählen.
create or replace function public.apply_categorization_rules(
  p_rule_id uuid    default null,
  p_dry_run boolean default false
)
returns integer
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_uid   uuid := auth.uid();
  v_count integer;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;

  if p_dry_run then
    select count(*) into v_count
      from public.transactions t
      cross join lateral private.match_rule(v_uid, t.account_id, t.amount, t.counterparty_name, t.purpose,
                                            t.description, t.transaction_type, t.counterparty_iban) m
     where t.user_id = v_uid
       and t.category_id is null
       and (p_rule_id is null or m.rule_id = p_rule_id);
    return v_count;
  end if;

  update public.transactions t
     set category_id = m.category_id,
         categorization_source = 'rule',
         categorization_rule_id = m.rule_id
    from public.transactions s
    cross join lateral private.match_rule(v_uid, s.account_id, s.amount, s.counterparty_name, s.purpose,
                                          s.description, s.transaction_type, s.counterparty_iban) m
   where s.id = t.id
     and t.user_id = v_uid
     and t.category_id is null
     and (p_rule_id is null or m.rule_id = p_rule_id);
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

comment on function public.apply_categorization_rules(uuid, boolean) is
  'Regeln auf eigene Buchungen ohne Kategorie anwenden (manuelle bleiben unberührt); p_rule_id: nur diese '
  'Regel; p_dry_run: nur zählen. Liefert die Anzahl.';

-- Maschinell vergebene Kategorien zurücksetzen (Schicht 1: manuelle nie).
create or replace function public.reset_machine_categorization()
returns integer
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_uid   uuid := auth.uid();
  v_count integer;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  update public.transactions t
     set category_id = null, categorization_source = null, categorization_rule_id = null
   where t.user_id = v_uid
     and t.categorization_source = 'rule';
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- Anteile: manuell, eigene Regel, Standardregel, unkategorisiert.
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
                                       and t.categorization_source is distinct from 'rule'),
    'rule',          count(*) filter (where t.categorization_source = 'rule'
                                       and coalesce(r.origin, 'manual') <> 'standard'),
    'standard',      count(*) filter (where t.categorization_source = 'rule' and r.origin = 'standard'),
    'uncategorized', count(*) filter (where t.category_id is null)
  )
    from public.transactions t
    left join public.categorization_rules r on r.id = t.categorization_rule_id
   where t.user_id = (select auth.uid());
$$;

-- ---------------------------------------------------------------------
-- 8. Import mit Transaktionstyp, IBAN, Beschreibung und Regel-ID
-- ---------------------------------------------------------------------
drop function private.import_rows(jsonb, public.currency_code);

create function private.import_rows(p_rows jsonb, p_default_currency public.currency_code)
returns table (
  ord               integer,
  booking_date      date,
  value_date        date,
  amount            numeric(14,2),
  currency          public.currency_code,
  counterparty      text,
  purpose           text,
  transaction_type  text,
  counterparty_iban text,
  description       text
)
language plpgsql
stable
set search_path = ''
as $$
declare
  v_row    jsonb;
  v_ord    integer;
  v_amount numeric;
  v_iban   text;
begin
  for v_row, v_ord in select e.value, e.ordinality::integer from jsonb_array_elements(p_rows) with ordinality as e loop
    begin
      ord              := v_ord;
      booking_date     := (v_row ->> 'booking_date')::date;
      value_date       := nullif(v_row ->> 'value_date', '')::date;
      v_amount         := (v_row ->> 'amount')::numeric;
      currency         := coalesce(nullif(v_row ->> 'currency', ''), p_default_currency::text)::public.currency_code;
      counterparty     := nullif(btrim(v_row ->> 'counterparty'), '');
      purpose          := nullif(btrim(v_row ->> 'purpose'), '');
      transaction_type := nullif(btrim(v_row ->> 'transaction_type'), '');
      description      := nullif(btrim(v_row ->> 'description'), '');
      v_iban           := upper(regexp_replace(coalesce(v_row ->> 'counterparty_iban', ''), '\s', '', 'g'));
    exception when others then
      raise exception 'invalid_row' using errcode = '22023', detail = v_ord::text;
    end;
    -- Ungültige IBAN verwerfen statt die Zeile abzulehnen (manche Banken
    -- liefern dort Kontonummern).
    counterparty_iban := case when v_iban ~ '^[A-Z]{2}[0-9]{2}[0-9A-Z]{11,30}$' then v_iban end;
    if jsonb_typeof(v_row) <> 'object'
       or booking_date is null or booking_date not between date '1900-01-01' and date '2100-12-31'
       or (value_date is not null and value_date not between date '1900-01-01' and date '2100-12-31')
       or v_amount is null or v_amount = 0 or v_amount <> round(v_amount, 2)
       or abs(v_amount) >= 1000000000000
       or char_length(counterparty) > 200
       or char_length(purpose) > 1000
       or char_length(transaction_type) > 100
       or char_length(description) > 1000 then
      raise exception 'invalid_row' using errcode = '22023', detail = v_ord::text;
    end if;
    amount := v_amount;
    return next;
  end loop;
end;
$$;

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
  v_new         integer;
  v_duplicates  integer;
  v_categorized integer;
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

  -- Mehrfachaufruf in einer Transaktion (Vorschau + Import, Tests).
  if to_regclass('pg_temp.import_batch') is not null then
    drop table pg_temp.import_batch;
  end if;
  create temporary table import_batch (
    booking_date date, value_date date, amount numeric(14,2), currency public.currency_code,
    counterparty text, purpose text, transaction_type text, counterparty_iban text, description text,
    import_hash text, category_id uuid, rule_id uuid, duplicate boolean
  ) on commit drop;

  insert into pg_temp.import_batch
  select r.booking_date, r.value_date, r.amount, r.currency, r.counterparty, r.purpose,
         r.transaction_type, r.counterparty_iban, r.description,
         private.import_hash(r.booking_date, r.amount, r.purpose,
           row_number() over (
             partition by r.booking_date, r.amount, btrim(regexp_replace(lower(coalesce(r.purpose, '')), '\s+', ' ', 'g'))
             order by r.ord)),
         null, null, false
    from private.import_rows(p_rows, v_currency) r;

  update pg_temp.import_batch b
     set duplicate = exists (
       select 1 from public.transactions t
        where t.account_id = v_account_id and t.import_hash = b.import_hash
     )
   where v_account_id is not null;

  -- Schichten 2 und 3: eigene Regeln vor Standardregeln.
  update pg_temp.import_batch b
     set category_id = m.category_id, rule_id = m.rule_id
    from pg_temp.import_batch s
    cross join lateral private.match_rule(v_uid, v_account_id, s.amount, s.counterparty, s.purpose,
                                          s.description, s.transaction_type, s.counterparty_iban) m
   where s.ctid = b.ctid
     and not b.duplicate;

  select count(*) filter (where not b.duplicate),
         count(*) filter (where b.duplicate),
         count(*) filter (where not b.duplicate and b.category_id is not null)
    into v_new, v_duplicates, v_categorized
    from pg_temp.import_batch b;

  if not p_dry_run then
    insert into public.transactions (
      user_id, account_id, booking_date, value_date, amount, currency,
      counterparty_name, purpose, transaction_type, counterparty_iban, description,
      import_hash, source, category_id, categorization_source, categorization_rule_id
    )
    select v_uid, v_account_id, b.booking_date, b.value_date, b.amount, b.currency,
           b.counterparty, b.purpose, b.transaction_type, b.counterparty_iban, b.description,
           b.import_hash, 'csv_import', b.category_id,
           case when b.category_id is not null then 'rule'::public.categorization_source end,
           b.rule_id
      from pg_temp.import_batch b
     where not b.duplicate
    on conflict (account_id, import_hash) where import_hash is not null do nothing;
    get diagnostics v_new = row_count;
  end if;

  select a.balance into v_balance from public.accounts a where a.id = v_account_id;

  return jsonb_build_object(
    'account_id',  v_account_id,
    'currency',    v_currency,
    'total',       v_total,
    'new',         v_new,
    'duplicates',  v_duplicates,
    'categorized', v_categorized,
    'balance',     v_balance,
    'dry_run',     p_dry_run
  );
end;
$$;

comment on function public.import_transactions(uuid, jsonb, boolean, text, text) is
  'Importiert normalisierte Zeilen [{booking_date, value_date?, amount, currency?, counterparty?, purpose?, '
  'transaction_type?, counterparty_iban?, description?}] in ein eigenes manuelles/CSV-Konto (oder legt eines '
  'an); überspringt Duplikate (import_hash), wendet eigene und Standardregeln an (mit Regel-ID). p_dry_run: '
  'nur zählen. Fehler (22023): invalid_rows, no_rows, too_many_rows, invalid_row (DETAIL = Position), '
  'account_not_importable, invalid_account_name, invalid_currency; account_not_found (P0002).';

-- ---------------------------------------------------------------------
-- 9. Kategorie ändern, lernen, ähnliche zählen
-- ---------------------------------------------------------------------
create or replace function public.set_transaction_category(p_id uuid, p_category_id uuid)
returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_uid          uuid := auth.uid();
  v_old_category uuid;
  v_source       public.transaction_source;
  v_purpose      text;
  v_counterparty text;
  v_pattern      text;
  v_rule_id      uuid;
  v_similar      integer := 0;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;

  select t.category_id, t.source, t.purpose, t.counterparty_name
    into v_old_category, v_source, v_purpose, v_counterparty
    from public.transactions t
   where t.id = p_id and t.user_id = v_uid
     for update;
  if not found then
    raise exception 'transaction_not_found' using errcode = 'P0002';
  end if;
  if p_category_id is not null
     and not exists (select 1 from public.categories c where c.id = p_category_id and c.user_id = v_uid) then
    raise exception 'category_not_found' using errcode = 'P0002';
  end if;
  if v_old_category is not distinct from p_category_id then
    -- Auch eine bestätigte Regel-Zuordnung zählt danach als manuell.
    update public.transactions t
       set categorization_source = case when p_category_id is null then null else 'manual'::public.categorization_source end,
           categorization_rule_id = null
     where t.id = p_id and t.categorization_source = 'rule';
    return jsonb_build_object('changed', false, 'learned_pattern', null, 'rule_id', null, 'similar', 0);
  end if;

  update public.transactions t
     set category_id = p_category_id,
         categorization_source = case when p_category_id is null then null else 'manual'::public.categorization_source end,
         categorization_rule_id = null
   where t.id = p_id;

  -- Lernen nur bei importierten/synchronisierten Buchungen.
  if p_category_id is not null and v_source <> 'manual' then
    v_pattern := private.extract_merchant(v_purpose, v_counterparty);
    if v_pattern is not null then
      select r.id into v_rule_id
        from public.categorization_rules r
       where r.user_id = v_uid
         and r.origin <> 'standard'
         and r.match_type = 'contains'
         and r.account_id is null and r.amount_min is null and r.amount_max is null
         and private.normalize_booking_text(r.pattern) = v_pattern
       order by r.priority, r.created_at
       limit 1;
      if found then
        update public.categorization_rules r
           set category_id = p_category_id, is_active = true
         where r.id = v_rule_id;
      else
        insert into public.categorization_rules (user_id, category_id, pattern, match_type, match_field, priority, origin)
        values (v_uid, p_category_id, v_pattern, 'contains', 'counterparty_or_purpose',
                private.priority_for_new_rule(v_uid, v_pattern), 'learned')
        returning id into v_rule_id;
      end if;
      v_similar := public.apply_categorization_rules(v_rule_id, true);
    end if;
  end if;

  return jsonb_build_object('changed', true, 'learned_pattern', v_pattern, 'rule_id', v_rule_id, 'similar', v_similar);
end;
$$;

comment on function public.set_transaction_category(uuid, uuid) is
  'Kategorie einer eigenen Buchung setzen (categorization_source = manual). Bei importierten/synchronisierten '
  'Buchungen wird eine Regel für den Händler gelernt; similar = unkategorisierte Buchungen, auf die sie passt. '
  'Fehler: transaction_not_found, category_not_found (P0002).';

-- ---------------------------------------------------------------------
-- 10. Standardkategorie „Kapitalertragsteuer“
-- ---------------------------------------------------------------------
create or replace function private.default_budget_group(
  p_default_key text,
  p_kind        public.category_kind
)
returns public.budget_group
language sql
immutable
set search_path = ''
as $$
  select case
    when p_kind = 'income' then null
    when p_default_key in ('housing', 'groceries', 'mobility', 'insurance', 'health', 'taxes', 'capital_gains_tax')
      then 'needs'::public.budget_group
    when p_default_key in ('leisure_travel', 'subscriptions_media', 'shopping', 'education', 'other_expenses')
      then 'wants'::public.budget_group
    when p_default_key in ('savings_investments', 'loan_repayment')
      then 'savings'::public.budget_group
    when p_default_key = 'transfer' then null
    when p_kind = 'expense' then 'wants'::public.budget_group
    else null
  end;
$$;

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
    (p_user_id, 'Sonstige Ausgaben',    'expense',  '#94a3b8', 'ellipsis',         true, 200, 'other_expenses'),
    (p_user_id, 'Sparen & Investieren', 'transfer', '#0f766e', 'piggy-bank',       true, 300, 'savings_investments'),
    (p_user_id, 'Kredittilgung',        'transfer', '#475569', 'receipt',          true, 310, 'loan_repayment'),
    (p_user_id, 'Umbuchung',            'transfer', '#9ca3af', 'arrow-left-right', true, 320, 'transfer')
  on conflict on constraint categories_name_key do nothing;
end;
$$;

-- Nachtrag für bestehende Nutzer (idempotent):
--  - ohne jede Kategorie: vollständige Standardkategorien,
--  - sonst „Kapitalertragsteuer“ und – falls weder per Schlüssel noch per
--    Name vorhanden – „Kapitalerträge“. Gleichnamige eigene Kategorien
--    ohne Schlüssel erhalten den Schlüssel (wie 20261002120000).
do $$
declare
  v_user uuid;
begin
  for v_user in select u.id from auth.users u loop
    if not exists (select 1 from public.categories c where c.user_id = v_user) then
      perform private.seed_default_categories(v_user);
      continue;
    end if;

    update public.categories c
       set default_key = m.key
      from (values ('Kapitalertragsteuer', 'capital_gains_tax', 'expense'::public.category_kind),
                   ('Kapitalerträge', 'investment_income', 'income'::public.category_kind)) as m (name, key, kind)
     where c.user_id = v_user
       and c.parent_category_id is null
       and c.default_key is null
       and c.name = m.name
       and c.kind = m.kind
       and not exists (select 1 from public.categories x where x.user_id = v_user and x.default_key = m.key);

    insert into public.categories (user_id, name, kind, color, icon, is_default, sort_order, default_key)
    select v_user, m.name, m.kind, m.color, m.icon, true, m.sort_order, m.key
      from (values
        ('Kapitalertragsteuer', 'expense'::public.category_kind, '#475569', 'percent', 195, 'capital_gains_tax'),
        ('Kapitalerträge',      'income'::public.category_kind,  '#15803d', 'trending-up', 20, 'investment_income')
      ) as m (name, kind, color, icon, sort_order, key)
     where not exists (select 1 from public.categories c where c.user_id = v_user and c.default_key = m.key)
    on conflict on constraint categories_name_key do nothing;
  end loop;
end;
$$;

-- ---------------------------------------------------------------------
-- Rechte
-- ---------------------------------------------------------------------
grant execute on function private.is_payment_processor(text)                                       to authenticated;
grant execute on function private.merchant_candidate(text)                                         to authenticated;
grant execute on function private.match_rule(uuid, uuid, numeric, text, text, text, text, text)   to authenticated;
grant execute on function private.standard_rule_templates()                                       to authenticated;
grant execute on function private.import_rows(jsonb, public.currency_code)                        to authenticated;

revoke all on function public.create_categorization_rule(text, uuid, public.rule_match_field, public.rule_match_type, text) from public, anon;
revoke all on function public.load_standard_rules()                    from public, anon;
revoke all on function public.apply_categorization_rules(uuid, boolean) from public, anon;
revoke all on function public.reset_machine_categorization()           from public, anon;
revoke all on function public.categorization_stats()                   from public, anon;
grant execute on function public.create_categorization_rule(text, uuid, public.rule_match_field, public.rule_match_type, text) to authenticated;
grant execute on function public.load_standard_rules()                    to authenticated;
grant execute on function public.apply_categorization_rules(uuid, boolean) to authenticated;
grant execute on function public.reset_machine_categorization()           to authenticated;
grant execute on function public.categorization_stats()                   to authenticated;

commit;
