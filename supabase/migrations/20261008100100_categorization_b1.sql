-- =====================================================================
--  20261008100100_categorization_b1.sql
--
--  Kategorisierung, PR B1:
--
--  3. Gegenpartei-Gedächtnis: transactions.counterparty_key =
--       i:<md5 der IBAN>        Gegenkonto-IBAN (kein Klartext im Schlüssel)
--       m:<händler>             bei Zahlungsvermittlern (PayPal, Klarna …)
--                               der Händler aus dem Verwendungszweck
--       n:<wörter sortiert>     sonst der Empfänger ohne Rechtsform/Titel
--       m:<händler>             ohne Empfänger: Händler aus dem Zweck
--     Hat der Nutzer eine Gegenpartei manuell immer gleich kategorisiert
--     (IBAN: ab 1 Zuordnung, sonst ab 2), bekommen weitere Buchungen diese
--     Kategorie automatisch (categorization_source = learned). Nur aus
--     manuellen Zuordnungen – nie aus gelernten (kein Selbsttraining).
--     Reihenfolge: eigene Regeln → Gedächtnis → eigene Konten (IBAN) →
--     Standardregeln. Namensvarianten ohne gleiche IBAN nur als Vorschlag.
--  4. Gruppenansicht: uncategorized_groups() (nach Gegenpartei, Anzahl
--     absteigend, mit Vorschlag) und categorize_group() (ganze Gruppe
--     manuell zuordnen → füttert das Gedächtnis).
--  5. Eigene Konten: Zielkategorie je IBAN wählbar; Namens-Treffer ohne
--     IBAN werden nicht mehr automatisch zugeordnet, nur vorgeschlagen.
--  6. Wiederkehrende Buchungen: transactions.recurrence (weekly, monthly,
--     quarterly, semiannual, yearly) – gleiche Gegenpartei, Betrag ±10 %,
--     mindestens 3 Buchungen in regelmäßigem Abstand.
--  7. Qualität: auto_category_id/auto_source/auto_rule_id halten die erste
--     automatische Zuordnung fest. Automatisierungsquote = Anteil
--     automatisch zugeordneter Buchungen; Treffsicherheit = Anteil davon,
--     deren Kategorie noch der automatischen entspricht. rule_quality()
--     zählt Treffer und Korrekturen je Regel.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- Zahlungsvermittler (ergänzt: secupay)
-- ---------------------------------------------------------------------
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
    || 'vr pay|ratepay|afterpay|riverty|mangopay|secupay|checkout\.com|paysafe|skrill) )');
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
               || 'concardis|ratepay|afterpay|riverty|mangopay|secupay|ihr|ihre|einkauf|bei|bestellung|zahlung|kauf|'
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


-- ---------------------------------------------------------------------
-- 3. Gegenpartei-Schlüssel
-- ---------------------------------------------------------------------
-- Empfängername vergleichbar machen: normalisiert, ohne Wörter mit Ziffern,
-- Rechtsformen, Anreden und Titel; Wörter eindeutig und sortiert
-- („MUSTERMANN, DOMINIK“ = „Dominik Mustermann“). NULL wenn leer.
create or replace function private.counterparty_name_key(p_name text)
returns text
language sql
immutable
parallel safe
set search_path = ''
as $$
  select nullif(string_agg(distinct w.word, ' ' order by w.word), '')
    from regexp_split_to_table(private.normalize_booking_text(p_name), '[ .&+@]+') as w (word)
   where char_length(w.word) >= 2
     and w.word !~ '[0-9]'
     and w.word !~ ('^(gmbh|mbh|ag|se|kg|kgaa|ohg|gbr|ug|ev|eg|co|ltd|limited|inc|corp|llc|sa|sas|sarl|bv|nv|ab|'
                    || 'cie|et|und|haftungsbeschraenkt|dr|prof|dipl|ing|med|herr|herrn|frau|hr|fr|familie|fam)$');
$$;

comment on function private.counterparty_name_key(text) is
  'Empfängername als Schlüssel: Wörter ohne Ziffern, Rechtsformen, Anreden, Titel; eindeutig und sortiert.';

create or replace function private.counterparty_key(p_iban text, p_counterparty text, p_purpose text)
returns text
language plpgsql
immutable
parallel safe
set search_path = ''
as $$
declare
  v_iban text := upper(regexp_replace(coalesce(p_iban, ''), '\s', '', 'g'));
  v_text text;
