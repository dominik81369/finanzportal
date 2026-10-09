-- =====================================================================
--  20261011100000_budget_b1.sql
--
--  Budget, Schritt 1: 50/30/20 auf Basis der Ausgaben.
--
--  1. public.budget_settings je Nutzer: Prozentziele (Standard 50/30/20,
--     eine Nachkommastelle, Summe 100) und Voreinstellung der Bezugsgröße
--     (expenses | expenses_avg3 | fixed | income) mit festem Monatsbetrag
--     in einer Währung. Eigentümer liest und schreibt, aktive Berater lesen.
--  2. Standardkategorien „Darlehen“ (ungeteilte Rate) und
--     „Darlehenszinsen“, beide Needs; „Kredittilgung“ bleibt bei Sparen &
--     Schulden. Für bestehende Nutzer nachgetragen.
--  3. public.budget_category_totals(): Summen je Monat, Währung und
--     Kategorie mit Gruppe, Art, Merkmal (taxes | loan) und ob die
--     Gegenseite ein eigenes Konto ist (IBAN-Regel). Daraus berechnet die
--     App Gruppen, Steuer-/Darlehenszeilen, „davon auf eigene Sparkonten“,
--     Umbuchungen und „Nicht erfasst“ (lib/budget-rule.ts).
--
--  public.budget_rule_summary() bleibt vorerst bestehen, damit die
--  bisherige App-Version bis zum Merge funktioniert; sie entfällt mit
--  Budget-2.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. Einstellungen
-- ---------------------------------------------------------------------
create type public.budget_basis as enum ('expenses', 'expenses_avg3', 'fixed', 'income');

create table public.budget_settings (
  user_id        uuid primary key default auth.uid(),
  basis          public.budget_basis not null default 'expenses',
  needs_pct      numeric(4,1) not null default 50 check (needs_pct between 0 and 100),
  wants_pct      numeric(4,1) not null default 30 check (wants_pct between 0 and 100),
  savings_pct    numeric(4,1) not null default 20 check (savings_pct between 0 and 100),
  fixed_amount   numeric(14,2) check (fixed_amount > 0),
  fixed_currency public.currency_code not null default 'EUR',
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),

  constraint budget_settings_user_id_fkey
    foreign key (user_id) references auth.users (id) on delete cascade,
  constraint budget_settings_pct_sum
    check (needs_pct + wants_pct + savings_pct = 100),
  constraint budget_settings_fixed_amount
    check (basis <> 'fixed' or fixed_amount is not null)
);

comment on table public.budget_settings is
  '50/30/20-Einstellungen je Nutzer: Prozentziele und Voreinstellung der Bezugsgröße. Ohne Zeile gelten '
  'die Standardwerte (Ausgaben, 50/30/20).';
comment on column public.budget_settings.basis is
  'Voreinstellung der Bezugsgröße: expenses (Ausgaben des Zeitraums), expenses_avg3 (Monatsschnitt der drei '
  'vollen Vormonate), fixed (fester Monatsbetrag), income (Einkommen).';
comment on column public.budget_settings.fixed_amount is
  'Fester Monatsbetrag für die Bezugsgröße fixed, in fixed_currency.';

create trigger set_updated_at before update on public.budget_settings
  for each row execute function private.set_updated_at();

alter table public.budget_settings enable row level security;

create policy budget_settings_select_owner_or_advisor on public.budget_settings
  for select to authenticated
  using ((select auth.uid()) = user_id or user_id in (select private.advisor_client_ids()));
create policy budget_settings_insert_owner on public.budget_settings
  for insert to authenticated with check ((select auth.uid()) = user_id);
create policy budget_settings_update_owner on public.budget_settings
  for update to authenticated
  using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);

revoke all on public.budget_settings from anon, authenticated;
grant select, insert, update on public.budget_settings to authenticated;

