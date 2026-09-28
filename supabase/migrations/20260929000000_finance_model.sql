-- =====================================================================
--  supabase/migrations/20260929000000_finance_model.sql
--  Phase 3 · Erweitertes Datenmodell (Kategorisierung, Tags, Budgets,
--  Vertragserkennung, Kategorisierungsregeln)
--
--  Baut auf 00000000000000_initial_schema.sql auf und folgt denselben
--  Sicherheitsprinzipien:
--  1. Jede neue Tabelle hat user_id (indiziert, Default auth.uid()) und RLS.
--  2. Owner-Policies strikt nach (select auth.uid()) = user_id; Berater lesen
--     über private.advisor_client_ids(), schreiben nie.
--  3. Verweise zwischen Mandantendaten laufen über zusammengesetzte
--     Fremdschlüssel (id, user_id) – FK-Prüfungen umgehen RLS, ohne diese
--     Constraints könnte Mandant A auf IDs von Mandant B verweisen.
--  4. Rechte zusätzlich über Grants (anon: nichts).
--
--  Bestehende Tabellen werden erweitert statt neu angelegt:
--    categories   – parent_id → parent_category_id (Ober-/Unterkategorien)
--    transactions – source, recurring_contract_id, Tags über transaction_tags
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. Enums
-- ---------------------------------------------------------------------
create type public.transaction_source  as enum ('manual', 'csv_import', 'bank_sync');
create type public.budget_period       as enum ('weekly', 'monthly', 'quarterly', 'yearly');
create type public.contract_rhythm     as enum ('weekly', 'monthly', 'quarterly', 'semiannual', 'yearly');
create type public.contract_status     as enum ('suggested', 'active', 'cancellation_pending', 'cancelled', 'dismissed');
create type public.contract_detection  as enum ('manual', 'auto');
create type public.rule_match_field    as enum ('counterparty', 'purpose', 'counterparty_or_purpose');
create type public.rule_match_type     as enum ('contains', 'equals', 'starts_with', 'regex');

-- ---------------------------------------------------------------------
-- 2. categories: Ober-/Unterkategorien
-- ---------------------------------------------------------------------
-- Der zusammengesetzte FK categories_parent_fkey (parent, user_id) und der
-- Unique-Key categories_name_key ziehen beim Umbenennen automatisch mit.
alter table public.categories rename column parent_id to parent_category_id;
alter index public.categories_parent_id_idx rename to categories_parent_category_id_idx;

-- ---------------------------------------------------------------------
-- 3. transactions: Herkunft & Zielschlüssel für Verweise
-- ---------------------------------------------------------------------
alter table public.transactions
  add column source public.transaction_source not null default 'manual',
  add column recurring_contract_id uuid,
  -- Ziel für zusammengesetzte FKs (transaction_tags); id ist bereits PK.
  add constraint transactions_id_user_id_key unique (id, user_id);

comment on column public.transactions.source is
  'Herkunft der Buchung: manual (Erfassung im Portal), csv_import, bank_sync.';

-- Bestandsdaten: Herkunft aus den vorhandenen Import-Merkmalen ableiten.
update public.transactions
   set source = case
                  when import_hash is not null then 'csv_import'::public.transaction_source
                  when external_id is not null then 'bank_sync'::public.transaction_source
                  else 'manual'::public.transaction_source
                end;

-- ---------------------------------------------------------------------
-- 4. tags (mandantenspezifisch, unabhängig von categories)
-- ---------------------------------------------------------------------
create table public.tags (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null default auth.uid(),
  name        text not null check (char_length(btrim(name)) between 1 and 50),
  color       text check (color ~ '^#[0-9a-fA-F]{6}$'),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),

  constraint tags_user_id_fkey
    foreign key (user_id) references auth.users (id) on delete cascade,
  constraint tags_id_user_id_key unique (id, user_id)
);

-- "Urlaub" und "urlaub" sind derselbe Tag.
create unique index tags_user_name_key on public.tags (user_id, lower(name));

-- ---------------------------------------------------------------------
-- 5. transaction_tags (n:m)
-- ---------------------------------------------------------------------
create table public.transaction_tags (
  transaction_id  uuid not null,
  tag_id          uuid not null,
  user_id         uuid not null default auth.uid(),
  created_at      timestamptz not null default now(),

  primary key (transaction_id, tag_id),
  constraint transaction_tags_user_id_fkey
    foreign key (user_id) references auth.users (id) on delete cascade,
  constraint transaction_tags_transaction_fkey
    foreign key (transaction_id, user_id) references public.transactions (id, user_id) on delete cascade,
  constraint transaction_tags_tag_fkey
    foreign key (tag_id, user_id) references public.tags (id, user_id) on delete cascade
);

