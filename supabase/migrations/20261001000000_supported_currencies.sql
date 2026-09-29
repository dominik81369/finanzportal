-- =====================================================================
--  supabase/migrations/20261001000000_supported_currencies.sql
--  Mehrere Währungen (ohne Umrechnung)
--
--  1. currency_code erlaubt nur noch die unterstützten Währungen EUR, USD
--     und CHF (vorher jeder Code aus drei Großbuchstaben). Die Domain ist
--     die einzige Quelle dieser Liste; sie gilt für alle Spalten, die sie
--     verwenden (accounts, transactions, budgets, recurring_contracts,
--     portfolios, assets, profiles.base_currency). ALTER DOMAIN prüft die
--     Bestandsdaten – steht irgendwo eine andere Währung, bricht die
--     Migration ab, statt ungültige Daten stehen zu lassen.
--  2. create_manual_transaction() erhält p_currency: Originalwährung der
--     Buchung, Standard ist die Kontowährung.
--
--  Bewusst NICHT enthalten: Umrechnung, base_amount, exchange_rate(s).
--  Beträge bleiben in ihrer Originalwährung. Summen über mehrere Konten
--  (Net Worth, Budgets) dürfen Währungen daher nie addieren, sondern
--  weisen getrennte Summen je Währung aus (siehe lib/currency.ts).
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. Unterstützte Währungen
-- ---------------------------------------------------------------------
alter domain public.currency_code drop constraint currency_code_check;
alter domain public.currency_code add constraint currency_code_supported
  check (value in ('EUR', 'USD', 'CHF'));

-- ---------------------------------------------------------------------
-- 2. create_manual_transaction() mit Originalwährung
-- ---------------------------------------------------------------------
-- Neue Signatur statt Überladung: Zwei Varianten mit Default-Parametern
-- wären bei Aufrufen ohne p_currency mehrdeutig.
drop function public.create_manual_transaction(date, numeric, text, text, uuid, uuid, uuid[], text[]);

