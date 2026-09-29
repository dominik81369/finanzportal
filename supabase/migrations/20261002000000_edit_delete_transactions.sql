-- =====================================================================
--  supabase/migrations/20261002000000_edit_delete_transactions.sql
--  Manuelle Buchungen bearbeiten und löschen
--
--  - private.save_manual_transaction(): gemeinsame Logik für Anlegen
--    (p_id = null) und Bearbeiten. Übernimmt alle Prüfungen aus
--    create_manual_transaction() (Konto, Kategorieart, Tags, Währung),
--    damit Anlegen und Bearbeiten nicht auseinanderlaufen.
--  - public.create_manual_transaction(): unveränderte Signatur, ruft die
--    gemeinsame Logik auf.
--  - public.update_manual_transaction(p_id, …): bearbeitet eine eigene,
--    manuell erfasste Buchung inkl. Tags in einer Datenbanktransaktion.
--  - public.delete_manual_transaction(p_id): löscht eine eigene, manuell
--    erfasste Buchung (Tag-Zuordnungen per ON DELETE CASCADE).
--
--  Nur source = 'manual': Importierte bzw. synchronisierte Buchungen kämen
--  beim nächsten Abgleich wieder bzw. verändert zurück.
--
--  Alle Funktionen SECURITY INVOKER (RLS gilt) und mit ausdrücklicher
--  Prüfung user_id = auth.uid(): Berater lesen Mandantendaten, ändern sie
--  aber nie. Neue Fehlercodes: transaction_not_found, transaction_not_editable.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. Gemeinsame Logik
-- ---------------------------------------------------------------------
create or replace function private.save_manual_transaction(
  p_id                 uuid,
  p_booking_date       date,
  p_amount             numeric,
  p_counterparty_name  text,
  p_purpose            text,
  p_account_id         uuid,
  p_category_id        uuid,
  p_tag_ids            uuid[],
  p_new_tag_names      text[],
  p_currency           text
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
  v_source          public.transaction_source;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;

  -- 0. Beim Bearbeiten: eigene, manuell erfasste Buchung sperren --------
  -- Berater sehen Buchungen ihrer Mandanten per RLS, dürfen sie aber nicht
  -- ändern – daher ausdrücklich user_id = auth.uid(). Importierte bzw.
  -- synchronisierte Buchungen kämen beim nächsten Abgleich wieder bzw.
  -- verändert zurück und sind deshalb nicht bearbeitbar.
  if p_id is not null then
    select t.source into v_source
      from public.transactions t
     where t.id = p_id
       and t.user_id = v_uid
       for update;

    if not found then
      raise exception 'transaction_not_found' using errcode = 'P0002';
    end if;
    if v_source <> 'manual' then
      raise exception 'transaction_not_editable' using errcode = '22023';
    end if;
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
  if p_id is null then
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
  else
    update public.transactions t
       set account_id            = v_account_id,
           category_id           = p_category_id,
           booking_date          = p_booking_date,
           amount                = p_amount,
           currency              = v_currency,
           counterparty_name     = nullif(btrim(p_counterparty_name), ''),
           purpose               = nullif(btrim(p_purpose), ''),
           categorization_source = case when p_category_id is not null
                                        then 'manual'::public.categorization_source end
     where t.id = p_id
       and t.user_id = v_uid
    returning t.id into v_transaction_id;

    -- Tags: nicht mehr gewählte Zuordnungen lösen (die Tags selbst bleiben).
    delete from public.transaction_tags tt
     where tt.transaction_id = v_transaction_id
       and tt.tag_id <> all(v_tag_ids);
  end if;

  insert into public.transaction_tags (transaction_id, tag_id, user_id)
  select v_transaction_id, tag_id, v_uid from unnest(v_tag_ids) as tag_id
  on conflict (transaction_id, tag_id) do nothing;

  return v_transaction_id;
end;
$$;

revoke all on function private.save_manual_transaction(uuid, date, numeric, text, text, uuid, uuid, uuid[], text[], text) from public, anon;
-- Nötig, weil die öffentlichen Funktionen als Aufrufer laufen. Über die
-- Data API ist das Schema private nicht erreichbar.
grant execute on function private.save_manual_transaction(uuid, date, numeric, text, text, uuid, uuid, uuid[], text[], text) to authenticated;

-- ---------------------------------------------------------------------
-- 2. Anlegen (Signatur unverändert)
-- ---------------------------------------------------------------------
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
language sql
security invoker
set search_path = ''
as $$
  select private.save_manual_transaction(
    null, p_booking_date, p_amount, p_counterparty_name, p_purpose, p_account_id,
    p_category_id, p_tag_ids, p_new_tag_names, p_currency
  );
$$;

-- ---------------------------------------------------------------------
-- 3. Bearbeiten
-- ---------------------------------------------------------------------
create function public.update_manual_transaction(
  p_id                 uuid,
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
begin
  if p_id is null then
    raise exception 'transaction_not_found' using errcode = 'P0002';
  end if;
  return private.save_manual_transaction(
    p_id, p_booking_date, p_amount, p_counterparty_name, p_purpose, p_account_id,
    p_category_id, p_tag_ids, p_new_tag_names, p_currency
  );
end;
$$;

comment on function public.update_manual_transaction(uuid, date, numeric, text, text, uuid, uuid, uuid[], text[], text) is
  'Eigene, manuell erfasste Buchung inkl. Tags atomar bearbeiten (SECURITY INVOKER, RLS aktiv). '
  'Parameter wie create_manual_transaction(); die Tag-Auswahl ersetzt die bisherige.';

revoke all on function public.update_manual_transaction(uuid, date, numeric, text, text, uuid, uuid, uuid[], text[], text) from public, anon;
grant execute on function public.update_manual_transaction(uuid, date, numeric, text, text, uuid, uuid, uuid[], text[], text) to authenticated;

-- ---------------------------------------------------------------------
-- 4. Löschen
-- ---------------------------------------------------------------------
create function public.delete_manual_transaction(p_id uuid)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_uid     uuid := auth.uid();
  v_source  public.transaction_source;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;

  select t.source into v_source
    from public.transactions t
   where t.id = p_id
     and t.user_id = v_uid
     for update;

  if not found then
    raise exception 'transaction_not_found' using errcode = 'P0002';
  end if;
  if v_source <> 'manual' then
    raise exception 'transaction_not_editable' using errcode = '22023';
  end if;

  delete from public.transactions t
   where t.id = p_id
     and t.user_id = v_uid;
end;
$$;

comment on function public.delete_manual_transaction(uuid) is
  'Eigene, manuell erfasste Buchung löschen (SECURITY INVOKER, RLS aktiv).';

revoke all on function public.delete_manual_transaction(uuid) from public, anon;
grant execute on function public.delete_manual_transaction(uuid) to authenticated;

commit;
