-- =====================================================================
--  20261007120100_categorization_a2.sql
--
--  Kategorisierung, PR A2:
--
--  1. Korrekturen auch auf automatisch zugeordnete Buchungen übertragen:
--     apply_categorization_rules(…, p_overwrite_auto) überschreibt auf
--     Wunsch per Regel vergebene Kategorien (nie manuelle), wenn die Regel
--     dort jetzt die erste Treffer-Regel ist. set_transaction_category
--     meldet dazu similar (ohne Kategorie) und similar_auto (automatisch
--     anders zugeordnet).
--  2. Standardregeln für den deutschen Markt: nur Marken (plus wenige
--     eindeutige Bankbegriffe wie „Zinszahlung“), Vergleich „ganzes Wort“,
--     US-Händler und Allerweltsbegriffe entfernt; Priorität je Regel
--     (MVG/MVV vor „Stadtwerke“). load_standard_rules() gleicht ab:
--     entfernte Standardregeln werden gelöscht, ihre automatischen
--     Zuordnungen zurückgesetzt und die Regeln neu angewendet.
--  5. Eigene Konten: Regeln mit origin = own_account (eigener Name, alle
--     Wörter; eigene IBAN) → Umbuchung. Reihenfolge: eigene Regeln
--     (manual/learned) vor eigenen Konten vor Standardregeln.
--
--  Bestehende Nutzer mit Standardregeln werden am Ende abgeglichen.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- Herkunft own_account
-- ---------------------------------------------------------------------
alter table public.categorization_rules drop constraint categorization_rules_origin_check;
alter table public.categorization_rules
  add constraint categorization_rules_origin_check
  check (origin in ('manual', 'learned', 'standard', 'own_account'));
comment on column public.categorization_rules.origin is
  'manual = vom Nutzer angelegt, learned = aus einer Korrektur gelernt, standard = aus dem Standard-Regelset, '
  'own_account = Erkennung eigener Konten (Name/IBAN → Umbuchung).';

-- ---------------------------------------------------------------------
-- Regel-Abgleich: Rangfolge der Herkunft, Vergleich „alle Wörter“
-- ---------------------------------------------------------------------
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
                when 'all_words'   then v.pat <> '' and not exists (
                                          select 1 from regexp_split_to_table(v.pat, ' ') as w (word)
                                           where w.word <> ''
                                             and position(' ' || w.word || ' ' in ' ' || v.norm || ' ') = 0)
                when 'equals'      then v.pat <> '' and v.norm = v.pat
                when 'starts_with' then v.pat <> '' and starts_with(v.norm, v.pat)
                when 'regex'       then case when r.case_sensitive then f.raw ~ r.pattern else f.raw ~* r.pattern end
              end
     )
   order by case r.origin when 'standard' then 2 when 'own_account' then 1 else 0 end,
            r.priority, char_length(n.np) desc, r.created_at, r.id
   limit 1;
$$;

comment on function private.match_rule(uuid, uuid, numeric, text, text, text, text, text) is
  'Erste passende aktive Regel (eigene Regeln, dann eigene Konten, dann Standard; je priority, längeres '
  'Muster, älter): Regel- und Kategorie-ID.';