create or replace function public.create_manual_transaction(
  p_booking_date       date,
  p_amount             numeric,
  p_counterparty_name  text,
  p_purpose            text   default null,
  p_account_id         uuid   default null,
  p_category_id        uuid   default null,
  p_tag_ids            uuid[] default '{}',
  p_new_tag_names      text[] default '{}',
  p_currency           text   default null
)
returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_uid             uuid := auth.uid();
  v_account_id      uuid := p_account_id;
  v_currency        public.currency_code;
  v_category_kind   public.category_kind;
  v_new_tag_names   text[];
  v_tag_ids         uuid[];
  v_transaction_id  uuid;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;

  -- 1. Betrag und Datum -------------------------------------------------
  if p_amount is null or p_amount = 0 or p_amount <> round(p_amount, 2) then
    raise exception 'invalid_amount' using errcode = '22023';
  end if;
  if p_booking_date is null then
    raise exception 'invalid_booking_date' using errcode = '22023';
  end if;

  -- 2. Konto ------------------------------------------------------------
  -- Ohne Angabe: das manuelle Bargeld-Konto des Nutzers, bei Bedarf neu.
  -- Der Advisory Lock verhindert, dass zwei parallele Erfassungen je ein
  -- eigenes Bargeld-Konto anlegen.
  if v_account_id is null then
    perform pg_advisory_xact_lock(hashtextextended('manual_cash_account:' || v_uid::text, 0));

    select a.id into v_account_id
      from public.accounts a
     where a.user_id = v_uid
       and a.provider = 'manual'
       and a.type = 'cash'
       and a.archived_at is null
     order by a.created_at
     limit 1;

    if v_account_id is null then
      insert into public.accounts (user_id, name, type, provider)
      values (v_uid, 'Bargeld', 'cash', 'manual')
      returning id into v_account_id;
    end if;
  end if;

  select a.currency into v_currency
    from public.accounts a
   where a.id = v_account_id
     and a.user_id = v_uid
     and a.archived_at is null;

  if not found then
    raise exception 'account_not_found' using errcode = 'P0002';
  end if;

  -- Originalwährung der Buchung: ohne Angabe die des Kontos. Eine andere
  -- unterstützte Währung ist zulässig (z. B. USD-Zahlung vom EUR-Konto);
  -- umgerechnet wird nicht. Die Liste der Währungen steht allein in der
  -- Domain currency_code – der Cast prüft sie.
  if p_currency is not null then
    begin
      v_currency := p_currency::public.currency_code;
    exception when check_violation then
      raise exception 'invalid_currency' using errcode = '22023';
    end;
  end if;

  -- 3. Kategorie: Art muss zum Vorzeichen passen ----------------------------
  -- expense → Ausgabe (negativ), income → Einnahme (positiv), transfer → beides.
  if p_category_id is not null then
    select c.kind into v_category_kind
      from public.categories c
     where c.id = p_category_id
       and c.user_id = v_uid;

    if not found then
      raise exception 'category_not_found' using errcode = 'P0002';
    end if;

    if (v_category_kind = 'expense' and p_amount > 0)
       or (v_category_kind = 'income' and p_amount < 0) then
      raise exception 'category_kind_mismatch' using errcode = '22023';
    end if;
  end if;

  -- 4. Tags ---------------------------------------------------------------
  select coalesce(array_agg(distinct btrim(n)), '{}') into v_new_tag_names
    from unnest(coalesce(p_new_tag_names, '{}')) as n
   where btrim(n) <> '';

  if cardinality(v_new_tag_names) > 10
     or cardinality(coalesce(p_tag_ids, '{}')) + cardinality(v_new_tag_names) > 20 then
    raise exception 'too_many_tags' using errcode = '22023';
  end if;

  -- Existiert ein Tag bereits (ohne Groß-/Kleinschreibung), wird er
  -- wiederverwendet statt dupliziert (Index tags_user_name_key).
  insert into public.tags (user_id, name)
  select v_uid, n from unnest(v_new_tag_names) as n
  on conflict (user_id, lower(name)) do nothing;

  select coalesce(array_agg(distinct t.id), '{}') into v_tag_ids
    from public.tags t
   where t.user_id = v_uid
     and (t.id = any(coalesce(p_tag_ids, '{}'))
          or lower(t.name) = any(select lower(n) from unnest(v_new_tag_names) as n));

  -- Jede übergebene Tag-ID muss dem Nutzer gehören.
  if exists (
    select 1 from unnest(coalesce(p_tag_ids, '{}')) as requested(id)
     where requested.id <> all(v_tag_ids)
  ) then
    raise exception 'tag_not_found' using errcode = 'P0002';
  end if;

  -- 5. Buchung ------------------------------------------------------------
  insert into public.transactions (
    user_id, account_id, category_id, booking_date, amount, currency,
    counterparty_name, purpose, categorization_source, source
  )
  values (
    v_uid, v_account_id, p_category_id, p_booking_date, p_amount, v_currency,
    nullif(btrim(p_counterparty_name), ''), nullif(btrim(p_purpose), ''),
    case when p_category_id is not null then 'manual'::public.categorization_source end,
    'manual'
  )
  returning id into v_transaction_id;

  insert into public.transaction_tags (transaction_id, tag_id, user_id)
  select v_transaction_id, tag_id, v_uid from unnest(v_tag_ids) as tag_id;

  return v_transaction_id;
end;
$$;

comment on function public.create_manual_transaction(date, numeric, text, text, uuid, uuid, uuid[], text[], text) is
  'Manuelle Buchung inkl. Tags atomar anlegen (SECURITY INVOKER, RLS aktiv). '
  'Ohne Konto wird das manuelle Bargeld-Konto verwendet bzw. angelegt. '
  'p_currency: Originalwährung, Standard = Kontowährung; keine Umrechnung.';

revoke all on function public.create_manual_transaction(date, numeric, text, text, uuid, uuid, uuid[], text[], text)
  from public, anon;
grant execute on function public.create_manual_transaction(date, numeric, text, text, uuid, uuid, uuid[], text[], text)
  to authenticated;

commit;