begin
  if v_iban ~ '^[A-Z]{2}[0-9]{2}[0-9A-Z]{11,30}$' then
    return 'i:' || md5(v_iban);
  end if;
  -- Zahlungsvermittler sind kein Schlüssel: der Händler aus dem Zweck zählt.
  if private.is_payment_processor(p_counterparty) or private.is_payment_processor(left(coalesce(p_purpose, ''), 40)) then
    v_text := private.extract_merchant(p_purpose, p_counterparty);
    return case when v_text is not null then 'm:' || v_text end;
  end if;
  v_text := private.counterparty_name_key(p_counterparty);
  if v_text is not null then
    return 'n:' || v_text;
  end if;
  v_text := private.merchant_candidate(p_purpose);
  return case when v_text is not null then 'm:' || v_text end;
end;
$$;

comment on function private.counterparty_key(text, text, text) is
  'Gegenpartei einer Buchung: i:<md5(IBAN)>, bei Zahlungsvermittlern m:<Händler aus dem Zweck>, sonst '
  'n:<Empfängername-Schlüssel> bzw. m:<Händler aus dem Zweck>; NULL wenn nichts Brauchbares.';

-- ---------------------------------------------------------------------
-- Neue Spalten
-- ---------------------------------------------------------------------
alter table public.transactions
  add column counterparty_key text check (char_length(counterparty_key) <= 300),
  add column recurrence text check (recurrence in ('weekly', 'monthly', 'quarterly', 'semiannual', 'yearly')),
  add column auto_category_id uuid,
  add column auto_source public.categorization_source,
  add column auto_rule_id uuid,
  add constraint transactions_auto_category_fkey
    foreign key (auto_category_id, user_id) references public.categories (id, user_id)
    on delete set null (auto_category_id),
  add constraint transactions_auto_rule_fkey
    foreign key (auto_rule_id, user_id) references public.categorization_rules (id, user_id)
    on delete set null (auto_rule_id);

comment on column public.transactions.counterparty_key is
  'Gegenpartei (private.counterparty_key): Grundlage für Gedächtnis, Gruppen und wiederkehrende Buchungen.';
comment on column public.transactions.recurrence is
  'Wiederkehrend (gleiche Gegenpartei, ähnlicher Betrag, regelmäßiger Abstand): weekly … yearly.';
comment on column public.transactions.auto_category_id is
  'Erste automatisch vergebene Kategorie (für Treffsicherheit: weicht category_id ab, wurde korrigiert).';
comment on column public.transactions.auto_source is 'Herkunft der ersten automatischen Zuordnung (rule/learned).';
comment on column public.transactions.auto_rule_id is 'Regel der ersten automatischen Zuordnung (bei rule).';

create index transactions_user_counterparty_key_idx
  on public.transactions (user_id, counterparty_key) where counterparty_key is not null;
create index transactions_auto_rule_idx
  on public.transactions (auto_rule_id) where auto_rule_id is not null;

-- SECURITY DEFINER: auch Schreibzugriffe von service_role (ohne Rechte auf
-- private) und Kaskaden setzen den Schlüssel.
create or replace function private.transactions_set_counterparty_key()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  new.counterparty_key := private.counterparty_key(new.counterparty_iban, new.counterparty_name, new.purpose);
  return new;
end;
$$;

create trigger transactions_counterparty_key
  before insert or update of counterparty_iban, counterparty_name, purpose on public.transactions
  for each row execute function private.transactions_set_counterparty_key();

-- ---------------------------------------------------------------------
-- 3. Gedächtnis
-- ---------------------------------------------------------------------
-- Manuelle Zuordnungen einer Gegenpartei: Anzahl und ob immer gleich.
create or replace function private.memory_lookup(p_user_id uuid, p_key text)
returns table (category_id uuid, manual_count integer, consistent boolean)
language sql
stable
set search_path = ''
as $$
  select (array_agg(t.category_id))[1],
         count(*)::integer,
         count(distinct t.category_id) = 1
    from public.transactions t
   where t.user_id = p_user_id
     and t.counterparty_key = p_key
     and t.categorization_source = 'manual'
     and t.category_id is not null
  having count(*) > 0;
$$;

-- Kategorie aus dem Gedächtnis: immer gleich und genug Zuordnungen
-- (IBAN ab 1, sonst ab 2). NULL sonst.
create or replace function private.memory_category(p_user_id uuid, p_key text)
returns uuid
language sql
stable
set search_path = ''
as $$
  select m.category_id
    from private.memory_lookup(p_user_id, p_key) m
   where p_key is not null
     and m.consistent
     and m.manual_count >= case when p_key like 'i:%' then 1 else 2 end;
