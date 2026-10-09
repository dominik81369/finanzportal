-- =====================================================================
--  20261013100000_contracts_v2a.sql
--  Verträge V2a: Grundlagen für die Hinweise (V2b) und Jahreskosten
--
--  1. transactions.mandate_reference / creditor_id: SEPA-Mandatsreferenz
--     und Gläubiger-ID – aus eigenen Spalten des Kontoauszugs (Import) oder
--     aus dem Verwendungszweck („MREF+…“, „Mandatsreferenz: …“, „CRED+…“,
--     „Gläubiger-ID: …“). Ein Trigger liest sie beim Anlegen und Ändern aus,
--     sofern nicht gesetzt; der Bestand wird einmalig nachgetragen.
--  2. Import: neue Felder je Zeile, Anreichern vorhandener Buchungen bei
--     erneutem Import (wie Typ/IBAN/Beschreibung).
--  3. Verträge: recurring_contracts.mandate_reference / creditor_id aus der
--     letzten verknüpften Abbuchung. Das Mandat trennt zwei Verträge
--     derselben Gegenpartei nur, wenn beide Mandate parallel laufen
--     (zeitlich überlappende Abbuchungen); ein Mandatswechsel gilt als
--     Fortsetzung – in der Erkennung und beim Verknüpfen.
--  4. Gegenbuchungen: Gutschriften derselben Gegenpartei (Erstattung,
--     Rücklastschrift) mit Betrag innerhalb der Toleranz werden ab der
--     ersten Abbuchung mit dem Vertrag verknüpft. Termine, Betrag und
--     Mandat des Vertrags folgen nur den Abbuchungen.
--  5. public.contract_actuals(): Abbuchungen und Gegenbuchungen je Vertrag
--     in einem Zeitraum (Jahreskosten „tatsächlich“).
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. Mandatsreferenz und Gläubiger-ID
-- ---------------------------------------------------------------------
alter table public.transactions
  add column mandate_reference text check (char_length(mandate_reference) between 1 and 35),
  add column creditor_id       text check (creditor_id ~ '^[A-Z]{2}[0-9]{2}[A-Z0-9]{3}[A-Z0-9]{1,28}$');

comment on column public.transactions.mandate_reference is
  'SEPA-Mandatsreferenz (Lastschrift), aus dem Kontoauszug oder dem Verwendungszweck.';
comment on column public.transactions.creditor_id is
  'SEPA-Gläubiger-ID, aus dem Kontoauszug oder dem Verwendungszweck.';

alter table public.recurring_contracts
  add column mandate_reference text check (char_length(mandate_reference) between 1 and 35),
  add column creditor_id       text check (creditor_id ~ '^[A-Z]{2}[0-9]{2}[A-Z0-9]{3}[A-Z0-9]{1,28}$');

comment on column public.recurring_contracts.mandate_reference is
  'Mandatsreferenz der letzten verknüpften Abbuchung (private.update_contract_dates).';
comment on column public.recurring_contracts.creditor_id is
  'Gläubiger-ID der letzten verknüpften Abbuchung (private.update_contract_dates).';

-- SEPA-Kennungen im Verwendungszweck trennen („…ABCCRED+DE…“ → „…ABC CRED+DE…“).
create or replace function private.sepa_text(p_text text)
returns text
language sql
immutable
parallel safe
set search_path = ''
as $$
  select regexp_replace(coalesce(p_text, ''), '(EREF|KREF|MREF|CRED|SVWZ|ABWA|ABWE|PURP|IBAN|BIC)\+', ' \1+', 'g');
$$;

-- Mandatsreferenz aus dem Text: „MREF+…“, „Mandatsreferenz: …“,
-- „Mandatsref. …“, „Mandat: …“; höchstens 35 Zeichen (SEPA).
create or replace function private.extract_mandate_reference(p_text text)
returns text
language sql
immutable
parallel safe
set search_path = ''
as $$
  select case when char_length(r.ref) between 1 and 35 then r.ref end
    from (
      select regexp_replace(m[1], '[.,;:]+$', '') as ref
        from regexp_match(private.sepa_text(p_text),
          '(?:MREF[+:]|Mandatsref(?:erenz)?\.?:?|Mandat:|Mandate ?ref(?:erence)?:?)\s*([A-Za-z0-9+?/:().,''-]{1,36})(?:\s|$)',
          'i') m
    ) r;
$$;