-- ---------------------------------------------------------------------
-- 6. budgets (genau eine Bezugsgröße: Kategorie ODER Tag ODER Konto)
-- ---------------------------------------------------------------------
create table public.budgets (
  id                   uuid primary key default gen_random_uuid(),
  user_id              uuid not null default auth.uid(),
  name                 text not null check (char_length(name) between 1 and 120),
  category_id          uuid,
  tag_id               uuid,
  account_id           uuid,
  period               public.budget_period not null default 'monthly',
  starts_on            date not null default (date_trunc('month', current_date))::date,
  ends_on              date,
  -- Obergrenze der Ausgaben je Zeitraum (positiver Betrag).
  amount               numeric(14,2) not null check (amount > 0),
  currency             public.currency_code not null default 'EUR',
  -- Warnschwelle in % der Obergrenze.
  alert_threshold_pct  smallint not null default 80 check (alert_threshold_pct between 1 and 100),
  is_active            boolean not null default true,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),

  constraint budgets_user_id_fkey
    foreign key (user_id) references auth.users (id) on delete cascade,
  constraint budgets_single_scope
    check (num_nonnulls(category_id, tag_id, account_id) = 1),
  constraint budgets_date_range
    check (ends_on is null or ends_on >= starts_on),
  constraint budgets_category_fkey
    foreign key (category_id, user_id) references public.categories (id, user_id) on delete cascade,
  constraint budgets_tag_fkey
    foreign key (tag_id, user_id) references public.tags (id, user_id) on delete cascade,
  constraint budgets_account_fkey
    foreign key (account_id, user_id) references public.accounts (id, user_id) on delete cascade
);

comment on column public.budgets.amount is 'Ausgaben-Obergrenze je Zeitraum (positiv).';
comment on column public.budgets.alert_threshold_pct is 'Warnung ab diesem Anteil der Obergrenze (Prozent).';

-- ---------------------------------------------------------------------
-- 7. recurring_contracts (erkannte oder manuell angelegte Verträge)
-- ---------------------------------------------------------------------
-- Die zugehörige Transaktionsgruppe sind alle transactions mit
-- recurring_contract_id = id (FK unten, nach Anlage der Tabelle).
create table public.recurring_contracts (
  id                     uuid primary key default gen_random_uuid(),
  user_id                uuid not null default auth.uid(),
  name                   text not null check (char_length(name) between 1 and 120),
  counterparty_name      text check (char_length(counterparty_name) <= 200),
  -- Muster, über das Buchungen dem Vertrag zugeordnet werden (z. B. Empfänger).
  match_pattern          text check (char_length(match_pattern) <= 200),
  account_id             uuid,
  category_id            uuid,
  rhythm                 public.contract_rhythm not null default 'monthly',
  -- Alle n Rhythmus-Einheiten (z. B. rhythm = weekly, interval_count = 2 → 14-täglich).
  interval_count         smallint not null default 1 check (interval_count between 1 and 24),
  -- Vorzeichen wie transactions.amount (negativ = Ausgabe).
  expected_amount        numeric(14,2),
  amount_tolerance_pct   numeric(5,2) not null default 10 check (amount_tolerance_pct between 0 and 100),
  currency               public.currency_code not null default 'EUR',
  first_booking_date     date,
  last_booking_date      date,
  next_expected_date     date,
  -- Kündigungsfrist in Tagen und Ende der (Mindest-)Laufzeit bzw. nächste Verlängerung.
  notice_period_days     smallint check (notice_period_days between 0 and 730),
  term_end_date          date,
  cancellation_deadline  date generated always as (term_end_date - notice_period_days) stored,
  auto_renewal           boolean not null default true,
  status                 public.contract_status not null default 'suggested',
  detection_source       public.contract_detection not null default 'manual',
  detection_confidence   numeric(3,2) check (detection_confidence between 0 and 1),
  cancelled_on           date,
  notes                  text check (char_length(notes) <= 2000),
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),

  constraint recurring_contracts_user_id_fkey
    foreign key (user_id) references auth.users (id) on delete cascade,
  constraint recurring_contracts_id_user_id_key unique (id, user_id),
  constraint recurring_contracts_account_fkey
    foreign key (account_id, user_id) references public.accounts (id, user_id)
    on delete set null (account_id),
  constraint recurring_contracts_category_fkey
    foreign key (category_id, user_id) references public.categories (id, user_id)
    on delete set null (category_id),
  constraint recurring_contracts_booking_dates
    check (last_booking_date is null or first_booking_date is null or last_booking_date >= first_booking_date),
  constraint recurring_contracts_auto_confidence
    check (detection_source = 'auto' or detection_confidence is null)
);

