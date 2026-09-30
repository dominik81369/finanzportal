-- =====================================================================
--  20261002150000_budget_groups.sql
--
--  Budget-Abgleich nach der 50/30/20-Regel (Needs / Wants / Savings).
--
--  1. Typ public.budget_group ('needs', 'wants', 'savings') und Spalte
--     categories.budget_group. NULL = wird nicht gezählt (z. B. Umbuchung).
--     Unabhängig von kind: „Sparen & Investieren“ und „Kredittilgung“ sind
--     kind = 'transfer', zählen aber als Savings.
--     Einkommenskategorien haben nie eine Gruppe – Einkommen ist der Nenner.
--
--  2. Standardwert beim Anlegen (BEFORE INSERT, nur wenn budget_group NULL):
--       Standardkategorie (default_key) → feste Zuordnung (siehe unten)
--       Unterkategorie                  → Gruppe der Oberkategorie
--       sonst kind 'expense'            → 'wants'
--       kind 'income' / 'transfer'      → NULL
--     Ein Trigger kann ein ausdrücklich übergebenes NULL nicht von einem
--     fehlenden Wert unterscheiden: Ausschließen einer Ausgabenkategorie
--     geht per UPDATE (Zuordnungsformular der App).
--     seed_default_categories() bleibt unverändert – der Trigger ordnet zu.
--
--  3. Bestand: Standardkategorien nach default_key (umbenannte über
--     is_default + sort_order), eigene Kategorien nach derselben Regel
--     (Oberkategorien zuerst, dann Unterkategorien).
--
--  4. public.budget_rule_summary(): Ist-Werte je Monat und Währung.
--  5. public.set_category_budget_groups(): Zuordnung in einem Schritt ändern.
--
--  Beide Funktionen SECURITY INVOKER – RLS gilt (Berater lesen nur Daten
--  aktiver Mandanten, schreiben nie).
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. Typ und Spalte
-- ---------------------------------------------------------------------
create type public.budget_group as enum ('needs', 'wants', 'savings');

alter table public.categories
  add column budget_group public.budget_group,
  add constraint categories_income_without_budget_group
    check (kind <> 'income' or budget_group is null);

comment on column public.categories.budget_group is
  '50/30/20-Gruppe (needs/wants/savings); NULL = zählt nicht (Umbuchungen, Einkommen). '
  'Standardwert per Trigger categories_default_budget_group.';

-- ---------------------------------------------------------------------
-- 2. Standardzuordnung
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
    when p_default_key in ('housing', 'groceries', 'mobility', 'insurance', 'health', 'taxes')
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

-- SECURITY DEFINER: Auch Rollen ohne Rechte auf das Schema private
-- (service_role, z. B. künftige Importe) müssen Kategorien anlegen können.
create or replace function private.categories_default_budget_group()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.budget_group is not null or new.kind = 'income' then
    return new;
  end if;

  if new.default_key is null and new.parent_category_id is not null then
    select p.budget_group into new.budget_group
      from public.categories p
     where p.id = new.parent_category_id
       and p.user_id = new.user_id;
    return new;
  end if;

  new.budget_group := private.default_budget_group(new.default_key, new.kind);
  return new;
end;
$$;

create trigger categories_default_budget_group
  before insert on public.categories
  for each row execute function private.categories_default_budget_group();

-- ---------------------------------------------------------------------
-- 3. Bestand
-- ---------------------------------------------------------------------
-- Umbenannte Standardkategorien haben keinen default_key mehr (siehe
-- 20261002120000); sie sind über is_default und die geseedete sort_order
-- weiterhin eindeutig erkennbar.
update public.categories c
   set budget_group = private.default_budget_group(coalesce(c.default_key, m.default_key), c.kind)
  from public.categories c2
  left join (values
    (100, 'housing'), (110, 'groceries'), (120, 'mobility'), (130, 'insurance'),
    (140, 'health'), (150, 'leisure_travel'), (160, 'subscriptions_media'), (170, 'shopping'),
    (180, 'education'), (190, 'taxes'), (200, 'other_expenses'),
    (300, 'savings_investments'), (310, 'loan_repayment'), (320, 'transfer')
  ) as m (sort_order, default_key)
    on c2.is_default and c2.default_key is null and c2.sort_order = m.sort_order
 where c2.id = c.id
   and (c.parent_category_id is null or c.default_key is not null);

update public.categories c
   set budget_group = p.budget_group
  from public.categories p
 where c.parent_category_id = p.id
   and c.user_id = p.user_id
   and c.default_key is null
   and c.kind <> 'income';

