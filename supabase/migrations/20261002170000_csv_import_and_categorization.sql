-- =====================================================================
--  20261002170000_csv_import_and_categorization.sql
--
--  CSV-/Excel-Import mit Duplikaterkennung und regelbasierter
--  Kategorisierung, Lernen aus manuellen Korrekturen.
--
--  Das Einlesen der Datei (Encoding, Trennzeichen, Kopfzeile, Spalten,
--  deutsches Zahlen-/Datumsformat) geschieht in der App (lib/import/). Hier
--  landen normalisierte Zeilen; die Datenbank prüft sie erneut.
--
--  1. categorization_rules.origin ('manual' | 'learned').
--  2. private.normalize_booking_text(): Kleinschreibung, Zahlenfolgen ab
--     vier Ziffern (Karten-, Transaktionsnummern) entfernt, Leerraum
--     zusammengefasst – für Regel-Abgleich und gelernte Muster.
--  3. private.extract_merchant(): wahrscheinlicher Händlername = Text des
--     Verwendungszwecks vor der ersten längeren Zahlenfolge (Fallback:
--     Empfänger), normalisiert, führende Wörter bis zum ersten Code mit
--     Ziffern (max. vier) – ein zusammenhängender Teil künftiger Texte.
--  4. private.match_category_rule(): erste passende Regel. Reihenfolge:
--     priority (vom Nutzer einstellbar), dann längeres = spezifischeres
--     Muster zuerst, dann ältere Regel.
--  5. public.create_categorization_rule(), public.reorder_categorization_rules().
--  6. public.import_transactions(): Zeilen prüfen, Hash, Duplikate
--     überspringen, Regeln anwenden – alles in einer Anweisung; mit
--     p_dry_run nur zählen (Vorschau).
--  7. public.set_transaction_category(): Kategorie ändern; bei importierten
--     oder synchronisierten Buchungen daraus eine Regel lernen.
--
--  Alle öffentlichen Funktionen SECURITY INVOKER – RLS gilt; Berater
--  (nur SELECT auf Mandantendaten) können nichts schreiben.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. Herkunft einer Regel
-- ---------------------------------------------------------------------
alter table public.categorization_rules
  add column origin text not null default 'manual' check (origin in ('manual', 'learned'));

comment on column public.categorization_rules.origin is
  'manual = vom Nutzer angelegt, learned = aus einer manuellen Kategorie-Korrektur gelernt.';
comment on column public.categorization_rules.priority is
  'Kleinere Zahl = früher geprüft. Bei gleicher Priorität gewinnt das längere (spezifischere) '
  'normalisierte Muster, dann die ältere Regel (private.match_category_rule).';

-- ---------------------------------------------------------------------
-- 2./3. Normalisierung und Händlername
-- ---------------------------------------------------------------------
create or replace function private.normalize_booking_text(p_text text)
returns text
language sql
immutable
parallel safe
set search_path = ''
as $$
  select btrim(regexp_replace(regexp_replace(regexp_replace(
           lower(coalesce(p_text, '')),
           '[^[:alnum:]&.+@ ]+', ' ', 'g'),   -- Trennzeichen wie * / - , ; zu Leerraum
           '\d{4,}', ' ', 'g'),               -- Karten-/Transaktionsnummern
           '\s+', ' ', 'g'));
$$;

comment on function private.normalize_booking_text(text) is
  'Kleinschreibung, Sonderzeichen außer & . + @ zu Leerraum, Zahlenfolgen ab 4 Ziffern entfernt, '
  'Leerraum zusammengefasst.';

create or replace function private.extract_merchant(p_purpose text, p_counterparty text)
returns text
language plpgsql
immutable
parallel safe
set search_path = ''
as $$
declare
  v_source text;
  v_merchant text;
begin
  foreach v_source in array array[p_purpose, p_counterparty] loop
    -- Text vor der ersten Zahlenfolge ab 4 Ziffern, normalisiert.
    v_merchant := private.normalize_booking_text(
      coalesce(substring(coalesce(v_source, '') from '^(.*?)\d{4,}'), coalesce(v_source, '')));
    -- Buchungsart-Präfixe („SEPA-Lastschrift“, „Kartenzahlung“ …) vorn entfernen.
    v_merchant := regexp_replace(v_merchant,
      '^((sepa|lastschrift|basislastschrift|folgelastschrift|erstlastschrift|kartenzahlung|kartenumsatz|'
      || 'ueberweisung|überweisung|gutschrift|dauerauftrag|einzug|abbuchung|zahlung|visa|mastercard|'
      || 'girocard|debitk|ec|pos|lastschrifteinzug)( |$))+', '');
    -- Führende Wörter bis zum ersten Wort mit Ziffern (Buchungscode wie
    -- „ab12“) – das erste Wort darf Ziffern haben („1&1“, „o2“). So bleibt
    -- das Muster ein zusammenhängender Teil künftiger Buchungstexte.
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
    if char_length(v_merchant) >= 3 and v_merchant ~ '[[:alpha:]]' then
      return v_merchant;
    end if;
  end loop;
  return null;