-- Gläubiger-ID aus dem Text: „CRED+…“, „Gläubiger-ID: …“, „CI: …“ oder
-- frei stehend mit Geschäftsbereich „ZZZ“ (z. B. DE98ZZZ09999999999).
create or replace function private.extract_creditor_id(p_text text)
returns text
language sql
immutable
parallel safe
set search_path = ''
as $$
  select upper(coalesce(
    (regexp_match(private.sepa_text(p_text),
       '(?:CRED[+:]|Gl(?:ä|ae)ubiger-?ID:?|Gl(?:ä|ae)ubiger-?Identifikationsnummer:?|Creditor[ -]?ID:?|CI:)\s*([A-Z]{2}[0-9]{2}[A-Z0-9]{3}[A-Z0-9]{1,28})\M',
       'i'))[1],
    (regexp_match(coalesce(p_text, ''), '\m([A-Z]{2}[0-9]{2}ZZZ[0-9A-Z]{5,28})\M'))[1]));
$$;

comment on function private.extract_mandate_reference(text) is
  'Mandatsreferenz aus Verwendungszweck/Beschreibung (MREF+, Mandatsreferenz:, Mandatsref., Mandat:) oder NULL.';
comment on function private.extract_creditor_id(text) is
  'Gläubiger-ID aus Verwendungszweck/Beschreibung (CRED+, Gläubiger-ID:, CI: oder frei stehend mit ZZZ) oder NULL.';

-- Fehlende Werte beim Anlegen und Ändern aus Verwendungszweck und
-- Beschreibung lesen; gesetzte Werte (z. B. eigene Spalte im Auszug) bleiben.
-- SECURITY DEFINER: auch für service_role und Kaskaden (wie die übrigen
-- Trigger auf transactions).
create or replace function private.transactions_set_sepa_refs()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.mandate_reference is null then
    new.mandate_reference := private.extract_mandate_reference(concat_ws(' ', new.purpose, new.description));
  end if;
  if new.creditor_id is null then
    new.creditor_id := private.extract_creditor_id(concat_ws(' ', new.purpose, new.description));
  end if;
  return new;
end;
$$;

create trigger transactions_sepa_refs
  before insert or update of purpose, description, mandate_reference, creditor_id on public.transactions
  for each row execute function private.transactions_set_sepa_refs();

-- Bestand nachtragen (nur Buchungen, deren Text überhaupt in Frage kommt).
update public.transactions t
   set mandate_reference = coalesce(t.mandate_reference,
                                    private.extract_mandate_reference(concat_ws(' ', t.purpose, t.description))),
       creditor_id       = coalesce(t.creditor_id,
                                    private.extract_creditor_id(concat_ws(' ', t.purpose, t.description)))
 where (t.mandate_reference is null or t.creditor_id is null)
   and concat_ws(' ', t.purpose, t.description) ~* '(mref|mandat|cred|gl(ä|ae)ubiger|creditor|ci:|zzz)';

-- ---------------------------------------------------------------------
-- 2. Import
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
  description       text,
  mandate_reference text,
  creditor_id       text
)
language plpgsql
stable
set search_path = ''
as $$
declare
  v_row      jsonb;
  v_ord      integer;
  v_amount   numeric;
  v_iban     text;
  v_mandate  text;
  v_creditor text;
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
      v_mandate        := nullif(btrim(v_row ->> 'mandate_reference'), '');
      v_creditor       := upper(regexp_replace(coalesce(v_row ->> 'creditor_id', ''), '\s', '', 'g'));
    exception when others then
      raise exception 'invalid_row' using errcode = '22023', detail = v_ord::text;
    end;
    -- Ungültige IBAN, Mandatsreferenz oder Gläubiger-ID verwerfen statt die
    -- Zeile abzulehnen (Banken liefern dort teils andere Angaben).
    counterparty_iban := case when v_iban ~ '^[A-Z]{2}[0-9]{2}[0-9A-Z]{11,30}$' then v_iban end;
    mandate_reference := case when char_length(v_mandate) <= 35 then v_mandate end;
    creditor_id       := case when v_creditor ~ '^[A-Z]{2}[0-9]{2}[A-Z0-9]{3}[A-Z0-9]{1,28}$' then v_creditor end;
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