$$;

-- ---------------------------------------------------------------------
-- Regel-Abgleich mit Herkunft; Klassifikation in Schichten
-- ---------------------------------------------------------------------
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
   order by case r.origin when 'standard' then 2 when 'own_account' then 1 else 0 end,
            r.priority, char_length(n.np) desc, r.created_at, r.id
   limit 1;
$$;

-- Bisherige Schnittstelle: erste Regel über alle Herkünfte (ohne
-- Namensregeln eigener Konten, die nur noch vorschlagen).
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
                                   array['manual', 'learned', 'own_account', 'standard'], false) d;
$$;

-- Schichten: eigene Regeln → Gegenpartei-Gedächtnis → eigene Konten (IBAN)
-- → Standardregeln. source: rule bzw. learned (Gedächtnis).
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
                                   p_transaction_type, p_iban, array['own_account', 'standard'], false);
  if v_rule.rule_id is not null then
    return query select v_rule.category_id, 'rule'::public.categorization_source, v_rule.rule_id;
  end if;
end;
$$;

comment on function private.classify(uuid, uuid, numeric, text, text, text, text, text, text) is
  'Kategorie nach Schichten: eigene Regeln, Gegenpartei-Gedächtnis (learned), eigene Konten (IBAN), '
  'Standardregeln. Keine Zeile, wenn nichts passt.';

-- Regeln und Gedächtnis auf eigene Buchungen anwenden (siehe
-- public.apply_categorization_rules). p_rule_id: nur Zuordnungen dieser
-- Regel; p_overwrite_auto: auch automatisch (rule/learned) anders
-- zugeordnete ändern, nie manuelle.
create or replace function private.apply_rules_for_user(
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
      cross join lateral private.classify(p_user_id, t.account_id, t.amount, t.counterparty_name, t.purpose,
                                          t.description, t.transaction_type, t.counterparty_iban,
                                          t.counterparty_key) c
     where t.user_id = p_user_id
       and (t.category_id is null
            or (p_overwrite_auto and t.categorization_source in ('rule', 'learned')
                and t.category_id is distinct from c.category_id))
       and (p_rule_id is null or c.rule_id = p_rule_id);
    return v_count;
  end if;

  update public.transactions t
     set category_id            = c.category_id,
         categorization_source  = c.source,
         categorization_rule_id = c.rule_id,
         auto_category_id       = coalesce(t.auto_category_id, c.category_id),
         auto_source            = case when t.auto_category_id is null then c.source else t.auto_source end,
         auto_rule_id           = case when t.auto_category_id is null then c.rule_id else t.auto_rule_id end
    from public.transactions s
    cross join lateral private.classify(p_user_id, s.account_id, s.amount, s.counterparty_name, s.purpose,
                                        s.description, s.transaction_type, s.counterparty_iban,
                                        s.counterparty_key) c
   where s.id = t.id
     and t.user_id = p_user_id
     and (t.category_id is null
          or (p_overwrite_auto and t.categorization_source in ('rule', 'learned')
              and t.category_id is distinct from c.category_id))
     and (p_rule_id is null or c.rule_id = p_rule_id);
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- Automatische Zuordnungen (rule und learned) zurücksetzen; manuelle nie.
-- Kein Fall für die Treffsicherheit: auto_* wird mit geleert.
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
     set category_id = null, categorization_source = null, categorization_rule_id = null,
         auto_category_id = null, auto_source = null, auto_rule_id = null
   where t.user_id = v_uid
     and t.categorization_source in ('rule', 'learned');
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- Anteile: manuell, eigene Regel, Standardregel, gelernt, unkategorisiert.
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
                                       and coalesce(r.origin, 'manual') <> 'standard'),
    'standard',      count(*) filter (where t.categorization_source = 'rule' and r.origin = 'standard'),
    'learned',       count(*) filter (where t.categorization_source = 'learned'),
    'uncategorized', count(*) filter (where t.category_id is null)
  )
    from public.transactions t
    left join public.categorization_rules r on r.id = t.categorization_rule_id
   where t.user_id = (select auth.uid());
$$;