-- Eigene Regeln (manual/learned) werden untereinander geordnet; eigene
-- Konten und Standardregeln laufen danach.
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
        and r.origin in ('manual', 'learned')
        and private.normalize_booking_text(r.pattern) <> ''
        and private.normalize_booking_text(r.pattern) <> private.normalize_booking_text(p_pattern)
        and position(private.normalize_booking_text(r.pattern) in private.normalize_booking_text(p_pattern)) > 0),
    (select max(r.priority) + 1 from public.categorization_rules r
      where r.user_id = p_user_id and r.origin in ('manual', 'learned')),
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
    from public.categorization_rules r where r.user_id = v_uid and r.origin in ('manual', 'learned');
  if p_ids is null
     or cardinality(p_ids) <> v_total
     or v_total > 1000
     or (select count(distinct x) from unnest(p_ids) as x) <> v_total
     or exists (
       select 1 from unnest(p_ids) as x
        where not exists (select 1 from public.categorization_rules r
                           where r.id = x and r.user_id = v_uid and r.origin in ('manual', 'learned'))
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
  'Alle eigenen Regeln (manual/learned, ohne eigene Konten und Standardregeln) in neuer Reihenfolge '
  '(priority 1..n). Fehler invalid_order (22023).';

-- ---------------------------------------------------------------------
-- Eigene Regeln: auch „alle Wörter“
-- ---------------------------------------------------------------------
create or replace function public.create_categorization_rule(
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
  if p_match_type not in ('contains', 'word', 'all_words', 'equals', 'starts_with') then
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
       and r.origin in ('manual', 'learned')
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

-- ---------------------------------------------------------------------
-- 1. Rückwirkend anwenden, optional automatische überschreiben
-- ---------------------------------------------------------------------
drop function public.apply_categorization_rules(uuid, boolean);

-- Nur für den angegebenen Nutzer (Aufrufer prüfen den Nutzer).
create function private.apply_rules_for_user(
  p_user_id        uuid,
  p_rule_id        uuid,
  p_dry_run        boolean,
  p_overwrite_auto boolean
)
returns integer
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_count integer;
begin
  if p_dry_run then
    select count(*) into v_count
      from public.transactions t
      cross join lateral private.match_rule(p_user_id, t.account_id, t.amount, t.counterparty_name, t.purpose,
                                            t.description, t.transaction_type, t.counterparty_iban) m
     where t.user_id = p_user_id
       and (t.category_id is null
            or (p_overwrite_auto and t.categorization_source = 'rule' and t.category_id is distinct from m.category_id))
       and (p_rule_id is null or m.rule_id = p_rule_id);
    return v_count;
  end if;

  update public.transactions t
     set category_id = m.category_id,
         categorization_source = 'rule',
         categorization_rule_id = m.rule_id
    from public.transactions s
    cross join lateral private.match_rule(p_user_id, s.account_id, s.amount, s.counterparty_name, s.purpose,
                                          s.description, s.transaction_type, s.counterparty_iban) m
   where s.id = t.id
     and t.user_id = p_user_id
     and (t.category_id is null
          or (p_overwrite_auto and t.categorization_source = 'rule' and t.category_id is distinct from m.category_id))
     and (p_rule_id is null or m.rule_id = p_rule_id);
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- Regeln auf eigene Buchungen anwenden. Manuelle Zuordnungen bleiben
-- immer (Schicht 1). p_overwrite_auto: auch per Regel vergebene Kategorien
-- ändern, wenn jetzt eine andere Regel zuerst greift.
create function public.apply_categorization_rules(
  p_rule_id        uuid    default null,
  p_dry_run        boolean default false,
  p_overwrite_auto boolean default false
)
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
  return private.apply_rules_for_user(v_uid, p_rule_id, p_dry_run, p_overwrite_auto);
end;
$$;

comment on function public.apply_categorization_rules(uuid, boolean, boolean) is
  'Regeln auf eigene Buchungen ohne Kategorie anwenden; p_overwrite_auto: auch automatisch (per Regel) '
  'zugeordnete ändern, nie manuelle. p_rule_id: nur Treffer dieser Regel; p_dry_run: nur zählen.';

-- ---------------------------------------------------------------------
-- 1. Kategorie ändern: ähnliche ohne Kategorie und automatisch anders
--    zugeordnete melden
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
  v_similar_auto integer := 0;
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
    return jsonb_build_object('changed', false, 'learned_pattern', null, 'rule_id', null,
                              'similar', 0, 'similar_auto', 0);
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
         and r.origin in ('manual', 'learned')
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
      v_similar := private.apply_rules_for_user(v_uid, v_rule_id, true, false);
      v_similar_auto := private.apply_rules_for_user(v_uid, v_rule_id, true, true) - v_similar;
    end if;
  end if;

  return jsonb_build_object('changed', true, 'learned_pattern', v_pattern, 'rule_id', v_rule_id,
                            'similar', v_similar, 'similar_auto', v_similar_auto);
end;
$$;

comment on function public.set_transaction_category(uuid, uuid) is
  'Kategorie einer eigenen Buchung setzen (categorization_source = manual). Bei importierten/synchronisierten '
  'Buchungen wird eine Regel für den Händler gelernt; similar = Buchungen ohne Kategorie, similar_auto = '
  'automatisch anders zugeordnete, auf die sie jetzt zuerst passt. Fehler: transaction_not_found, '
  'category_not_found (P0002).';

-- ---------------------------------------------------------------------
-- 2. Standardregeln für den deutschen Markt
-- ---------------------------------------------------------------------
-- Spalten: Muster (normalisiert), Feld, Vergleich, default_key der
-- Kategorie, Richtung (out/in/NULL), Priorität (kleiner = zuerst; 100
-- Standard, 90 spezifischer als 110).
drop function private.standard_rule_templates();

create function private.standard_rule_templates()
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
      ('sollzinsen',           'any_text', 'word', 'other_expenses', 'out', 100)
    ) as t (pattern, field, type, key, dir, prio);
$$;

comment on function private.standard_rule_templates() is
  'Standard-Regelset für den deutschen Markt: Marken und eindeutige Bankbegriffe, ganzes Wort '
  '(über load_standard_rules()).';

-- Standardregeln eines Nutzers mit dem Regelset abgleichen:
--  - nicht mehr enthaltene Standardregeln löschen; ihre automatischen
--    Zuordnungen zurücksetzen,
--  - fehlende ergänzen, Priorität angleichen,
--  - danach Regeln auf Buchungen ohne Kategorie anwenden.
-- Liefert (added, removed, reset, applied).
create function private.sync_standard_rules(p_user_id uuid)
returns table (added integer, removed integer, reset integer, applied integer)
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_added   integer;
  v_removed integer;
  v_reset   integer;
begin
  create temporary table if not exists sync_obsolete (id uuid) on commit drop;
  truncate pg_temp.sync_obsolete;
  insert into pg_temp.sync_obsolete
  select r.id
    from public.categorization_rules r
   where r.user_id = p_user_id
     and r.origin = 'standard'
     and not exists (
       select 1 from private.standard_rule_templates() t
        where t.pattern = r.pattern
          and t.match_field = r.match_field
          and t.match_type = r.match_type
          and r.amount_min is not distinct from (case when t.direction = 'in' then 0.01 end)
          and r.amount_max is not distinct from (case when t.direction = 'out' then -0.01 end)
     );

  update public.transactions t
     set category_id = null, categorization_source = null, categorization_rule_id = null
   where t.user_id = p_user_id
     and t.categorization_source = 'rule'
     and t.categorization_rule_id in (select o.id from pg_temp.sync_obsolete o);
  get diagnostics v_reset = row_count;

  delete from public.categorization_rules r
   where r.user_id = p_user_id and r.id in (select o.id from pg_temp.sync_obsolete o);
  get diagnostics v_removed = row_count;

  update public.categorization_rules r
     set priority = t.priority
    from private.standard_rule_templates() t
   where r.user_id = p_user_id
     and r.origin = 'standard'
     and t.pattern = r.pattern
     and t.match_field = r.match_field
     and t.match_type = r.match_type
     and r.priority is distinct from t.priority;

  insert into public.categorization_rules
    (user_id, category_id, pattern, match_type, match_field, amount_min, amount_max, priority, origin)
  select p_user_id, c.id, t.pattern, t.match_type, t.match_field,
         case when t.direction = 'in' then 0.01 end,
         case when t.direction = 'out' then -0.01 end,
         t.priority, 'standard'
    from private.standard_rule_templates() t
    join public.categories c on c.user_id = p_user_id and c.default_key = t.default_key
   where not exists (
     select 1 from public.categorization_rules r
      where r.user_id = p_user_id
        and r.origin = 'standard'
        and r.pattern = t.pattern
        and r.match_field = t.match_field
        and r.match_type = t.match_type
        and r.amount_min is not distinct from (case when t.direction = 'in' then 0.01 end)
        and r.amount_max is not distinct from (case when t.direction = 'out' then -0.01 end)
   );
  get diagnostics v_added = row_count;

  return query select v_added, v_removed, v_reset,
                      private.apply_rules_for_user(p_user_id, null, false, false);
end;
$$;

-- Bisher: nur ergänzen. Jetzt: abgleichen und anwenden; Ergebnis als jsonb.
drop function public.load_standard_rules();

create function public.load_standard_rules()
returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_row record;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  select * into v_row from private.sync_standard_rules(v_uid);
  return jsonb_build_object('added', v_row.added, 'removed', v_row.removed,
                            'reset', v_row.reset, 'applied', v_row.applied);
end;
$$;

comment on function public.load_standard_rules() is
  'Standardregeln mit dem Regelset abgleichen (ergänzen, entfernte löschen und deren automatische '
  'Zuordnungen zurücksetzen) und auf Buchungen ohne Kategorie anwenden. Liefert {added, removed, reset, applied}.';

-- ---------------------------------------------------------------------
-- 5. Eigene Konten (eigener Name, eigene IBAN → Umbuchung)
-- ---------------------------------------------------------------------
-- p_kind: 'name' (alle Wörter im Empfänger) oder 'iban' (Gegenkonto).
-- Wendet die Regel sofort an – auch auf automatisch anders zugeordnete
-- Buchungen, nie auf manuelle. Liefert {rule_id, applied}.
create function public.add_own_account_identifier(p_kind text, p_value text)
returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_uid      uuid := auth.uid();
  v_category uuid;
  v_pattern  text;
  v_id       uuid;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if p_kind = 'name' then
    v_pattern := private.normalize_booking_text(p_value);
    -- Mindestens zwei Wörter (Vor- und Nachname), sonst träfe z. B.
    -- „Dominik“ jede andere Person dieses Namens.
    if char_length(v_pattern) > 200 or coalesce(array_length(regexp_split_to_array(v_pattern, ' '), 1), 0) < 2
       or v_pattern !~ '[[:alpha:]]{2}' then
      raise exception 'invalid_name' using errcode = '22023';
    end if;
  elsif p_kind = 'iban' then
    v_pattern := upper(regexp_replace(coalesce(p_value, ''), '\s', '', 'g'));
    if v_pattern !~ '^[A-Z]{2}[0-9]{2}[0-9A-Z]{11,30}$' then
      raise exception 'invalid_iban' using errcode = '22023';
    end if;
  else
    raise exception 'invalid_kind' using errcode = '22023';
  end if;

  select c.id into v_category
    from public.categories c
   where c.user_id = v_uid and c.default_key = 'transfer';
  if v_category is null then
    raise exception 'category_not_found' using errcode = 'P0002';
  end if;

  if exists (
    select 1 from public.categorization_rules r
     where r.user_id = v_uid and r.origin = 'own_account' and r.pattern = v_pattern
  ) then
    raise exception 'rule_exists' using errcode = '23505';
  end if;

  insert into public.categorization_rules (user_id, category_id, pattern, match_type, match_field, priority, origin)
  values (v_uid, v_category, v_pattern,
          case when p_kind = 'name' then 'all_words' else 'equals' end::public.rule_match_type,
          case when p_kind = 'name' then 'counterparty' else 'counterparty_iban' end::public.rule_match_field,
          100, 'own_account')
  returning id into v_id;

  return jsonb_build_object('rule_id', v_id,
                            'applied', private.apply_rules_for_user(v_uid, v_id, false, true));
end;
$$;

comment on function public.add_own_account_identifier(text, text) is
  'Eigenes Konto erkennen: p_kind name (Vor- und Nachname, alle Wörter im Empfänger) oder iban → Kategorie '
  'Umbuchung; sofort angewendet (auch auf automatisch anders zugeordnete, nie manuelle). Fehler: invalid_name, '
  'invalid_iban, invalid_kind (22023), category_not_found (P0002), rule_exists (23505).';

-- ---------------------------------------------------------------------
-- Bestehende Nutzer mit Standardregeln abgleichen
-- ---------------------------------------------------------------------
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
-- Rechte
-- ---------------------------------------------------------------------
grant execute on function private.standard_rule_templates()                        to authenticated;
grant execute on function private.apply_rules_for_user(uuid, uuid, boolean, boolean) to authenticated;
grant execute on function private.sync_standard_rules(uuid)                        to authenticated;

revoke all on function public.apply_categorization_rules(uuid, boolean, boolean) from public, anon;
revoke all on function public.load_standard_rules()                             from public, anon;
revoke all on function public.add_own_account_identifier(text, text)            from public, anon;
grant execute on function public.apply_categorization_rules(uuid, boolean, boolean) to authenticated;
grant execute on function public.load_standard_rules()                             to authenticated;
grant execute on function public.add_own_account_identifier(text, text)            to authenticated;

commit;