-- ---------------------------------------------------------------------
-- 4. Auswertung je Monat und Währung
-- ---------------------------------------------------------------------
-- income     = Summe der Buchungen in Einkommenskategorien
-- needs/…    = −Summe der Buchungen der Gruppe (netto: Erstattungen
--              mindern die Ausgaben, statt als Einkommen zu zählen)
-- unassigned = unkategorisierte Ausgaben (positive unkategorisierte
--              Beträge zählen nirgends)
-- Ausgelassen: exclude_from_budget = true, Kategorien ohne Gruppe.
-- Getrennt je Buchungswährung – keine Umrechnung, keine Vermischung.
-- Monate ohne gezählte Buchungen fehlen im Ergebnis.
create or replace function public.budget_rule_summary(
  p_user_id uuid,
  p_from    date,
  p_to      date
)
returns table (
  month      date,
  currency   text,
  income     numeric,
  needs      numeric,
  wants      numeric,
  savings    numeric,
  unassigned numeric
)
language plpgsql
stable
security invoker
set search_path = ''
as $$
begin
  if p_user_id is null or p_from is null or p_to is null or p_from > p_to
     or p_to > (p_from + interval '5 years') then
    raise exception 'invalid_period' using errcode = '22023';
  end if;

  return query
  select s.month, s.currency, s.income, s.needs, s.wants, s.savings, s.unassigned
    from (
      select date_trunc('month', t.booking_date)::date                                        as month,
             t.currency::text                                                                  as currency,
             coalesce(sum(t.amount) filter (where c.kind = 'income'), 0)                        as income,
             coalesce(-sum(t.amount) filter (where c.kind <> 'income' and c.budget_group = 'needs'), 0)   as needs,
             coalesce(-sum(t.amount) filter (where c.kind <> 'income' and c.budget_group = 'wants'), 0)   as wants,
             coalesce(-sum(t.amount) filter (where c.kind <> 'income' and c.budget_group = 'savings'), 0) as savings,
             coalesce(-sum(t.amount) filter (where t.category_id is null and t.amount < 0), 0)  as unassigned
        from public.transactions t
        left join public.categories c
          on c.id = t.category_id
         and c.user_id = t.user_id
       where t.user_id = p_user_id
         and t.booking_date between p_from and p_to
         and not t.exclude_from_budget
       group by 1, 2
    ) s
   where (s.income, s.needs, s.wants, s.savings, s.unassigned) <> (0, 0, 0, 0, 0)
   order by s.month, s.currency;
end;
$$;

comment on function public.budget_rule_summary(uuid, date, date) is
  '50/30/20-Ist-Werte je Monat und Buchungswährung (SECURITY INVOKER, RLS aktiv). '
  'Fehler invalid_period (22023) bei fehlenden Angaben, von > bis oder mehr als 5 Jahren.';

revoke all on function public.budget_rule_summary(uuid, date, date) from public, anon;
grant execute on function public.budget_rule_summary(uuid, date, date) to authenticated;

-- ---------------------------------------------------------------------
-- 5. Zuordnung ändern (eine Anweisung → alles oder nichts)
-- ---------------------------------------------------------------------
-- p_assignments: [{"id": "<uuid>", "budget_group": "needs"|"wants"|"savings"|null}, …]
-- Nur eigene Kategorien (RLS + user_id = auth.uid()); Einkommenskategorien
-- scheitern am Check categories_income_without_budget_group, sofern eine
-- Gruppe gesetzt wird. Liefert die Zahl der geänderten Kategorien.
create or replace function public.set_category_budget_groups(p_assignments jsonb)
returns integer
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_count integer;
begin
  if p_assignments is null or jsonb_typeof(p_assignments) <> 'array' then
    raise exception 'invalid_assignments' using errcode = '22023';
  end if;

  begin
    with input as (
      select (e ->> 'id')::uuid                        as id,
             (e ->> 'budget_group')::public.budget_group as budget_group
        from jsonb_array_elements(p_assignments) as e
    )
    update public.categories c
       set budget_group = i.budget_group
      from input i
     where c.id = i.id
       and c.user_id = (select auth.uid())
       and c.budget_group is distinct from i.budget_group;
    get diagnostics v_count = row_count;
  exception
    when invalid_text_representation then
      raise exception 'invalid_assignments' using errcode = '22023';
  end;

  return v_count;
end;
$$;

comment on function public.set_category_budget_groups(jsonb) is
  'Setzt categories.budget_group für eigene Kategorien in einer Anweisung (SECURITY INVOKER). '
  'Fehler invalid_assignments (22023) bei ungültiger ID oder Gruppe.';

revoke all on function public.set_category_budget_groups(jsonb) from public, anon;
grant execute on function public.set_category_budget_groups(jsonb) to authenticated;

commit;