grant execute on function private.import_rows(jsonb, public.currency_code) to authenticated;

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

  -- Mehrfachaufruf in einer Transaktion (Vorschau + Import, Tests).
  if to_regclass('pg_temp.import_batch') is not null then
    drop table pg_temp.import_batch;
  end if;
  create temporary table import_batch (
    booking_date date, value_date date, amount numeric(14,2), currency public.currency_code,
    counterparty text, purpose text, transaction_type text, counterparty_iban text, description text,
    mandate_reference text, creditor_id text, import_hash text, category_id uuid, rule_id uuid, source public.categorization_source, duplicate boolean,
    existing_id uuid, enrich boolean, existing_uncategorized boolean
  ) on commit drop;

  insert into pg_temp.import_batch
  select r.booking_date, r.value_date, r.amount, r.currency, r.counterparty, r.purpose,
         r.transaction_type, r.counterparty_iban, r.description, r.mandate_reference, r.creditor_id,
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
               or (t.description is null and b.description is not null)
               or (t.mandate_reference is null and b.mandate_reference is not null)
               or (t.creditor_id is null and b.creditor_id is not null),
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
      mandate_reference, creditor_id, import_hash, source, category_id, categorization_source, categorization_rule_id,
      auto_category_id, auto_source, auto_rule_id
    )
    select v_uid, v_account_id, b.booking_date, b.value_date, b.amount, b.currency,
           b.counterparty, b.purpose, b.transaction_type, b.counterparty_iban, b.description,
           b.mandate_reference, b.creditor_id, b.import_hash, 'csv_import', b.category_id, b.source, b.rule_id,
           b.category_id, b.source, b.rule_id
      from pg_temp.import_batch b
     where not b.duplicate
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
       and t.user_id = v_uid;
    get diagnostics v_enriched = row_count;

    perform private.refresh_recurrence(v_uid);
    -- Schicht 6: Klassifikator für alles, was noch offen ist.
    select b.assigned, b.suggested into v_learned, v_suggested from private.bayes_run(v_uid, true) b;
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
    'learned',     v_learned,
    'suggested',   v_suggested,
    'balance',     v_balance,
    'dry_run',     p_dry_run
  );
end;
$$;

-- ---------------------------------------------------------------------
-- 3. Mandat und Gegenbuchungen bei Verträgen
-- ---------------------------------------------------------------------
-- Zwei Mandate derselben Gegenpartei laufen parallel, wenn sich die
-- Zeiträume ihrer Abbuchungen überlappen. Sonst ist das neue Mandat die
-- Fortsetzung des alten (z. B. neues Mandat nach Vertragsänderung).
create or replace function private.mandates_parallel(
  p_user_id  uuid,
  p_key      text,
  p_currency text,
  p_mandate1 text,
  p_mandate2 text
)
returns boolean
language sql
stable
set search_path = ''
as $$
  select coalesce(a.lo <= b.hi and b.lo <= a.hi, false)
    from (select min(t.booking_date) as lo, max(t.booking_date) as hi
            from public.transactions t
           where t.user_id = p_user_id and t.counterparty_key = p_key and t.currency::text = p_currency
             and t.amount < 0 and t.mandate_reference = p_mandate1) a,
         (select min(t.booking_date) as lo, max(t.booking_date) as hi
            from public.transactions t
           where t.user_id = p_user_id and t.counterparty_key = p_key and t.currency::text = p_currency
             and t.amount < 0 and t.mandate_reference = p_mandate2) b;
$$;

comment on function private.mandates_parallel(uuid, text, text, text, text) is
  'true, wenn sich die Abbuchungszeiträume zweier Mandate derselben Gegenpartei überlappen.';

-- Bestätigte Verträge: neue Abbuchungen und Gegenbuchungen (Gutschriften
-- derselben Gegenpartei ab der ersten Abbuchung) verknüpfen. Ein anderes,
-- parallel laufendes Mandat schließt die Buchung aus; bei mehreren
-- Kandidaten gewinnt das gleiche Mandat, dann der nächste Betrag.
create or replace function private.link_contract_bookings(p_user_id uuid)
returns integer
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_linked integer;
begin
  with cand as (
    select distinct on (t.id) t.id, rc.id as contract_id
      from public.transactions t
      join public.recurring_contracts rc
        on rc.user_id = t.user_id
       and rc.counterparty_key = t.counterparty_key
       and rc.currency = t.currency
      left join public.recurring_contracts cur on cur.id = t.recurring_contract_id
     where t.user_id = p_user_id
       and not t.contract_link_manual
       and (t.recurring_contract_id is null or cur.status in ('suggested', 'dismissed'))
       and rc.status in ('active', 'cancellation_pending', 'cancelled')
       and rc.expected_amount is not null
       and abs(abs(t.amount) - abs(rc.expected_amount)) <= abs(rc.expected_amount) * rc.amount_tolerance_pct / 100
       and (t.amount < 0 or (rc.first_booking_date is not null and t.booking_date >= rc.first_booking_date))
       and (rc.mandate_reference is null or t.mandate_reference is null
            or rc.mandate_reference = t.mandate_reference
            or not private.mandates_parallel(p_user_id, rc.counterparty_key, rc.currency::text,
                                             rc.mandate_reference, t.mandate_reference))
     order by t.id,
              (rc.mandate_reference is not distinct from t.mandate_reference) desc,
              abs(abs(t.amount) - abs(rc.expected_amount)), rc.created_at, rc.id
  )
  update public.transactions t
     set recurring_contract_id = cand.contract_id
    from cand
   where t.id = cand.id
     and t.user_id = p_user_id
     and t.recurring_contract_id is distinct from cand.contract_id;
  get diagnostics v_linked = row_count;
  return v_linked;