comment on column public.recurring_contracts.cancellation_deadline is
  'Letzter Kündigungstag: term_end_date − notice_period_days (berechnet).';

alter table public.transactions
  add constraint transactions_recurring_contract_fkey
    foreign key (recurring_contract_id, user_id)
    references public.recurring_contracts (id, user_id)
    on delete set null (recurring_contract_id);

-- ---------------------------------------------------------------------
-- 8. categorization_rules (Muster für Empfänger/Text → Kategorie)
-- ---------------------------------------------------------------------
create table public.categorization_rules (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null default auth.uid(),
  category_id     uuid not null,
  name            text check (char_length(name) <= 120),
  match_field     public.rule_match_field not null default 'counterparty_or_purpose',
  match_type      public.rule_match_type not null default 'contains',
  pattern         text not null check (char_length(pattern) between 1 and 200),
  case_sensitive  boolean not null default false,
  -- Optionale Einschränkungen
  account_id      uuid,
  amount_min      numeric(14,2),
  amount_max      numeric(14,2),
  -- Kleinere Zahl = höhere Priorität; bei Gleichstand gewinnt die ältere Regel.
  priority        smallint not null default 100 check (priority between 0 and 1000),
  is_active       boolean not null default true,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),

  constraint categorization_rules_user_id_fkey
    foreign key (user_id) references auth.users (id) on delete cascade,
  constraint categorization_rules_category_fkey
    foreign key (category_id, user_id) references public.categories (id, user_id) on delete cascade,
  constraint categorization_rules_account_fkey
    foreign key (account_id, user_id) references public.accounts (id, user_id) on delete cascade,
  constraint categorization_rules_amount_range
    check (amount_min is null or amount_max is null or amount_min <= amount_max)
);

-- Ungültige reguläre Ausdrücke früh abweisen statt erst beim Anwenden.
create or replace function private.categorization_rules_validate_pattern()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.match_type = 'regex' then
    begin
      perform '' ~ new.pattern;
    exception when invalid_regular_expression then
      raise exception 'categorization_rules: ungültiger regulärer Ausdruck'
        using errcode = '22023';
    end;
  end if;
  return new;
end;
$$;

create trigger validate_pattern
  before insert or update of match_type, pattern on public.categorization_rules
  for each row execute function private.categorization_rules_validate_pattern();

-- ---------------------------------------------------------------------
-- 9. Indizes (user_id + Fremdschlüssel)
-- ---------------------------------------------------------------------
create index transactions_recurring_contract_idx
  on public.transactions (recurring_contract_id) where recurring_contract_id is not null;
create index transactions_user_source_idx on public.transactions (user_id, source);

create index tags_user_id_idx on public.tags (user_id);

create index transaction_tags_user_id_idx on public.transaction_tags (user_id);
create index transaction_tags_tag_id_idx  on public.transaction_tags (tag_id);

create index budgets_user_id_idx     on public.budgets (user_id);
create index budgets_category_id_idx on public.budgets (category_id) where category_id is not null;
create index budgets_tag_id_idx      on public.budgets (tag_id)      where tag_id is not null;
create index budgets_account_id_idx  on public.budgets (account_id)  where account_id is not null;

create index recurring_contracts_user_status_idx  on public.recurring_contracts (user_id, status);
create index recurring_contracts_account_id_idx   on public.recurring_contracts (account_id)  where account_id is not null;
create index recurring_contracts_category_id_idx  on public.recurring_contracts (category_id) where category_id is not null;
create index recurring_contracts_deadline_idx
  on public.recurring_contracts (user_id, cancellation_deadline) where cancellation_deadline is not null;

create index categorization_rules_user_priority_idx
  on public.categorization_rules (user_id, priority) where is_active;
