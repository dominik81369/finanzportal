-- =====================================================================
--  20261014100000_contracts_cleanup.sql
--  Verträge: Bereinigung – Informationsquelle statt Arbeitsliste
--
--  1. Offene Vorschläge (status 'suggested') werden gelöscht, ihre
--     Buchungen gelöst. Verworfene bleiben unsichtbar gespeichert. Die
--     Erkennung (private.refresh_contracts) bleibt in der Datenbank, wird
--     aber nicht mehr aufgerufen; Verträge werden manuell angelegt.
--     public.refresh_contracts() verknüpft nur noch (wie sync_contracts).
--  2. Verknüpfung ohne einstellbare Toleranz und ohne Mandat
--     (private.link_contract_bookings):
--       – Band: Betrag höchstens 50 % über bzw. unter dem Vertragsbetrag (×1,5),
--       – je Vertrag höchstens eine Abbuchung je Periode (Abstand zu jeder
--         verknüpften Abbuchung mehr als eine halbe Periode),
--       – mehrere Verträge derselben Gegenpartei: der nächste Betrag zuerst,
--       – Gegenbuchungen (Gutschriften) im Band ab der ersten Abbuchung.
--     amount_tolerance_pct bleibt als Spalte, wird aber nicht mehr verwendet.
--  3. Der Vertragsbetrag folgt den verknüpften Abbuchungen (Median der
--     letzten drei; eine einzelne abweichende Buchung verschiebt ihn nicht).
--     Eine Preisänderung erzeugt keinen Hinweis; der Betrag zieht nach.
--  4. private/public.sync_contracts(): verknüpfen und nachführen, ohne
--     Erkennung – nach dem Import, beim Öffnen der Seite, beim Speichern.
--  5. public.delete_contract(): jeder eigene Vertrag (auch erkannte).
--  6. public.contract_counterparties(): zusätzlich Rhythmus (wiederkehrende
--     Buchungen, B1), Vorschlag für den Vertragstyp und ob schon ein
--     Vertrag zu dieser Gegenpartei besteht.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. Offene Vorschläge entfernen
-- ---------------------------------------------------------------------
update public.transactions t
   set contract_link_manual = false
 where t.contract_link_manual
   and t.recurring_contract_id in (select rc.id from public.recurring_contracts rc where rc.status = 'suggested');

-- Buchungen werden über den Fremdschlüssel gelöst (on delete set null).
delete from public.recurring_contracts rc where rc.status = 'suggested';

comment on column public.recurring_contracts.amount_tolerance_pct is
  'Ungenutzt seit 20261014100000: Die Verknüpfung nutzt ein festes Band (×1,5) und eine Abbuchung je Periode.';

-- ---------------------------------------------------------------------
-- 2. Verknüpfung
-- ---------------------------------------------------------------------
-- Paare (Buchung, Vertrag) im Band, bester Betrag zuerst. Eine Abbuchung
-- wird nur verknüpft, wenn der Vertrag in dieser Periode noch keine hat;
-- sonst kommt der nächste passende Vertrag derselben Gegenpartei an die
-- Reihe. So bleiben ähnliche Einkäufe bei derselben Gegenpartei (z. B.
-- Amazon neben Amazon Prime) außen vor.
create or replace function private.link_contract_bookings(p_user_id uuid)
returns integer
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_pair   record;
  v_done   uuid[] := '{}';
  v_linked integer := 0;