-- ---------------------------------------------------------------------
-- 7. Qualität
-- ---------------------------------------------------------------------
create or replace function public.categorization_quality()
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select jsonb_build_object(
    'total',     count(*),
    'automated', count(*) filter (where t.auto_category_id is not null),
    'accurate',  count(*) filter (where t.auto_category_id is not null and t.category_id = t.auto_category_id),
    'automation_rate', round(count(*) filter (where t.auto_category_id is not null)::numeric
                             / nullif(count(*), 0), 4),
    'accuracy',  round(count(*) filter (where t.auto_category_id is not null and t.category_id = t.auto_category_id)::numeric
                       / nullif(count(*) filter (where t.auto_category_id is not null), 0), 4)
  )
    from public.transactions t
   where t.user_id = (select auth.uid());
$$;

comment on function public.categorization_quality() is
  'Automatisierungsquote (automated/total) und Treffsicherheit (accurate/automated: Kategorie entspricht '
  'noch der ersten automatischen Zuordnung).';

-- Treffer und Korrekturen je Regel (und für das Gedächtnis als eine Zeile
-- mit rule_id NULL). flagged: mindestens p_min_hits Treffer und mehr als
-- p_max_error korrigiert.
create or replace function public.rule_quality(p_min_hits integer default 5, p_max_error numeric default 0.3)
returns table (
  rule_id   uuid,
  pattern   text,
  origin    text,
  is_active boolean,
  hits      integer,
  corrected integer,
  flagged   boolean
)
language sql
stable
security invoker
set search_path = ''
as $$
  with q as (
    select t.auto_rule_id, t.auto_source,
           count(*)::integer as hits,
           count(*) filter (where t.category_id is distinct from t.auto_category_id)::integer as corrected
      from public.transactions t
     where t.user_id = (select auth.uid())
       and t.auto_category_id is not null
     group by t.auto_rule_id, t.auto_source
  )
  select q.auto_rule_id, r.pattern,
         case when q.auto_rule_id is null then 'memory' else r.origin end,
         coalesce(r.is_active, true), q.hits, q.corrected,
         q.hits >= p_min_hits and q.corrected::numeric / q.hits > p_max_error
    from q
    left join public.categorization_rules r on r.id = q.auto_rule_id
   where q.auto_rule_id is not null or q.auto_source = 'learned'
   order by q.corrected::numeric / q.hits desc, q.hits desc;
$$;

create or replace function public.set_rule_active(p_rule_id uuid, p_active boolean)
returns void
language plpgsql
volatile
security invoker
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  update public.categorization_rules r
     set is_active = coalesce(p_active, false)
   where r.id = p_rule_id and r.user_id = auth.uid();
  if not found then
    raise exception 'rule_not_found' using errcode = 'P0002';
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- 6. Wiederkehrende Buchungen
-- ---------------------------------------------------------------------
-- Eine Serie (Buchungen gleicher Gegenpartei und ähnlichen Betrags)
-- auswerten: ab 3 Buchungen und regelmäßigem Abstand (mindestens 75 % der
-- Abstände im Band des Rhythmus) als wiederkehrend markieren.
create or replace function private.mark_recurring_series(p_ids uuid[])
returns integer
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_dates     date[];
  v_intervals integer[];
  v_median    integer;
  v_rhythm    text;
  v_low       integer;
  v_high      integer;
  v_regular   integer;
begin
  if cardinality(p_ids) < 3 then
    return 0;
  end if;
  select array_agg(t.booking_date order by t.booking_date) into v_dates
    from public.transactions t where t.id = any (p_ids);
  -- Abstände in Tagen; gleiche Tage zählen nicht.
  v_intervals := array(
    select v_dates[k + 1] - v_dates[k] from generate_series(1, cardinality(v_dates) - 1) k
     where v_dates[k + 1] > v_dates[k]);
  if cardinality(v_intervals) < 2 then
    return 0;
  end if;
  select percentile_disc(0.5) within group (order by x) into v_median from unnest(v_intervals) x;
  select r.rhythm, r.low, r.high into v_rhythm, v_low, v_high
    from (values ('weekly', 5, 9), ('monthly', 25, 36), ('quarterly', 80, 100),
                 ('semiannual', 170, 195), ('yearly', 350, 380)) as r (rhythm, low, high)
   where v_median between r.low and r.high;
  if v_rhythm is null then
    return 0;
  end if;
  select count(*) into v_regular from unnest(v_intervals) x where x between v_low and v_high;
  if v_regular::numeric / cardinality(v_intervals) < 0.75 then
    return 0;
  end if;
  update public.transactions t set recurrence = v_rhythm where t.id = any (p_ids);
  return cardinality(p_ids);