-- Einstellungen speichern (anlegen oder ändern).
create or replace function public.save_budget_settings(
  p_basis          public.budget_basis,
  p_needs_pct      numeric,
  p_wants_pct      numeric,
  p_savings_pct    numeric,
  p_fixed_amount   numeric,
  p_fixed_currency public.currency_code
)
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
  if p_basis is null then
    raise exception 'invalid_basis' using errcode = '22023';
  end if;
  if p_needs_pct is null or p_wants_pct is null or p_savings_pct is null
     or least(p_needs_pct, p_wants_pct, p_savings_pct) < 0
     or greatest(p_needs_pct, p_wants_pct, p_savings_pct) > 100
     or round(p_needs_pct, 1) <> p_needs_pct or round(p_wants_pct, 1) <> p_wants_pct
     or round(p_savings_pct, 1) <> p_savings_pct
     or p_needs_pct + p_wants_pct + p_savings_pct <> 100 then
    raise exception 'invalid_percentages' using errcode = '22023';
  end if;
  if (p_fixed_amount is not null and (p_fixed_amount <= 0 or p_fixed_amount >= 1e12))
     or (p_basis = 'fixed' and p_fixed_amount is null) then
    raise exception 'invalid_fixed_amount' using errcode = '22023';
  end if;

  insert into public.budget_settings (user_id, basis, needs_pct, wants_pct, savings_pct, fixed_amount, fixed_currency)
  values (v_uid, p_basis, p_needs_pct, p_wants_pct, p_savings_pct, round(p_fixed_amount, 2),
          coalesce(p_fixed_currency, 'EUR'))
  on conflict (user_id) do update
     set basis = excluded.basis, needs_pct = excluded.needs_pct, wants_pct = excluded.wants_pct,
         savings_pct = excluded.savings_pct, fixed_amount = excluded.fixed_amount,
         fixed_currency = excluded.fixed_currency;
end;
$$;

comment on function public.save_budget_settings(public.budget_basis, numeric, numeric, numeric, numeric, public.currency_code) is
  'Speichert die 50/30/20-Einstellungen des angemeldeten Nutzers. Fehler: invalid_basis, invalid_percentages '
  '(je 0–100, eine Nachkommastelle, Summe 100), invalid_fixed_amount (> 0; Pflicht bei fixed) (22023).';

-- ---------------------------------------------------------------------
-- 2. Standardkategorien „Darlehen“ und „Darlehenszinsen“
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
    when p_default_key in ('housing', 'groceries', 'mobility', 'insurance', 'health', 'taxes', 'capital_gains_tax',
                           'loan', 'loan_interest')
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
    (p_user_id, 'Darlehen',             'expense',  '#334155', 'landmark',         true, 196, 'loan'),
    (p_user_id, 'Darlehenszinsen',      'expense',  '#334155', 'percent',          true, 197, 'loan_interest'),
    (p_user_id, 'Sonstige Ausgaben',    'expense',  '#94a3b8', 'ellipsis',         true, 200, 'other_expenses'),
    (p_user_id, 'Sparen & Investieren', 'transfer', '#0f766e', 'piggy-bank',       true, 300, 'savings_investments'),
    (p_user_id, 'Kredittilgung',        'transfer', '#475569', 'receipt',          true, 310, 'loan_repayment'),
    (p_user_id, 'Umbuchung',            'transfer', '#9ca3af', 'arrow-left-right', true, 320, 'transfer')
  on conflict on constraint categories_name_key do nothing;
end;
$$;

-- Bestand (idempotent): gleichnamige eigene Kategorien ohne Schlüssel
-- erhalten den Schlüssel (Gruppe bleibt, wie der Nutzer sie gesetzt hat),
-- sonst werden die Kategorien angelegt (Gruppe Needs per Trigger).
do $$
declare
  v_user uuid;
begin
  for v_user in select distinct c.user_id from public.categories c loop
    update public.categories c
       set default_key = m.key
      from (values ('Darlehen', 'loan'), ('Darlehenszinsen', 'loan_interest')) as m (name, key)
     where c.user_id = v_user
       and c.parent_category_id is null
       and c.default_key is null
       and c.kind = 'expense'
       and c.name = m.name
       and not exists (select 1 from public.categories x where x.user_id = v_user and x.default_key = m.key);

    insert into public.categories (user_id, name, kind, color, icon, is_default, sort_order, default_key)
    select v_user, m.name, 'expense', '#334155', m.icon, true, m.sort_order, m.key
      from (values ('Darlehen', 'landmark', 196, 'loan'),
                   ('Darlehenszinsen', 'percent', 197, 'loan_interest')) as m (name, icon, sort_order, key)
     where not exists (select 1 from public.categories c where c.user_id = v_user and c.default_key = m.key)
    on conflict on constraint categories_name_key do nothing;
  end loop;