create index categorization_rules_category_id_idx on public.categorization_rules (category_id);
create index categorization_rules_account_id_idx
  on public.categorization_rules (account_id) where account_id is not null;

-- ---------------------------------------------------------------------
-- 10. updated_at-Trigger
-- ---------------------------------------------------------------------
create trigger set_updated_at before update on public.tags
  for each row execute function private.set_updated_at();
create trigger set_updated_at before update on public.budgets
  for each row execute function private.set_updated_at();
create trigger set_updated_at before update on public.recurring_contracts
  for each row execute function private.set_updated_at();
create trigger set_updated_at before update on public.categorization_rules
  for each row execute function private.set_updated_at();

-- ---------------------------------------------------------------------
-- 11. Row Level Security
-- ---------------------------------------------------------------------
alter table public.tags                 enable row level security;
alter table public.transaction_tags     enable row level security;
alter table public.budgets              enable row level security;
alter table public.recurring_contracts  enable row level security;
alter table public.categorization_rules enable row level security;

-- 11.1 tags
create policy tags_select_owner_or_advisor on public.tags
  for select to authenticated
  using ((select auth.uid()) = user_id or user_id in (select private.advisor_client_ids()));
create policy tags_insert_owner on public.tags
  for insert to authenticated with check ((select auth.uid()) = user_id);
create policy tags_update_owner on public.tags
  for update to authenticated
  using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy tags_delete_owner on public.tags
  for delete to authenticated using ((select auth.uid()) = user_id);

-- 11.2 transaction_tags (kein UPDATE – Zuordnung löschen und neu anlegen)
create policy transaction_tags_select_owner_or_advisor on public.transaction_tags
  for select to authenticated
  using ((select auth.uid()) = user_id or user_id in (select private.advisor_client_ids()));
create policy transaction_tags_insert_owner on public.transaction_tags
  for insert to authenticated with check ((select auth.uid()) = user_id);
create policy transaction_tags_delete_owner on public.transaction_tags
  for delete to authenticated using ((select auth.uid()) = user_id);

-- 11.3 budgets
create policy budgets_select_owner_or_advisor on public.budgets
  for select to authenticated
  using ((select auth.uid()) = user_id or user_id in (select private.advisor_client_ids()));
create policy budgets_insert_owner on public.budgets
  for insert to authenticated with check ((select auth.uid()) = user_id);
create policy budgets_update_owner on public.budgets
  for update to authenticated
  using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy budgets_delete_owner on public.budgets
  for delete to authenticated using ((select auth.uid()) = user_id);

-- 11.4 recurring_contracts
create policy recurring_contracts_select_owner_or_advisor on public.recurring_contracts
  for select to authenticated
  using ((select auth.uid()) = user_id or user_id in (select private.advisor_client_ids()));
create policy recurring_contracts_insert_owner on public.recurring_contracts
  for insert to authenticated with check ((select auth.uid()) = user_id);
create policy recurring_contracts_update_owner on public.recurring_contracts
  for update to authenticated
  using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy recurring_contracts_delete_owner on public.recurring_contracts
  for delete to authenticated using ((select auth.uid()) = user_id);

-- 11.5 categorization_rules
create policy categorization_rules_select_owner_or_advisor on public.categorization_rules
  for select to authenticated
  using ((select auth.uid()) = user_id or user_id in (select private.advisor_client_ids()));
create policy categorization_rules_insert_owner on public.categorization_rules
  for insert to authenticated with check ((select auth.uid()) = user_id);
create policy categorization_rules_update_owner on public.categorization_rules
  for update to authenticated
  using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy categorization_rules_delete_owner on public.categorization_rules
  for delete to authenticated using ((select auth.uid()) = user_id);

-- ---------------------------------------------------------------------
-- 12. Privilegien
-- ---------------------------------------------------------------------
revoke all on
  public.tags, public.transaction_tags, public.budgets,
  public.recurring_contracts, public.categorization_rules
from anon, authenticated;

grant select, insert, update, delete on
  public.tags, public.budgets, public.recurring_contracts, public.categorization_rules
to authenticated;

grant select, insert, delete on public.transaction_tags to authenticated;

-- cancellation_deadline ist generiert und damit ohnehin nicht beschreibbar.

revoke all on function private.categorization_rules_validate_pattern() from public, anon, authenticated;

commit;