end;
$$;

-- Je Gegenpartei und Richtung Buchungen mit ähnlichem Betrag bündeln (bis
-- +20 % über dem kleinsten der Serie, also etwa ±10 % um die Mitte) und
-- jede Serie auswerten.
create or replace function private.refresh_recurrence(p_user_id uuid)
returns integer
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_group  record;
  v_tx     record;
  v_ids    uuid[];
  v_start  numeric;
  v_marked integer := 0;
begin
  update public.transactions t set recurrence = null
   where t.user_id = p_user_id and t.recurrence is not null;

  for v_group in
    select t.counterparty_key as key, sign(t.amount) as dir
      from public.transactions t
     where t.user_id = p_user_id and t.counterparty_key is not null
     group by 1, 2
    having count(*) >= 3
  loop
    v_ids := '{}';
    v_start := null;
    for v_tx in
      select t.id, abs(t.amount) as amount
        from public.transactions t
       where t.user_id = p_user_id and t.counterparty_key = v_group.key and sign(t.amount) = v_group.dir
       order by abs(t.amount), t.booking_date
    loop
      if v_start is not null and v_tx.amount > v_start * 1.2 then
        v_marked := v_marked + private.mark_recurring_series(v_ids);
        v_ids := '{}';
        v_start := null;
      end if;
      v_start := coalesce(v_start, v_tx.amount);
      v_ids := v_ids || v_tx.id;
    end loop;
    v_marked := v_marked + private.mark_recurring_series(v_ids);
  end loop;
  return v_marked;
end;
$$;

comment on function private.refresh_recurrence(uuid) is
  'Markiert wiederkehrende Buchungen (gleiche Gegenpartei und Richtung, Betrag ähnlich, mindestens 3, '
  'regelmäßiger Abstand) in transactions.recurrence neu. Liefert die Anzahl markierter Buchungen.';

-- ---------------------------------------------------------------------
-- 4. Gruppenansicht
-- ---------------------------------------------------------------------
-- Unkategorisierte Buchungen nach Gegenpartei, Anzahl absteigend. Vorschlag
-- (nur Hinweis, nie automatisch):
--   own_name – Namensregel eines eigenen Kontos passt
--   memory   – Gegenpartei schon manuell immer gleich zugeordnet
--   variant  – Namensvariante (Wörter Teilmenge/Obermenge) mit Gedächtnis
create or replace function public.uncategorized_groups(p_limit integer default 200)
returns table (
  group_key          text,
  label              text,
  tx_count           integer,
  total              numeric,
  currency           text,
  first_date         date,
  last_date          date,
  samples            text[],
  recurrence         text,
  suggestion_category_id uuid,
  suggestion_source  text,
  suggestion_detail  text
)
language sql
stable
security invoker
set search_path = ''
as $$
  with g as (
    select t.counterparty_key as key,
           mode() within group (order by coalesce(t.counterparty_name, t.purpose)) as label,
           count(*)::integer as tx_count,
           sum(t.amount) as total,
           mode() within group (order by t.currency)::text as currency,
           min(t.booking_date) as first_date,
           max(t.booking_date) as last_date,
           (array_agg(distinct left(coalesce(t.purpose, ''), 80)) filter (where t.purpose is not null))[1:3] as samples,
           mode() within group (order by t.recurrence) as recurrence
      from public.transactions t
     where t.user_id = (select auth.uid())
       and t.category_id is null
       and t.counterparty_key is not null
     group by t.counterparty_key
  )
  -- Bei Zahlungsvermittlern zuerst der Händler („kiosk eck · PayPal …“).
  select g.key,
         case when g.key like 'm:%' and private.is_payment_processor(g.label)
              then substr(g.key, 3) || ' · ' || g.label else g.label end,
         g.tx_count, g.total, g.currency, g.first_date, g.last_date, g.samples, g.recurrence,
         s.category_id, s.source, s.detail
    from g
    left join lateral (
      select x.category_id, x.source, x.detail
        from (
          -- Namensregel eines eigenen Kontos
          select r.category_id, 'own_name' as source, r.pattern as detail, 1 as prio
            from public.categorization_rules r
           where r.user_id = (select auth.uid())
             and r.origin = 'own_account' and r.match_field = 'counterparty' and r.is_active
             and not exists (
               select 1 from regexp_split_to_table(r.pattern, ' ') w (word)
                where w.word <> ''
                  and position(' ' || w.word || ' ' in ' ' || private.normalize_booking_text(g.label) || ' ') = 0)
          union all
          -- Gedächtnis dieser Gegenpartei (auch unter der Schwelle)
          select m.category_id, 'memory', m.manual_count::text, 2
            from private.memory_lookup((select auth.uid()), g.key) m
           where m.consistent
          union all
          -- Namensvariante mit Gedächtnis (nur Namen, keine IBAN)
          select v.category_id, 'variant', v.label, 3
            from (
              select o.counterparty_key as key,
                     (array_agg(o.category_id))[1] as category_id,
                     mode() within group (order by o.counterparty_name) as label
                from public.transactions o
               where o.user_id = (select auth.uid())
                 and o.categorization_source = 'manual'
                 and o.category_id is not null
                 and g.key like 'n:%'
                 and o.counterparty_key like 'n:%'
                 and o.counterparty_key <> g.key
                 and (string_to_array(substr(o.counterparty_key, 3), ' ') <@ string_to_array(substr(g.key, 3), ' ')
                      or string_to_array(substr(o.counterparty_key, 3), ' ') @> string_to_array(substr(g.key, 3), ' '))
               group by o.counterparty_key
              having count(distinct o.category_id) = 1
               order by count(*) desc
               limit 1
            ) v
        ) x
       order by x.prio
       limit 1
    ) s on true
   order by g.tx_count desc, abs(g.total) desc, g.key
   limit greatest(1, least(coalesce(p_limit, 200), 1000));