end;
$$;

-- ---------------------------------------------------------------------
-- 3. Summen je Monat, Währung und Kategorie
-- ---------------------------------------------------------------------
-- amount      = Summe der Buchungen (Vorzeichen wie transactions.amount);
--               ohne Kategorie nur Abflüsse (positive zählen nirgends)
-- flag        = taxes (Steuern & Abgaben, Kapitalertragsteuer) | loan
--               (Darlehen, Darlehenszinsen, Kredittilgung) – auch für
--               deren Unterkategorien; sonst NULL
-- own_account = Gegenkonto ist ein eigenes Konto (aktive IBAN-Regel)
-- Ausgelassen: exclude_from_budget. Getrennt je Buchungswährung.
create or replace function public.budget_category_totals(
  p_user_id uuid,
  p_from    date,
  p_to      date
)
returns table (
  month        date,
  currency     text,
  category_id  uuid,
  budget_group public.budget_group,
  kind         public.category_kind,
  flag         text,
  own_account  boolean,
  amount       numeric
)
language plpgsql
stable
security invoker
set search_path = ''
as $$
begin
  if p_user_id is null or p_from is null or p_to is null or p_from > p_to
     or p_to > (p_from + interval '5 years 3 months') then
    raise exception 'invalid_period' using errcode = '22023';
  end if;

  return query
  with own_ibans as (
    select upper(r.pattern) as iban
      from public.categorization_rules r
     where r.user_id = p_user_id
       and r.origin = 'own_account'
       and r.is_active
       and r.match_field = 'counterparty_iban'
  ),
  tx as (
    select date_trunc('month', t.booking_date)::date as month,
           t.currency::text as currency,
           t.category_id,
           c.budget_group,
           c.kind,
           case
             when coalesce(c.default_key, p.default_key) in ('taxes', 'capital_gains_tax') then 'taxes'
             when coalesce(c.default_key, p.default_key) in ('loan', 'loan_interest', 'loan_repayment') then 'loan'
           end as flag,
           coalesce(t.counterparty_iban in (select o.iban from own_ibans o), false) as own_account,
           t.amount
      from public.transactions t
      left join public.categories c on c.id = t.category_id and c.user_id = t.user_id
      left join public.categories p on p.id = c.parent_category_id and p.user_id = c.user_id
     where t.user_id = p_user_id
       and t.booking_date between p_from and p_to
       and not t.exclude_from_budget
       and (t.category_id is not null or t.amount < 0)
  )
  select tx.month, tx.currency, tx.category_id, tx.budget_group, tx.kind, tx.flag, tx.own_account, sum(tx.amount)
    from tx
   group by tx.month, tx.currency, tx.category_id, tx.budget_group, tx.kind, tx.flag, tx.own_account
   order by tx.month, tx.currency, tx.category_id nulls last, tx.own_account;
end;
$$;

comment on function public.budget_category_totals(uuid, date, date) is
  'Summen je Monat, Buchungswährung und Kategorie mit Gruppe, Art, Merkmal (taxes/loan) und eigenem Gegenkonto '
  '(SECURITY INVOKER, RLS aktiv). Fehler invalid_period (22023): fehlende Angaben, von > bis, mehr als 5 Jahre '
  'und 3 Monate (Zeitraum plus drei Vormonate).';

-- ---------------------------------------------------------------------
-- Rechte
-- ---------------------------------------------------------------------
revoke all on function public.save_budget_settings(public.budget_basis, numeric, numeric, numeric, numeric, public.currency_code)
  from public, anon;
revoke all on function public.budget_category_totals(uuid, date, date) from public, anon;
grant execute on function public.save_budget_settings(public.budget_basis, numeric, numeric, numeric, numeric, public.currency_code)
  to authenticated;
grant execute on function public.budget_category_totals(uuid, date, date) to authenticated;

commit;