begin
  for v_pair in
    select t.id as tx_id, t.amount, t.booking_date, rc.id as contract_id, rc.rhythm, rc.interval_count
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
       and rc.expected_amount <> 0
       and greatest(abs(t.amount), abs(rc.expected_amount)) <= least(abs(t.amount), abs(rc.expected_amount)) * 1.5
       and (t.amount < 0 or (rc.first_booking_date is not null and t.booking_date >= rc.first_booking_date))
     order by greatest(abs(t.amount), abs(rc.expected_amount)) / least(abs(t.amount), abs(rc.expected_amount)),
              t.booking_date,
              -- Gleicher Betrag bei mehreren Verträgen: der mit dem nächsten Termin.
              abs(t.booking_date - coalesce(rc.next_expected_date, t.booking_date)),
              rc.created_at, rc.id, t.id
  loop
    continue when v_pair.tx_id = any (v_done);
    if v_pair.amount < 0 and exists (
      select 1
        from public.transactions x
       where x.user_id = p_user_id
         and x.recurring_contract_id = v_pair.contract_id
         and x.amount < 0
         and x.id <> v_pair.tx_id
         and abs(x.booking_date - v_pair.booking_date) * 2
             <= (v_pair.booking_date + private.contract_period(v_pair.rhythm, v_pair.interval_count))::date - v_pair.booking_date
    ) then
      continue;
    end if;
    update public.transactions t
       set recurring_contract_id = v_pair.contract_id
     where t.id = v_pair.tx_id
       and t.user_id = p_user_id;
    v_done := v_done || v_pair.tx_id;
    v_linked := v_linked + 1;
  end loop;
  return v_linked;
end;
$$;

comment on function private.link_contract_bookings(uuid) is
  'Verknüpft Abbuchungen (Band ×1,5, je Vertrag eine je Periode, nächster Betrag zuerst) und Gegenbuchungen '
  'ab der ersten Abbuchung mit bestätigten bzw. manuellen Verträgen. Manuell gelöste Buchungen bleiben gelöst.';