$$;

comment on function public.uncategorized_groups(integer) is
  'Unkategorisierte Buchungen nach Gegenpartei (Anzahl absteigend) mit Vorschlag: own_name, memory, variant.';

-- Ganze Gruppe manuell zuordnen (nur Buchungen ohne Kategorie). Die
-- Zuordnungen füttern das Gegenpartei-Gedächtnis für künftige Buchungen.
create or replace function public.categorize_group(p_key text, p_category_id uuid)
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
  if p_key is null or char_length(p_key) > 300 then
    raise exception 'invalid_group' using errcode = '22023';
  end if;
  if not exists (select 1 from public.categories c where c.id = p_category_id and c.user_id = v_uid) then
    raise exception 'category_not_found' using errcode = 'P0002';
  end if;
  update public.transactions t
     set category_id = p_category_id,
         categorization_source = 'manual',
         categorization_rule_id = null
   where t.user_id = v_uid
     and t.counterparty_key = p_key
     and t.category_id is null;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

comment on function public.categorize_group(text, uuid) is
  'Alle Buchungen ohne Kategorie einer Gegenpartei manuell zuordnen. Fehler: invalid_group (22023), '
  'category_not_found (P0002).';

-- ---------------------------------------------------------------------
-- 5. Eigene Konten: Zielkategorie je IBAN; Namen nur als Vorschlag
-- ---------------------------------------------------------------------
drop function public.add_own_account_identifier(text, text);

create function public.add_own_account_identifier(p_kind text, p_value text, p_category_id uuid default null)
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
    -- Mindestens zwei Wörter (Vor- und Nachname).
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

  if p_category_id is not null then
    select c.id into v_category from public.categories c where c.id = p_category_id and c.user_id = v_uid;
  else
    select c.id into v_category from public.categories c where c.user_id = v_uid and c.default_key = 'transfer';
  end if;
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

  if p_kind = 'name' then
    -- Nur Vorschlag (Gruppenansicht): zählen, nichts zuordnen.
    return jsonb_build_object('rule_id', v_id, 'applied', 0, 'suggested', (
      select count(*)
        from public.transactions t
        cross join lateral private.match_rule_detail(v_uid, t.account_id, t.amount, t.counterparty_name, t.purpose,
                                                     null, null, null, array['own_account'], true) d
       where t.user_id = v_uid and t.category_id is null and d.rule_id = v_id));
  end if;
  return jsonb_build_object('rule_id', v_id,
                            'applied', private.apply_rules_for_user(v_uid, v_id, false, true),
                            'suggested', 0);
end;
$$;