end;
$$;

comment on function private.extract_merchant(text, text) is
  'Wahrscheinlicher Händlername: Verwendungszweck vor der ersten Zahlenfolge ab 4 Ziffern, '
  'normalisiert, ohne Buchungsart-Präfix, führende Wörter bis zum ersten Code mit Ziffern '
  '(max. 4); Fallback Empfänger; NULL wenn nichts Brauchbares.';

-- ---------------------------------------------------------------------
-- 4. Regel-Abgleich
-- ---------------------------------------------------------------------
-- contains / equals / starts_with vergleichen normalisierte Texte (Muster
-- ebenso normalisiert, case_sensitive entfällt dabei); regex prüft den
-- Rohtext. counterparty_or_purpose prüft beide Felder getrennt.
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
  select r.category_id
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
           ('counterparty', p_counterparty),
           ('purpose',      p_purpose)
         ) as f (field, raw)
        where f.raw is not null
          and (r.match_field = 'counterparty_or_purpose' or r.match_field::text = f.field)
          and case r.match_type
                when 'contains'    then n.np <> '' and position(n.np in private.normalize_booking_text(f.raw)) > 0
                when 'equals'      then n.np <> '' and private.normalize_booking_text(f.raw) = n.np
                when 'starts_with' then n.np <> '' and starts_with(private.normalize_booking_text(f.raw), n.np)
                when 'regex'       then case when r.case_sensitive then f.raw ~ r.pattern else f.raw ~* r.pattern end
              end
     )
   order by r.priority, char_length(n.np) desc, r.created_at, r.id
   limit 1;
$$;

comment on function private.match_category_rule(uuid, uuid, numeric, text, text) is
  'Kategorie der ersten passenden aktiven Regel (priority, dann längeres Muster, dann älter) oder NULL.';

-- Priorität für eine neue Regel: gleich der ersten allgemeineren Regel,
-- deren Muster im neuen enthalten ist (das längere Muster gewinnt dann den
-- Gleichstand), sonst ans Ende. So bleibt „amazon prime“ vor „amazon“,
-- auch nachdem der Nutzer die Reihenfolge angepasst hat.
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
        and private.normalize_booking_text(r.pattern) <> ''
        and private.normalize_booking_text(r.pattern) <> private.normalize_booking_text(p_pattern)
        and position(private.normalize_booking_text(r.pattern) in private.normalize_booking_text(p_pattern)) > 0),
    (select max(r.priority) + 1 from public.categorization_rules r where r.user_id = p_user_id),
    1
  ))::smallint;
$$;

-- ---------------------------------------------------------------------
-- 5. Regeln anlegen und ordnen
-- ---------------------------------------------------------------------
create or replace function public.create_categorization_rule(p_pattern text, p_category_id uuid)
returns uuid
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_uid     uuid := auth.uid();
  v_pattern text := private.normalize_booking_text(p_pattern);
  v_id      uuid;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if char_length(v_pattern) < 2 or char_length(v_pattern) > 200 then
    raise exception 'invalid_pattern' using errcode = '22023';
  end if;
  if not exists (select 1 from public.categories c where c.id = p_category_id and c.user_id = v_uid) then
    raise exception 'category_not_found' using errcode = 'P0002';
  end if;
  if exists (
    select 1 from public.categorization_rules r
     where r.user_id = v_uid and r.match_type = 'contains'
       and private.normalize_booking_text(r.pattern) = v_pattern
  ) then
    raise exception 'rule_exists' using errcode = '23505';
  end if;

  insert into public.categorization_rules (user_id, category_id, pattern, match_type, match_field, priority, origin)
  values (v_uid, p_category_id, v_pattern, 'contains', 'counterparty_or_purpose',
          private.priority_for_new_rule(v_uid, v_pattern), 'manual')
  returning id into v_id;
  return v_id;
end;
$$;