-- ---------------------------------------------------------------------
-- 3. Termine, Betrag, Mandat und Gläubiger-ID nachführen
-- ---------------------------------------------------------------------
-- Erste/letzte Abbuchung und Betrag (Median der letzten drei Abbuchungen)
-- aus den verknüpften Abbuchungen; die nächste erwartete rückt nach, sobald
-- die erwartete Abbuchung eingegangen ist. Manuell eingetragene spätere
-- Termine bleiben. Ohne verknüpfte Abbuchungen bleibt der eingetragene Betrag.
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
  ),
  recent as (
    select r.id, -percentile_disc(0.5) within group (order by r.amt) as amount
      from (select t.recurring_contract_id as id, abs(t.amount) as amt,
                   row_number() over (partition by t.recurring_contract_id order by t.booking_date desc, t.id desc) as n
              from public.transactions t
             where t.user_id = p_user_id and t.recurring_contract_id is not null and t.amount < 0) r
     where r.n <= 3
     group by r.id
  )
  update public.recurring_contracts rc
     set first_booking_date = agg.first_date,
         last_booking_date  = agg.last_date,
         mandate_reference  = agg.mandate,
         creditor_id        = agg.creditor,
         expected_amount    = case when rc.status = 'suggested' then rc.expected_amount else recent.amount end,
         next_expected_date = case
           when rc.status = 'suggested'
             or rc.next_expected_date is null
             or rc.next_expected_date <= agg.last_date + private.contract_period(rc.rhythm, rc.interval_count) / 2
           then (agg.last_date + private.contract_period(rc.rhythm, rc.interval_count))::date
           else rc.next_expected_date
         end
    from agg
    join recent on recent.id = agg.id
   where rc.id = agg.id
     and rc.user_id = p_user_id
     and (rc.first_booking_date is distinct from agg.first_date
          or rc.last_booking_date is distinct from agg.last_date
          or rc.mandate_reference is distinct from agg.mandate
          or rc.creditor_id is distinct from agg.creditor
          or (rc.status <> 'suggested' and rc.expected_amount is distinct from recent.amount)
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

-- ---------------------------------------------------------------------
-- 4. Verknüpfen und nachführen (ohne Erkennung)
-- ---------------------------------------------------------------------
create or replace function private.sync_contracts(p_user_id uuid)
returns integer
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_linked integer;
begin
  perform pg_advisory_xact_lock(hashtextextended('contracts:' || p_user_id::text, 0));
  v_linked := private.link_contract_bookings(p_user_id);
  perform private.update_contract_dates(p_user_id);
  -- Nach einer Preisänderung folgt der Betrag; ein zweiter Durchgang
  -- verknüpft, was erst mit dem neuen Betrag ins Band fällt.
  if v_linked > 0 then
    v_linked := v_linked + private.link_contract_bookings(p_user_id);
    perform private.update_contract_dates(p_user_id);
  end if;
  return v_linked;
end;
$$;

comment on function private.sync_contracts(uuid) is
  'Verknüpft neue Buchungen mit den Verträgen des Nutzers und führt Termine und Betrag nach (keine Erkennung).';

create or replace function public.sync_contracts()
returns integer
language plpgsql
volatile
security invoker
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  return private.sync_contracts(auth.uid());
end;
$$;

comment on function public.sync_contracts() is
  'Verknüpft neue Buchungen mit den eigenen Verträgen und führt Termine und Betrag nach. Liefert die Anzahl '
  'neu verknüpfter Buchungen.';

-- Ältere App-Stände rufen beim Öffnen der Seite und nach dem Import noch
-- refresh_contracts() auf: ab jetzt ohne Erkennung, also kein neuer
-- Vorschlag. Die Erkennung selbst bleibt in private.refresh_contracts().
create or replace function public.refresh_contracts()
returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  return jsonb_build_object('created', 0, 'removed', 0, 'linked', private.sync_contracts(auth.uid()));
end;
$$;

comment on function public.refresh_contracts() is
  'Veraltet (seit 20261014100000): wie sync_contracts(), ohne Erkennung. Liefert {created: 0, removed: 0, linked}.';

-- Speichern und Statuswechsel verknüpfen nur noch (keine Erkennung).
create or replace function public.save_contract(
  p_id                 uuid,
  p_name               text,
  p_counterparty_key   text,
  p_counterparty_name  text,
  p_rhythm             public.contract_rhythm,
  p_interval_count     integer,
  p_amount             numeric,
  p_next_expected_date date,
  p_contract_type      public.contract_type,
  p_account_id         uuid,
  p_category_id        uuid,
  p_notes              text,
  p_tolerance_pct      numeric default 10
)
returns uuid
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_uid     uuid := auth.uid();
  v_name    text := btrim(coalesce(p_name, ''));
  v_cp_name text := nullif(btrim(coalesce(p_counterparty_name, '')), '');
  v_key     text := nullif(btrim(coalesce(p_counterparty_key, '')), '');
  v_notes   text := nullif(btrim(coalesce(p_notes, '')), '');
  v_old_key text;
  v_status  public.contract_status;
  v_id      uuid;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if char_length(v_name) not between 1 and 120 then
    raise exception 'invalid_name' using errcode = '22023';
  end if;
  if v_cp_name is not null and char_length(v_cp_name) > 200 then
    raise exception 'invalid_counterparty' using errcode = '22023';
  end if;
  if v_key is not null and (char_length(v_key) > 300 or v_key !~ '^[imn]:.') then
    raise exception 'invalid_counterparty' using errcode = '22023';
  end if;
  if p_rhythm is null or p_interval_count is null or p_interval_count not between 1 and 24 then
    raise exception 'invalid_rhythm' using errcode = '22023';
  end if;
  if p_amount is null or p_amount <= 0 or p_amount >= 1e12 then
    raise exception 'invalid_amount' using errcode = '22023';
  end if;
  if p_tolerance_pct is null or p_tolerance_pct not between 0 and 50 then
    raise exception 'invalid_tolerance' using errcode = '22023';
  end if;
  if v_notes is not null and char_length(v_notes) > 2000 then
    raise exception 'invalid_notes' using errcode = '22023';
  end if;
  if p_account_id is not null
     and not exists (select 1 from public.accounts a where a.id = p_account_id and a.user_id = v_uid) then
    raise exception 'account_not_found' using errcode = 'P0002';
  end if;
  if p_category_id is not null
     and not exists (select 1 from public.categories c where c.id = p_category_id and c.user_id = v_uid) then
    raise exception 'category_not_found' using errcode = 'P0002';
  end if;
  if v_key is null and v_cp_name is not null then
    v_key := private.counterparty_key(null, v_cp_name, null);
  end if;
  -- Bezeichnung der Gegenpartei aus den Buchungen, wenn nur der Schlüssel kommt.
  if v_cp_name is null and v_key is not null then
    select left(mode() within group (order by btrim(t.counterparty_name)), 200) into v_cp_name
      from public.transactions t where t.user_id = v_uid and t.counterparty_key = v_key;
  end if;

  if p_id is null then
    insert into public.recurring_contracts (
      user_id, name, counterparty_name, counterparty_key, rhythm, interval_count, expected_amount,
      amount_tolerance_pct, next_expected_date, contract_type, account_id, category_id, notes,
      status, detection_source
    ) values (
      v_uid, v_name, v_cp_name, v_key, p_rhythm, p_interval_count, -round(p_amount, 2),
      p_tolerance_pct, p_next_expected_date, coalesce(p_contract_type, 'other'), p_account_id, p_category_id, v_notes,
      'active', 'manual'
    ) returning id into v_id;
  else
    select rc.status, rc.counterparty_key into v_status, v_old_key
      from public.recurring_contracts rc where rc.id = p_id and rc.user_id = v_uid;
    if not found then
      raise exception 'contract_not_found' using errcode = 'P0002';
    end if;
    if v_status in ('suggested', 'dismissed') then
      raise exception 'contract_not_editable' using errcode = '22023';
    end if;
    update public.recurring_contracts rc
       set name = v_name, counterparty_name = v_cp_name, counterparty_key = v_key,
           rhythm = p_rhythm, interval_count = p_interval_count, expected_amount = -round(p_amount, 2),
           amount_tolerance_pct = p_tolerance_pct, next_expected_date = p_next_expected_date,
           contract_type = coalesce(p_contract_type, 'other'), account_id = p_account_id,
           category_id = p_category_id, notes = v_notes
     where rc.id = p_id and rc.user_id = v_uid
    returning id into v_id;
    -- Andere Gegenpartei: automatisch verknüpfte Buchungen der alten lösen.
    if v_old_key is distinct from v_key then
      update public.transactions t
         set recurring_contract_id = null
       where t.user_id = v_uid and t.recurring_contract_id = v_id
         and not t.contract_link_manual
         and t.counterparty_key is distinct from v_key;
    end if;
  end if;

  perform private.sync_contracts(v_uid);
  return v_id;
end;
$$;

create or replace function public.set_contract_status(
  p_id            uuid,
  p_status        public.contract_status,
  p_contract_type public.contract_type default null
)
returns void
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_uid    uuid := auth.uid();
  v_status public.contract_status;
  v_source public.contract_detection;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  select rc.status, rc.detection_source into v_status, v_source
    from public.recurring_contracts rc where rc.id = p_id and rc.user_id = v_uid;
  if not found then
    raise exception 'contract_not_found' using errcode = 'P0002';
  end if;
  if not (
       (v_status = 'suggested' and p_status in ('active', 'dismissed'))
    or (v_status = 'active' and p_status = 'dismissed' and v_source = 'auto')
    or (v_status = 'dismissed' and p_status = 'suggested' and v_source = 'auto')
  ) then
    raise exception 'invalid_transition' using errcode = '22023';
  end if;
  update public.recurring_contracts rc
     set status = p_status,
         contract_type = coalesce(p_contract_type, rc.contract_type)
   where rc.id = p_id and rc.user_id = v_uid;
  perform private.sync_contracts(v_uid);
end;
$$;

-- ---------------------------------------------------------------------
-- 5. Löschen: jeder eigene Vertrag
-- ---------------------------------------------------------------------
create or replace function public.delete_contract(p_id uuid)
returns void
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
  if not exists (select 1 from public.recurring_contracts rc where rc.id = p_id and rc.user_id = v_uid) then
    raise exception 'contract_not_found' using errcode = 'P0002';
  end if;
  -- Manuelle Verknüpfungen mit diesem Vertrag verlieren ihren Bezug: Die
  -- Buchungen stehen der automatischen Verknüpfung wieder offen.
  update public.transactions t
     set contract_link_manual = false
   where t.user_id = v_uid and t.recurring_contract_id = p_id and t.contract_link_manual;
  delete from public.recurring_contracts rc where rc.id = p_id and rc.user_id = v_uid;
end;
$$;

comment on function public.delete_contract(uuid) is
  'Löscht einen eigenen Vertrag; verknüpfte Buchungen werden gelöst. Fehler: contract_not_found (P0002).';

-- ---------------------------------------------------------------------
-- 6. Gegenparteien für das Formular
-- ---------------------------------------------------------------------
drop function public.contract_counterparties(integer);

create function public.contract_counterparties(p_limit integer default 300)
returns table (
  counterparty_key text,
  label            text,
  tx_count         integer,
  last_amount      numeric,
  last_date        date,
  recurrence       text,
  contract_type    public.contract_type,
  has_contract     boolean
)
language sql
stable
security invoker
set search_path = ''
as $$
  select t.counterparty_key,
         left(coalesce(case when t.counterparty_key like 'm:%' then initcap(substr(t.counterparty_key, 3)) end,
                       mode() within group (order by btrim(t.counterparty_name)),
                       case when t.counterparty_key like 'n:%' then initcap(substr(t.counterparty_key, 3)) end,
                       mode() within group (order by btrim(t.purpose))), 120),
         count(*)::integer,
         (array_agg(abs(t.amount) order by t.booking_date desc, t.id))[1],
         max(t.booking_date),
         mode() within group (order by t.recurrence) filter (where t.recurrence is not null),
         private.guess_contract_type(
           concat_ws(' ', case when t.counterparty_key not like 'i:%' then substr(t.counterparty_key, 3) end,
                     mode() within group (order by t.counterparty_name),
                     (array_agg(t.purpose order by t.booking_date desc, t.id))[1]),
           mode() within group (order by c.default_key)),
         exists (select 1 from public.recurring_contracts rc
                  where rc.user_id = auth.uid() and rc.counterparty_key = t.counterparty_key
                    and rc.status in ('active', 'cancellation_pending', 'cancelled'))
    from public.transactions t
    left join public.categories c on c.id = t.category_id and c.user_id = t.user_id
   where t.user_id = auth.uid()
     and t.amount < 0
     and t.counterparty_key is not null
   group by t.counterparty_key
   order by (mode() within group (order by t.recurrence) filter (where t.recurrence is not null)) is null,
            count(*) desc, 2
   limit least(greatest(coalesce(p_limit, 300), 1), 1000);
$$;

comment on function public.contract_counterparties(integer) is
  'Gegenparteien der eigenen Abbuchungen für das Vertragsformular: wiederkehrende zuerst, mit Rhythmus, '
  'Vorschlag für den Vertragstyp und ob schon ein Vertrag besteht.';

-- ---------------------------------------------------------------------
-- Rechte
-- ---------------------------------------------------------------------
grant execute on function private.sync_contracts(uuid) to authenticated;
revoke all on function public.sync_contracts() from public, anon;
grant execute on function public.sync_contracts() to authenticated;
revoke all on function public.contract_counterparties(integer) from public, anon;
grant execute on function public.contract_counterparties(integer) to authenticated;

-- Bestand: Verknüpfungen und Beträge nach den neuen Regeln nachführen.
do $$
declare
  v_user uuid;
begin
  for v_user in select distinct rc.user_id from public.recurring_contracts rc loop
    perform private.sync_contracts(v_user);
  end loop;
end;
$$;

commit;