comment on function public.add_own_account_identifier(text, text, uuid) is
  'Eigenes Konto: p_kind iban (Zielkategorie p_category_id, Standard Umbuchung; sofort angewendet, auch auf '
  'automatisch anders zugeordnete) oder name (Vor- und Nachname; nur Vorschlag in der Gruppenansicht). '
  'Liefert {rule_id, applied, suggested}. Fehler: invalid_name, invalid_iban, invalid_kind (22023), '
  'category_not_found (P0002), rule_exists (23505).';

-- Zielkategorie eines eigenen Kontos ändern und neu anwenden (automatische
-- Zuordnungen dieser Regel werden angepasst, manuelle nie).
create or replace function public.set_own_account_category(p_rule_id uuid, p_category_id uuid)
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
   where r.id = p_rule_id and r.user_id = v_uid and r.origin = 'own_account';
  if not found then
    raise exception 'rule_not_found' using errcode = 'P0002';
  end if;
  return private.apply_rules_for_user(v_uid, p_rule_id, false, true);
end;
$$;

-- ---------------------------------------------------------------------
-- Import mit Schichten, Gedächtnis und wiederkehrenden Buchungen
-- ---------------------------------------------------------------------
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
  v_enriched    integer;
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
    import_hash text, category_id uuid, rule_id uuid, source public.categorization_source, duplicate boolean,
    existing_id uuid, enrich boolean, existing_uncategorized boolean
  ) on commit drop;

  insert into pg_temp.import_batch
  select r.booking_date, r.value_date, r.amount, r.currency, r.counterparty, r.purpose,
         r.transaction_type, r.counterparty_iban, r.description,
         private.import_hash(r.booking_date, r.amount, r.purpose,
           row_number() over (
             partition by r.booking_date, r.amount, btrim(regexp_replace(lower(coalesce(r.purpose, '')), '\s+', ' ', 'g'))
             order by r.ord)),
         null, null, null, false, null, false, false
    from private.import_rows(p_rows, v_currency) r;

  update pg_temp.import_batch b
     set duplicate = true,
         existing_id = t.id,
         -- Anreichern: vorhandene Buchung (z. B. vor diesen Spalten importiert)
         -- erhält fehlende Felder; vorhandene Werte bleiben unverändert.
         enrich = (t.transaction_type is null and b.transaction_type is not null)
               or (t.counterparty_iban is null and b.counterparty_iban is not null)
               or (t.description is null and b.description is not null),
         existing_uncategorized = t.category_id is null
    from public.transactions t
   where v_account_id is not null
     and t.account_id = v_account_id
     and t.import_hash = b.import_hash;

  -- Schichten: eigene Regeln, Gegenpartei-Gedächtnis, eigene Konten,
  -- Standardregeln – für neue Zeilen und für angereicherte Buchungen ohne
  -- Kategorie (Schicht 1 bleibt).
  update pg_temp.import_batch b
     set category_id = c.category_id, rule_id = c.rule_id, source = c.source
    from pg_temp.import_batch s
    cross join lateral private.classify(v_uid, v_account_id, s.amount, s.counterparty, s.purpose,
                                        s.description, s.transaction_type, s.counterparty_iban,
                                        private.counterparty_key(s.counterparty_iban, s.counterparty, s.purpose)) c
   where s.ctid = b.ctid
     and (not b.duplicate or (b.enrich and b.existing_uncategorized));

  select count(*) filter (where not b.duplicate),
         count(*) filter (where b.duplicate),
         count(*) filter (where b.category_id is not null),
         count(*) filter (where b.enrich)
    into v_new, v_duplicates, v_categorized, v_enriched
    from pg_temp.import_batch b;

  if not p_dry_run then
    insert into public.transactions (
      user_id, account_id, booking_date, value_date, amount, currency,
      counterparty_name, purpose, transaction_type, counterparty_iban, description,
      import_hash, source, category_id, categorization_source, categorization_rule_id,
      auto_category_id, auto_source, auto_rule_id
    )
    select v_uid, v_account_id, b.booking_date, b.value_date, b.amount, b.currency,
           b.counterparty, b.purpose, b.transaction_type, b.counterparty_iban, b.description,
           b.import_hash, 'csv_import', b.category_id, b.source, b.rule_id,
           b.category_id, b.source, b.rule_id
      from pg_temp.import_batch b
     where not b.duplicate
    on conflict (account_id, import_hash) where import_hash is not null do nothing;
    get diagnostics v_new = row_count;

    update public.transactions t
       set transaction_type       = coalesce(t.transaction_type, b.transaction_type),
           counterparty_iban      = coalesce(t.counterparty_iban, b.counterparty_iban),
           description            = coalesce(t.description, b.description),
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
       and t.user_id = v_uid;
    get diagnostics v_enriched = row_count;

    perform private.refresh_recurrence(v_uid);
  end if;

  select a.balance into v_balance from public.accounts a where a.id = v_account_id;

  return jsonb_build_object(
    'account_id',  v_account_id,
    'currency',    v_currency,
    'total',       v_total,
    'new',         v_new,
    'duplicates',  v_duplicates,
    'categorized', v_categorized,
    'enriched',    v_enriched,
    'balance',     v_balance,
    'dry_run',     p_dry_run
  );