end;
$$;

-- Erste/letzte Abbuchung, Mandat und Gläubiger-ID aus den verknüpften
-- Abbuchungen (Gegenbuchungen zählen nicht); die nächste erwartete rückt
-- nach, sobald die erwartete Abbuchung eingegangen ist (bei Vorschlägen
-- immer letzte + Periode). Manuell eingetragene spätere Termine bleiben.
create or replace function private.update_contract_dates(p_user_id uuid)
returns void
language plpgsql
volatile
set search_path = ''
as $$
begin
  with agg as (
    select t.recurring_contract_id as id, min(t.booking_date) as first_date, max(t.booking_date) as last_date,
           (array_agg(t.mandate_reference order by t.booking_date desc, t.id)
              filter (where t.mandate_reference is not null))[1] as mandate,
           (array_agg(t.creditor_id order by t.booking_date desc, t.id)
              filter (where t.creditor_id is not null))[1] as creditor
      from public.transactions t
     where t.user_id = p_user_id and t.recurring_contract_id is not null and t.amount < 0
     group by 1
  )
  update public.recurring_contracts rc
     set first_booking_date = agg.first_date,
         last_booking_date  = agg.last_date,
         mandate_reference  = agg.mandate,
         creditor_id        = agg.creditor,
         next_expected_date = case
           when rc.status = 'suggested'
             or rc.next_expected_date is null
             or rc.next_expected_date <= agg.last_date + private.contract_period(rc.rhythm, rc.interval_count) / 2
           then (agg.last_date + private.contract_period(rc.rhythm, rc.interval_count))::date
           else rc.next_expected_date
         end
    from agg
   where rc.id = agg.id
     and rc.user_id = p_user_id
     and (rc.first_booking_date is distinct from agg.first_date
          or rc.last_booking_date is distinct from agg.last_date
          or rc.mandate_reference is distinct from agg.mandate
          or rc.creditor_id is distinct from agg.creditor
          or rc.next_expected_date is null
          or (rc.status = 'suggested'
              and rc.next_expected_date is distinct from
                  (agg.last_date + private.contract_period(rc.rhythm, rc.interval_count))::date));

  -- Ohne verknüpfte Abbuchungen: keine erste/letzte Abbuchung, kein Mandat.
  update public.recurring_contracts rc
     set first_booking_date = null, last_booking_date = null, mandate_reference = null, creditor_id = null
   where rc.user_id = p_user_id
     and (rc.last_booking_date is not null or rc.mandate_reference is not null or rc.creditor_id is not null)
     and not exists (select 1 from public.transactions t
                      where t.user_id = p_user_id and t.recurring_contract_id = rc.id and t.amount < 0);
end;
$$;

-- Erkennung wie in V1, zusätzlich getrennt nach parallel laufenden Mandaten.
create or replace function private.refresh_contracts(p_user_id uuid)
returns jsonb
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_no       integer := 0;
  v_ids      uuid[] := '{}';
  v_key      text;
  v_currency text;
  v_mgroup   text;
  v_start    numeric;
  v_tx       record;
  v_s        record;
  v_c        record;
  v_iter     integer;
  v_changed  boolean;
  v_merge    boolean;
  v_edge     numeric;
  v_contract uuid;
  v_status   public.contract_status;
  v_matched  uuid[] := '{}';
  v_created  integer := 0;
  v_removed  integer := 0;
  v_linked   integer := 0;
  v_count    integer;
