-- =====================================================================
--  20261012100000_budget_b2.sql
--  Budget-2: Einzelbudgets je Kategorie (Monat oder Jahr)
--
--  1. Ein Budget je Kategorie: Unique-Index budgets_category_unique.
--     Tag- und Kontobudgets bleiben unverändert (ohne Oberfläche).
--  2. public.save_category_budget(): Budget anlegen oder ändern. Nur
--     Ausgabenkategorien, Zeitraum Monat oder Jahr (Woche/Quartal folgen),
--     Betrag > 0 mit höchstens zwei Nachkommastellen, Schwelle 1–100 %.
--     Der Name folgt der Kategorie.
--  3. public.budget_rule_summary() entfällt; die App rechnet seit
--     Budget-1 mit public.budget_category_totals().
--
--  Ausgewertet wird in der App (lib/category-budgets.ts): Ausgaben der
--  Kategorie samt Unterkategorien in der Währung des Budgets, netto nach
--  Erstattungen, ohne Buchungen „nicht im Budget“. starts_on/ends_on
--  bleiben ungenutzt: Budgets gelten für jeden angezeigten Zeitraum.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. Ein Budget je Kategorie
-- ---------------------------------------------------------------------
do $$
begin
  if exists (
    select 1
      from public.budgets
     where category_id is not null
     group by user_id, category_id
    having count(*) > 1
  ) then
    raise exception 'Budget-2: Es gibt mehrere Budgets für dieselbe Kategorie. Bitte vorher bereinigen.';
  end if;
end;
$$;

create unique index budgets_category_unique
  on public.budgets (user_id, category_id)
  where category_id is not null;

comment on column public.budgets.starts_on is
  'Derzeit ungenutzt: Kategoriebudgets gelten für jeden angezeigten Zeitraum (Budget-2).';
comment on column public.budgets.ends_on is
  'Derzeit ungenutzt: Kategoriebudgets gelten für jeden angezeigten Zeitraum (Budget-2).';

-- ---------------------------------------------------------------------
-- 2. Budget anlegen oder ändern
-- ---------------------------------------------------------------------
create or replace function public.save_category_budget(
  p_id            uuid,
  p_category_id   uuid,
  p_period        public.budget_period,
  p_amount        numeric,
  p_currency      public.currency_code,
  p_threshold_pct integer
)
returns uuid
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_uid  uuid := auth.uid();
  v_name text;
  v_kind public.category_kind;
  v_id   uuid;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if p_period is null or p_period not in ('monthly', 'yearly') then
    raise exception 'invalid_period' using errcode = '22023';
  end if;
  if p_amount is null or p_amount <= 0 or p_amount >= 1e12 or round(p_amount, 2) <> p_amount then
    raise exception 'invalid_amount' using errcode = '22023';
  end if;
  if p_currency is null then
    raise exception 'invalid_currency' using errcode = '22023';
  end if;
  if p_threshold_pct is null or p_threshold_pct not between 1 and 100 then
    raise exception 'invalid_threshold' using errcode = '22023';
  end if;

  select c.name, c.kind
    into v_name, v_kind
    from public.categories c
   where c.id = p_category_id
     and c.user_id = v_uid;
  if not found or v_kind <> 'expense' then
    raise exception 'invalid_category' using errcode = '22023';
  end if;

  begin
    if p_id is null then
      insert into public.budgets (user_id, name, category_id, period, amount, currency, alert_threshold_pct)
      values (v_uid, left(v_name, 120), p_category_id, p_period, p_amount, p_currency, p_threshold_pct)
      returning id into v_id;
    else
      update public.budgets b
         set name = left(v_name, 120),
             category_id = p_category_id,
             period = p_period,
             amount = p_amount,
             currency = p_currency,
             alert_threshold_pct = p_threshold_pct
       where b.id = p_id
         and b.user_id = v_uid
         and b.category_id is not null
      returning b.id into v_id;
    end if;
  exception
    when unique_violation then
      raise exception 'budget_exists' using errcode = '23505';
  end;
  if v_id is null then
    raise exception 'budget_not_found' using errcode = 'P0002';
  end if;
  return v_id;
end;
$$;

comment on function public.save_category_budget(uuid, uuid, public.budget_period, numeric, public.currency_code, integer) is
  'Legt ein Kategoriebudget des angemeldeten Nutzers an (p_id NULL) oder ändert es. Fehler (22023): '
  'invalid_period (nur monthly/yearly), invalid_amount (> 0, zwei Nachkommastellen), invalid_currency, '
  'invalid_threshold (1–100), invalid_category (eigene Ausgabenkategorie); budget_exists (23505): Kategorie '
  'hat schon ein Budget; budget_not_found (P0002).';

revoke all on function public.save_category_budget(uuid, uuid, public.budget_period, numeric, public.currency_code, integer)
  from public, anon;
grant execute on function public.save_category_budget(uuid, uuid, public.budget_period, numeric, public.currency_code, integer)
  to authenticated;

-- ---------------------------------------------------------------------
-- 3. Alte Auswertung entfällt
-- ---------------------------------------------------------------------
drop function public.budget_rule_summary(uuid, date, date);

commit;