end;
$$;

-- ---------------------------------------------------------------------
-- Kategorie ändern: Bestätigen auch für gelernte Zuordnungen
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
     where t.id = p_id and t.categorization_source in ('rule', 'learned');
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

comment on function public.import_transactions(uuid, jsonb, boolean, text, text) is
  'Importiert normalisierte Zeilen in ein eigenes manuelles/CSV-Konto (oder legt eines an); überspringt '
  'Duplikate (import_hash) und ergänzt bei ihnen fehlenden Typ/IBAN/Beschreibung; ordnet nach Schichten zu '
  '(eigene Regeln, Gegenpartei-Gedächtnis, eigene Konten, Standardregeln) und markiert wiederkehrende '
  'Buchungen. p_dry_run: nur zählen.';

-- ---------------------------------------------------------------------
-- Bestand: Schlüssel, erste automatische Zuordnung, Namens-Treffer eigener
-- Konten (jetzt nur Vorschlag), wiederkehrende Buchungen
-- ---------------------------------------------------------------------
update public.transactions t
   set counterparty_key = private.counterparty_key(t.counterparty_iban, t.counterparty_name, t.purpose);

update public.transactions t
   set auto_category_id = t.category_id, auto_source = t.categorization_source, auto_rule_id = t.categorization_rule_id
 where t.categorization_source = 'rule' and t.category_id is not null and t.auto_category_id is null;

update public.transactions t
   set category_id = null, categorization_source = null, categorization_rule_id = null,
       auto_category_id = null, auto_source = null, auto_rule_id = null
  from public.categorization_rules r
 where r.id = t.categorization_rule_id
   and t.categorization_source = 'rule'
   and r.origin = 'own_account'
   and r.match_field = 'counterparty';

do $$
declare
  v_user uuid;
begin
  for v_user in select distinct t.user_id from public.transactions t loop
    perform private.refresh_recurrence(v_user);
  end loop;
end;
$$;

-- ---------------------------------------------------------------------
-- Rechte
-- ---------------------------------------------------------------------
grant execute on function private.counterparty_name_key(text)                 to authenticated;
grant execute on function private.counterparty_key(text, text, text)          to authenticated;
grant execute on function private.memory_lookup(uuid, text)                   to authenticated;
grant execute on function private.memory_category(uuid, text)                 to authenticated;
grant execute on function private.match_rule_detail(uuid, uuid, numeric, text, text, text, text, text, text[], boolean) to authenticated;
grant execute on function private.classify(uuid, uuid, numeric, text, text, text, text, text, text) to authenticated;
grant execute on function private.mark_recurring_series(uuid[])               to authenticated;
grant execute on function private.refresh_recurrence(uuid)                    to authenticated;
grant execute on function private.transactions_set_counterparty_key()         to authenticated;

revoke all on function public.categorization_quality()                        from public, anon;
revoke all on function public.rule_quality(integer, numeric)                  from public, anon;
revoke all on function public.set_rule_active(uuid, boolean)                  from public, anon;
revoke all on function public.uncategorized_groups(integer)                   from public, anon;
revoke all on function public.categorize_group(text, uuid)                    from public, anon;
revoke all on function public.add_own_account_identifier(text, text, uuid)    from public, anon;
revoke all on function public.set_own_account_category(uuid, uuid)            from public, anon;
grant execute on function public.categorization_quality()                     to authenticated;
grant execute on function public.rule_quality(integer, numeric)               to authenticated;
grant execute on function public.set_rule_active(uuid, boolean)               to authenticated;
grant execute on function public.uncategorized_groups(integer)                to authenticated;
grant execute on function public.categorize_group(text, uuid)                 to authenticated;
grant execute on function public.add_own_account_identifier(text, text, uuid) to authenticated;
grant execute on function public.set_own_account_category(uuid, uuid)         to authenticated;

commit;