begin
  -- Gleichzeitige Läufe (zwei Tabs, Import) nacheinander.
  perform pg_advisory_xact_lock(hashtextextended('contracts:' || p_user_id::text, 0));

  -- 1. Bestätigte Verträge zuerst: neue Buchungen verknüpfen.
  v_linked := private.link_contract_bookings(p_user_id);

  -- 2. Kandidaten: Ausgaben mit Gegenpartei, ohne Umbuchungen und eigene Konten.
  if to_regclass('pg_temp.contract_tx') is not null then
    drop table pg_temp.contract_tx;
  end if;
  -- coverage: letzte Buchung des Kontos (Datenstand), um beendete Serien
  -- von noch nicht importierten Monaten zu unterscheiden.
  create temporary table contract_tx on commit drop as
  select t.id, t.counterparty_key as key, t.currency::text as currency, t.booking_date as d, abs(t.amount) as amt,
         t.account_id, t.category_id, c.default_key as category_key, t.counterparty_name, t.purpose,
         cov.coverage, t.mandate_reference as mandate, null::text as mgroup
    from public.transactions t
    left join public.categories c on c.id = t.category_id
    join (select a.account_id, max(a.booking_date) as coverage
            from public.transactions a where a.user_id = p_user_id group by a.account_id) cov
      on cov.account_id = t.account_id
   where t.user_id = p_user_id
     and t.amount < 0
     and t.counterparty_key is not null
     and c.default_key is distinct from 'transfer'
     and not exists (
       select 1 from public.categorization_rules r
        where r.user_id = p_user_id and r.origin = 'own_account' and r.is_active
          and r.match_field = 'counterparty_iban'
          and r.pattern = upper(regexp_replace(coalesce(t.counterparty_iban, ''), '\s', '', 'g')))
     and not exists (
       select 1 from public.categorization_rules r
        where r.user_id = p_user_id and r.origin = 'own_account' and r.is_active
          and r.match_field = 'counterparty' and t.counterparty_name is not null
          and not exists (
            select 1 from regexp_split_to_table(r.pattern, ' ') as w (word)
             where w.word <> ''
               and position(' ' || w.word || ' ' in ' ' || private.normalize_booking_text(t.counterparty_name) || ' ') = 0));
  create index on pg_temp.contract_tx (id);

  -- Mandat trennt nur parallel laufende Mandate derselben Gegenpartei
  -- (zeitlich überlappende Abbuchungen); ein Wechsel des Mandats gilt als
  -- Fortsetzung.
  with ranges as (
    select x.key, x.currency, x.mandate, min(x.d) as lo, max(x.d) as hi
      from pg_temp.contract_tx x
     where x.mandate is not null
     group by 1, 2, 3
  ), parallel as (
    select distinct a.key, a.currency, a.mandate
      from ranges a
      join ranges b on b.key = a.key and b.currency = a.currency and b.mandate <> a.mandate
                   and a.lo <= b.hi and b.lo <= a.hi
  )
  update pg_temp.contract_tx x
     set mgroup = x.mandate
    from parallel p
   where p.key = x.key and p.currency = x.currency and p.mandate = x.mandate;
  analyze pg_temp.contract_tx;

  if to_regclass('pg_temp.contract_series') is not null then
    drop table pg_temp.contract_series;
  end if;
  create temporary table contract_series (
    no             integer primary key,
    key            text,
    currency       text,
    mgroup         text,
    ids            uuid[],
    first_date     date,
    last_date      date,
    dates          integer,
    amount         numeric,
    rhythm_key     text,
    rhythm         public.contract_rhythm,
    interval_count integer,
    low            integer,
    high           integer,
    share          numeric,
    coverage       date,
    accepted       boolean not null default false,
    absorbed       boolean not null default false
  ) on commit drop;

  -- 3. Je Gegenpartei, Währung und parallelem Mandat nach Betrag bündeln
  --    (bis +20 % über dem kleinsten der Gruppe).
  for v_tx in
    select x.id, x.key, x.currency, x.mgroup, x.amt
      from pg_temp.contract_tx x
     order by x.key, x.currency, x.mgroup nulls first, x.amt, x.d, x.id
  loop
    if v_key is distinct from v_tx.key or v_currency is distinct from v_tx.currency
       or v_mgroup is distinct from v_tx.mgroup or v_tx.amt > v_start * 1.2 then
      if cardinality(v_ids) > 0 then
        v_no := v_no + 1;
        insert into pg_temp.contract_series (no, key, currency, mgroup, ids) values (v_no, v_key, v_currency, v_mgroup, v_ids);
      end if;
      v_ids := '{}';
      v_key := v_tx.key;
      v_currency := v_tx.currency;
      v_mgroup := v_tx.mgroup;
      v_start := v_tx.amt;
    end if;
    v_ids := v_ids || v_tx.id;
  end loop;
  if cardinality(v_ids) > 0 then
    v_no := v_no + 1;
    insert into pg_temp.contract_series (no, key, currency, mgroup, ids) values (v_no, v_key, v_currency, v_mgroup, v_ids);
  end if;

  -- Kennzahlen und Rhythmus je Bündel.
  update pg_temp.contract_series s
     set first_date = st.first_date, last_date = st.last_date, dates = st.dates, amount = st.amount,
         rhythm_key = r.rhythm_key, rhythm = r.rhythm, interval_count = r.interval_count,
         low = r.low, high = r.high, share = r.share,
         accepted = coalesce(r.share >= 0.75
                             and ((cardinality(s.ids) >= 3 and r.intervals >= 2)
                                  or (r.rhythm in ('semiannual', 'yearly') and r.intervals >= 1)), false)
    from pg_temp.contract_series s2
    cross join lateral (
      select min(x.d) as first_date, max(x.d) as last_date, count(distinct x.d)::integer as dates,
             percentile_disc(0.5) within group (order by x.amt) as amount, array_agg(x.d) as all_dates
        from pg_temp.contract_tx x where x.id = any (s2.ids)
    ) st
    left join lateral private.series_rhythm(st.all_dates) r on true
   where s.no = s2.no;

  -- 4. Fortsetzung: zeitlich anschließende Bündel derselben Gegenpartei mit
  --    gleichem Rhythmus und höchstens 50 % Betragsunterschied zur
  --    angrenzenden Abbuchung anhängen (Preisänderung).
  loop
    v_changed := false;
    for v_iter in
      select s.no from pg_temp.contract_series s
       where s.accepted and not s.absorbed
       order by cardinality(s.ids) desc, s.no
    loop
      select * into v_s from pg_temp.contract_series s where s.no = v_iter;
      continue when v_s.absorbed;
      for v_c in
        select c.* from pg_temp.contract_series c
         where c.key = v_s.key and c.currency = v_s.currency and c.no <> v_s.no and not c.absorbed
           and c.mgroup is not distinct from v_s.mgroup
           and (c.dates = 1 or c.rhythm_key = v_s.rhythm_key)
         order by c.first_date, c.no
      loop
        v_merge := false;
        if v_c.first_date > v_s.last_date and v_c.first_date - v_s.last_date between v_s.low and v_s.high then
          select x.amt into v_edge from pg_temp.contract_tx x
           where x.id = any (v_s.ids) order by x.d desc, x.amt desc limit 1;
          v_merge := greatest(v_edge, v_c.amount) <= least(v_edge, v_c.amount) * 1.5;
        elsif v_c.last_date < v_s.first_date and v_s.first_date - v_c.last_date between v_s.low and v_s.high then
          select x.amt into v_edge from pg_temp.contract_tx x
           where x.id = any (v_s.ids) order by x.d, x.amt limit 1;
          v_merge := greatest(v_edge, v_c.amount) <= least(v_edge, v_c.amount) * 1.5;
        end if;
        if v_merge then
          update pg_temp.contract_series s
             set ids = s.ids || v_c.ids,
                 first_date = least(s.first_date, v_c.first_date),
                 last_date = greatest(s.last_date, v_c.last_date)
           where s.no = v_s.no;
          update pg_temp.contract_series s set absorbed = true where s.no = v_c.no;
          v_changed := true;
          exit;
        end if;
      end loop;
    end loop;
    exit when not v_changed;
  end loop;

  -- Endgültige Serien: Anteil regelmäßiger Abstände über alle Tage; Betrag
  -- = Median der letzten drei Abbuchungen (bei zwei: die letzte).
  update pg_temp.contract_series s
     set dates = st.dates,
         share = coalesce(r.share, 0),
         amount = st.amount,
         coverage = st.coverage
    from pg_temp.contract_series s2
    cross join lateral (
      select count(distinct x.d)::integer as dates, array_agg(x.d) as all_dates, max(x.coverage) as coverage,
             case when count(*) >= 3
                  then (select percentile_disc(0.5) within group (order by l.amt)
                          from (select y.amt from pg_temp.contract_tx y where y.id = any (s2.ids)
                                 order by y.d desc, y.amt desc limit 3) l)
                  else (select y.amt from pg_temp.contract_tx y where y.id = any (s2.ids)
                         order by y.d desc, y.amt desc limit 1)
             end as amount
        from pg_temp.contract_tx x where x.id = any (s2.ids)
    ) st
    left join lateral (
      select sr.share from private.series_rhythm(st.all_dates) sr where sr.rhythm_key = s2.rhythm_key
    ) r on true
   where s.no = s2.no and s.accepted and not s.absorbed;

  -- 5. Serien bestehenden Verträgen zuordnen oder als Vorschlag anlegen.
  --    Beendete Serien (seit über zwei Perioden keine Abbuchung, gemessen am
  --    Datenstand der Konten der Serie) zählen nicht.
  for v_s in
    select s.* from pg_temp.contract_series s
     where s.accepted and not s.absorbed
       and (s.last_date + 2 * private.contract_period(s.rhythm, s.interval_count))::date + 7 >= s.coverage
     order by cardinality(s.ids) desc, s.no
  loop
    v_contract := null;
    -- a) Vertrag, an dem schon Buchungen der Serie hängen.
    select t.recurring_contract_id into v_contract
      from public.transactions t
     where t.user_id = p_user_id and t.id = any (v_s.ids) and t.recurring_contract_id is not null
     group by 1
     order by count(*) desc, 1
     limit 1;
    -- b) Fortsetzung eines Vertrags gleicher Gegenpartei und gleichen
    --    Rhythmus bis ±50 %, zeitlich nicht parallel zu dessen Buchungen.
    if v_contract is null then
      select rc.id into v_contract
        from public.recurring_contracts rc
        left join lateral (
          select min(t.booking_date) as first_date, max(t.booking_date) as last_date
            from public.transactions t
           where t.user_id = p_user_id and t.recurring_contract_id = rc.id
        ) l on true
       where rc.user_id = p_user_id
         and rc.counterparty_key = v_s.key
         and rc.currency::text = v_s.currency
         and rc.rhythm = v_s.rhythm and rc.interval_count = v_s.interval_count
         and rc.status <> 'dismissed'
         and (v_s.mgroup is null or rc.mandate_reference is null or rc.mandate_reference = v_s.mgroup)
         and rc.expected_amount is not null
         and greatest(abs(rc.expected_amount), v_s.amount) <= least(abs(rc.expected_amount), v_s.amount) * 1.5
         and not (l.first_date is not null and v_s.first_date < l.last_date and l.first_date < v_s.last_date)
       order by greatest(abs(rc.expected_amount), v_s.amount) / least(abs(rc.expected_amount), v_s.amount),
                rc.created_at, rc.id
       limit 1;
    end if;
    -- c) Verworfen: gleiche Gegenpartei und gleicher Rhythmus bis ±20 %.
    if v_contract is null then
      select rc.id into v_contract
        from public.recurring_contracts rc
       where rc.user_id = p_user_id
         and rc.counterparty_key = v_s.key
         and rc.currency::text = v_s.currency
         and rc.rhythm = v_s.rhythm and rc.interval_count = v_s.interval_count
         and rc.status = 'dismissed'
         and (v_s.mgroup is null or rc.mandate_reference is null or rc.mandate_reference = v_s.mgroup)
         and rc.expected_amount is not null
         and greatest(abs(rc.expected_amount), v_s.amount) <= least(abs(rc.expected_amount), v_s.amount) * 1.2
       order by rc.updated_at desc, rc.id
       limit 1;
    end if;

    if v_contract is not null then
      select rc.status into v_status from public.recurring_contracts rc where rc.id = v_contract;
      -- Vorschlag (einmal je Lauf) mit dem aktuellen Stand der Serie.
      if v_status = 'suggested' and not v_contract = any (v_matched) then
        update public.recurring_contracts rc
           set expected_amount      = -v_s.amount,
               rhythm               = v_s.rhythm,
               interval_count       = v_s.interval_count,
               detection_confidence = private.series_confidence(v_s.dates, v_s.share)
         where rc.id = v_contract and rc.user_id = p_user_id;
        update public.transactions t
           set recurring_contract_id = v_contract
          from (select x.id from public.transactions x
                  left join public.recurring_contracts cur on cur.id = x.recurring_contract_id
                 where x.user_id = p_user_id and x.id = any (v_s.ids) and not x.contract_link_manual
                   and (x.recurring_contract_id is null or cur.status = 'dismissed')) f
         where t.id = f.id and t.user_id = p_user_id;
        get diagnostics v_count = row_count;
        v_linked := v_linked + v_count;
      end if;
      v_matched := v_matched || v_contract;
      continue;
    end if;

    -- d) Neuer Vorschlag.
    insert into public.recurring_contracts (
      user_id, name, counterparty_name, counterparty_key, account_id, category_id,
      rhythm, interval_count, expected_amount, currency, contract_type,
      status, detection_source, detection_confidence
    )
    select p_user_id,
           left(coalesce(
             case when v_s.key like 'm:%' then initcap(substr(v_s.key, 3)) end,
             mode() within group (order by btrim(x.counterparty_name)),
             case when v_s.key like 'n:%' then initcap(substr(v_s.key, 3)) end,
             mode() within group (order by btrim(x.purpose))), 120),
           left(mode() within group (order by btrim(x.counterparty_name)), 200),
           v_s.key,
           mode() within group (order by x.account_id),
           mode() within group (order by x.category_id),
           v_s.rhythm, v_s.interval_count, -v_s.amount, v_s.currency::public.currency_code,
           private.guess_contract_type(
             concat_ws(' ', case when v_s.key not like 'i:%' then substr(v_s.key, 3) end,
                       mode() within group (order by x.counterparty_name),
                       (array_agg(x.purpose order by x.d desc))[1]),
             mode() within group (order by x.category_key)),
           'suggested', 'auto', private.series_confidence(v_s.dates, v_s.share)
      from pg_temp.contract_tx x
     where x.id = any (v_s.ids)
    returning id into v_contract;
    v_created := v_created + 1;
    v_matched := v_matched || v_contract;

    update public.transactions t
       set recurring_contract_id = v_contract
     where t.user_id = p_user_id and t.id = any (v_s.ids)
       and not t.contract_link_manual and t.recurring_contract_id is null;
    get diagnostics v_count = row_count;
    v_linked := v_linked + v_count;
  end loop;

  -- 6. Vorschläge ohne passende Serie entfallen (Buchungen werden gelöst).
  delete from public.recurring_contracts rc
   where rc.user_id = p_user_id
     and rc.status = 'suggested'
     and rc.detection_source = 'auto'
     and not rc.id = any (v_matched);
  get diagnostics v_removed = row_count;

  perform private.update_contract_dates(p_user_id);

  return jsonb_build_object('created', v_created, 'removed', v_removed, 'linked', v_linked);