comment on function public.create_categorization_rule(text, uuid) is
  'Regel „Verwendungszweck/Empfänger enthält Muster → Kategorie“ anlegen (Muster normalisiert). '
  'Fehler: invalid_pattern (22023), category_not_found (P0002), rule_exists (23505).';

-- Neue Reihenfolge: p_ids enthält ALLE Regeln des Nutzers in gewünschter
-- Reihenfolge; priority wird 1..n.
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
  select count(*) into v_total from public.categorization_rules r where r.user_id = v_uid;
  if p_ids is null
     or cardinality(p_ids) <> v_total
     or v_total > 1000
     or (select count(distinct x) from unnest(p_ids) as x) <> v_total
     or exists (
       select 1 from unnest(p_ids) as x
        where not exists (select 1 from public.categorization_rules r where r.id = x and r.user_id = v_uid)
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
  'Alle eigenen Regeln in neuer Reihenfolge (priority 1..n). Fehler invalid_order (22023).';

-- ---------------------------------------------------------------------
-- 6. Import
-- ---------------------------------------------------------------------
-- Zeilen aus JSON prüfen. Fehler invalid_row (22023) mit der 1-basierten
-- Position im Array als DETAIL.
create or replace function private.import_rows(p_rows jsonb, p_default_currency public.currency_code)
returns table (
  ord           integer,
  booking_date  date,
  value_date    date,
  amount        numeric(14,2),
  currency      public.currency_code,
  counterparty  text,
  purpose       text
)
language plpgsql
stable
set search_path = ''
as $$
declare
  v_row    jsonb;
  v_ord    integer;
  v_amount numeric;
begin
  for v_row, v_ord in select e.value, e.ordinality::integer from jsonb_array_elements(p_rows) with ordinality as e loop
    begin
      ord          := v_ord;
      booking_date := (v_row ->> 'booking_date')::date;
      value_date   := nullif(v_row ->> 'value_date', '')::date;
      v_amount     := (v_row ->> 'amount')::numeric;
      currency     := coalesce(nullif(v_row ->> 'currency', ''), p_default_currency::text)::public.currency_code;
      counterparty := nullif(btrim(v_row ->> 'counterparty'), '');
      purpose      := nullif(btrim(v_row ->> 'purpose'), '');
    exception when others then
      raise exception 'invalid_row' using errcode = '22023', detail = v_ord::text;
    end;
    if jsonb_typeof(v_row) <> 'object'
       or booking_date is null or booking_date not between date '1900-01-01' and date '2100-12-31'
       or (value_date is not null and value_date not between date '1900-01-01' and date '2100-12-31')
       or v_amount is null or v_amount = 0 or v_amount <> round(v_amount, 2)
       or abs(v_amount) >= 1000000000000
       or char_length(counterparty) > 200
       or char_length(purpose) > 1000 then
      raise exception 'invalid_row' using errcode = '22023', detail = v_ord::text;
    end if;
    amount := v_amount;
    return next;
  end loop;
end;
$$;

-- Hash für die Duplikaterkennung: Datum + Betrag + Verwendungszweck
-- (klein, Leerraum zusammengefasst) + laufende Nummer gleicher Buchungen
-- innerhalb der Datei. Die Nummer hält zwei echte identische Buchungen
-- (zweimal Kaffee am selben Tag) auseinander; dieselbe Datei erneut
-- hochgeladen ergibt dieselben Hashes.
create or replace function private.import_hash(
  p_booking_date date,
  p_amount       numeric,
  p_purpose      text,
  p_occurrence   bigint
)
returns text
language sql
immutable
parallel safe
set search_path = ''
as $$
  select encode(sha256(convert_to(concat_ws('|',
    p_booking_date::text,
    round(p_amount, 2)::text,
    btrim(regexp_replace(lower(coalesce(p_purpose, '')), '\s+', ' ', 'g')),
    p_occurrence::text
  ), 'UTF8')), 'hex');
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

  -- Konto: vorhandenes eigenes manuelles/CSV-Konto oder neu anlegen.
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

  create temporary table if not exists pg_temp.import_batch (
    booking_date date, value_date date, amount numeric(14,2), currency public.currency_code,
    counterparty text, purpose text, import_hash text, category_id uuid, duplicate boolean
  ) on commit drop;
  truncate pg_temp.import_batch;

  insert into pg_temp.import_batch
  select r.booking_date, r.value_date, r.amount, r.currency, r.counterparty, r.purpose,
         private.import_hash(r.booking_date, r.amount, r.purpose,
           row_number() over (
             partition by r.booking_date, r.amount, btrim(regexp_replace(lower(coalesce(r.purpose, '')), '\s+', ' ', 'g'))
             order by r.ord)),
         null, false
    from private.import_rows(p_rows, v_currency) r;

  update pg_temp.import_batch b
     set duplicate = exists (
       select 1 from public.transactions t
        where t.account_id = v_account_id and t.import_hash = b.import_hash
     )
   where v_account_id is not null;

  update pg_temp.import_batch b
     set category_id = private.match_category_rule(v_uid, v_account_id, b.amount, b.counterparty, b.purpose)
   where not b.duplicate;

  select count(*) filter (where not b.duplicate),
         count(*) filter (where b.duplicate),
         count(*) filter (where not b.duplicate and b.category_id is not null)
    into v_new, v_duplicates, v_categorized
    from pg_temp.import_batch b;

  if not p_dry_run then
    insert into public.transactions (
      user_id, account_id, booking_date, value_date, amount, currency,
      counterparty_name, purpose, import_hash, source, category_id, categorization_source
    )
    select v_uid, v_account_id, b.booking_date, b.value_date, b.amount, b.currency,
           b.counterparty, b.purpose, b.import_hash, 'csv_import', b.category_id,
           case when b.category_id is not null then 'rule'::public.categorization_source end
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
  'Importiert normalisierte Zeilen [{booking_date, value_date?, amount, currency?, counterparty?, purpose?}] '
  'in ein eigenes manuelles/CSV-Konto (oder legt eines an); überspringt Duplikate (import_hash), '
  'wendet Regeln an. p_dry_run: nur zählen. Fehler (22023): invalid_rows, no_rows, too_many_rows, '
  'invalid_row (DETAIL = Position), account_not_importable, invalid_account_name, invalid_currency; '
  'account_not_found (P0002).';

-- ---------------------------------------------------------------------
-- 7. Kategorie ändern und lernen
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
    return jsonb_build_object('changed', false, 'learned_pattern', null, 'rule_id', null);
  end if;

  update public.transactions t
     set category_id = p_category_id,
         categorization_source = case when p_category_id is null then null else 'manual'::public.categorization_source end
   where t.id = p_id;

  -- Lernen nur bei importierten/synchronisierten Buchungen: manuell
  -- erfasste haben der Nutzer ohnehin selbst eingegeben.
  if p_category_id is not null and v_source <> 'manual' then
    v_pattern := private.extract_merchant(v_purpose, v_counterparty);
    if v_pattern is not null then
      select r.id into v_rule_id
        from public.categorization_rules r
       where r.user_id = v_uid
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
    end if;
  end if;

  return jsonb_build_object('changed', true, 'learned_pattern', v_pattern, 'rule_id', v_rule_id);
end;
$$;

comment on function public.set_transaction_category(uuid, uuid) is
  'Kategorie einer eigenen Buchung setzen (categorization_source = manual). Bei importierten/'
  'synchronisierten Buchungen wird aus dem Händlernamen eine Regel gelernt bzw. aktualisiert. '
  'Fehler: transaction_not_found, category_not_found (P0002).';

-- ---------------------------------------------------------------------
-- Rechte
-- ---------------------------------------------------------------------
grant execute on function private.normalize_booking_text(text)                           to authenticated;
grant execute on function private.extract_merchant(text, text)                           to authenticated;
grant execute on function private.match_category_rule(uuid, uuid, numeric, text, text)   to authenticated;
grant execute on function private.priority_for_new_rule(uuid, text)                       to authenticated;
grant execute on function private.import_rows(jsonb, public.currency_code)                to authenticated;
grant execute on function private.import_hash(date, numeric, text, bigint)                to authenticated;

revoke all on function public.create_categorization_rule(text, uuid)                    from public, anon;
revoke all on function public.reorder_categorization_rules(uuid[])                      from public, anon;
revoke all on function public.import_transactions(uuid, jsonb, boolean, text, text)     from public, anon;
revoke all on function public.set_transaction_category(uuid, uuid)                      from public, anon;
grant execute on function public.create_categorization_rule(text, uuid)                 to authenticated;
grant execute on function public.reorder_categorization_rules(uuid[])                   to authenticated;
grant execute on function public.import_transactions(uuid, jsonb, boolean, text, text)  to authenticated;
grant execute on function public.set_transaction_category(uuid, uuid)                   to authenticated;

commit;