end;
$$;

comment on function private.refresh_contracts(uuid) is
  'Verknüpft Buchungen mit bestätigten Verträgen (auch Gegenbuchungen), erkennt Serien – getrennt nach '
  'parallel laufenden Mandaten – (Vorschläge anlegen/aktualisieren, verworfene unterdrücken, verwaiste '
  'entfernen) und führt Daten, Mandat und Gläubiger-ID nach. Liefert {created, removed, linked}.';

-- ---------------------------------------------------------------------
-- 4. Abbuchungen und Gegenbuchungen je Vertrag (Jahreskosten)
-- ---------------------------------------------------------------------
create or replace function public.contract_actuals(p_user_id uuid, p_from date, p_to date)
returns table (
  contract_id   uuid,
  currency      text,
  debit_count   integer,
  debits        numeric,
  credit_count  integer,
  credits       numeric
)
language sql
stable
security invoker
set search_path = ''
as $$
  select t.recurring_contract_id,
         t.currency::text,
         (count(*) filter (where t.amount < 0))::integer,
         coalesce(-sum(t.amount) filter (where t.amount < 0), 0),
         (count(*) filter (where t.amount > 0))::integer,
         coalesce(sum(t.amount) filter (where t.amount > 0), 0)
    from public.transactions t
   where t.user_id = p_user_id
     and t.recurring_contract_id is not null
     and t.booking_date between p_from and p_to
   group by 1, 2;
$$;

comment on function public.contract_actuals(uuid, date, date) is
  'Je Vertrag und Währung: Anzahl und Summe der verknüpften Abbuchungen (positiv) und Gegenbuchungen im '
  'Zeitraum (SECURITY INVOKER, RLS aktiv: eigene Daten bzw. die eines verbundenen Mandanten).';

-- ---------------------------------------------------------------------
-- Rechte
-- ---------------------------------------------------------------------
grant execute on function private.sepa_text(text)                                 to authenticated;
grant execute on function private.extract_mandate_reference(text)                 to authenticated;
grant execute on function private.extract_creditor_id(text)                       to authenticated;
grant execute on function private.transactions_set_sepa_refs()                    to authenticated;
grant execute on function private.mandates_parallel(uuid, text, text, text, text) to authenticated;

revoke all on function public.contract_actuals(uuid, date, date) from public, anon;
grant execute on function public.contract_actuals(uuid, date, date) to authenticated;

-- Bestand: Mandat und Gläubiger-ID der Verträge, Gegenbuchungen verknüpfen.
do $$
declare
  v_user uuid;
begin
  for v_user in select distinct rc.user_id from public.recurring_contracts rc loop
    perform private.link_contract_bookings(v_user);
    perform private.update_contract_dates(v_user);
  end loop;
end;
$$;

commit;
