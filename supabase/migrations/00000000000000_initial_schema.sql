-- =====================================================================
--  supabase/migrations/00000000000000_init.sql
--  Phase 1 · Datenbankschema, Auth-Trigger & RLS-Sicherheit
--  Zielplattform: Supabase · PostgreSQL 15+ · Region eu-central-1 (Frankfurt)
--
--  Sicherheitsprinzipien
--  1. Jede Tabelle in `public` hat `user_id` (indiziert) und aktiviertes RLS.
--  2. Owner-Policies strikt nach `(select auth.uid()) = user_id`.
--  3. Berater-Lesezugriff ausschließlich über SECURITY-DEFINER-Helper im
--     NICHT exponierten Schema `private` (keine Policy-Rekursion, initPlan-Caching).
--  4. Mandantenübergreifende Referenzen werden über zusammengesetzte
--     Fremdschlüssel (id, user_id) verhindert. FK-Prüfungen umgehen RLS –
--     ohne diese Constraints könnte Mandant A auf IDs von Mandant B verweisen.
--  5. Privilegien-Eskalation (z. B. role = 'advisor') wird über Spalten-Grants
--     verhindert, nicht nur über Policies.
--  6. Datenminimierung (Art. 5 Abs. 1 lit. c DSGVO): keine E-Mail-Kopie in
--     `profiles`, nur IBAN-Endziffern, keine Banking-Tokens in `public`.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 0. Extensions & Schemas
-- ---------------------------------------------------------------------
create extension if not exists pgcrypto with schema extensions;

-- `private` darf NICHT unter "API → Exposed schemas" eingetragen werden.
create schema if not exists private;
revoke all on schema private from public, anon, authenticated;
grant usage on schema private to authenticated;

-- ---------------------------------------------------------------------
-- 1. Enums & Domains
-- ---------------------------------------------------------------------
create type public.user_role             as enum ('client', 'advisor');
create type public.advisor_link_status   as enum ('invited', 'active', 'revoked');
create type public.account_type          as enum ('checking', 'savings', 'credit_card', 'depot', 'loan', 'cash', 'other');
create type public.account_provider      as enum ('manual', 'csv', 'gocardless', 'enable_banking', 'plaid');
create type public.category_kind         as enum ('income', 'expense', 'transfer');
create type public.categorization_source as enum ('manual', 'rule', 'provider', 'ai');
create type public.instrument_type       as enum ('stock', 'etf', 'fund', 'bond', 'crypto', 'commodity', 'cash', 'other');
create type public.asset_class           as enum ('equity', 'fixed_income', 'real_estate', 'commodity', 'crypto', 'cash', 'other');
create type public.market_region         as enum ('global', 'north_america', 'europe', 'japan', 'asia_pacific', 'emerging_markets', 'other');
create type public.real_estate_usage     as enum ('self_occupied', 'rented', 'mixed', 'vacant');

create domain public.currency_code as text
  check (value ~ '^[A-Z]{3}$');

-- ---------------------------------------------------------------------
-- 2. Generische Trigger-Funktion
-- ---------------------------------------------------------------------
create or replace function private.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

-- ---------------------------------------------------------------------
-- 3. Tabellen
-- ---------------------------------------------------------------------

-- 3.1 profiles ---------------------------------------------------------
-- user_id ist Primärschlüssel (1:1 zu auth.users) und damit zugleich der
-- Pflicht-Index. Die E-Mail bleibt ausschließlich in auth.users.
create table public.profiles (
  user_id                 uuid primary key,
  role                    public.user_role not null default 'client',
  first_name              text check (char_length(first_name) <= 100),
  last_name               text check (char_length(last_name) <= 100),
  locale                  text not null default 'de-DE' check (locale ~ '^[a-z]{2}-[A-Z]{2}$'),
  base_currency           public.currency_code not null default 'EUR',
  onboarding_completed_at timestamptz,
  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now(),

  constraint profiles_user_id_fkey
    foreign key (user_id) references auth.users (id) on delete cascade
);

comment on column public.profiles.role is
  'Nur per service_role änderbar – authenticated besitzt keinen Spalten-Grant.';

-- 3.2 advisor_clients --------------------------------------------------
-- user_id = Mandant (Dateneigentümer). Bleibt NULL, solange die Einladung
-- offen ist; wird ausschließlich über accept_advisor_invitation() gesetzt.
create table public.advisor_clients (
  id                 uuid primary key default gen_random_uuid(),
  user_id            uuid,
  advisor_id         uuid not null default auth.uid(),
  status             public.advisor_link_status not null default 'invited',
  invited_email      text not null
                       check (invited_email = lower(invited_email))
                       check (char_length(invited_email) <= 320)
                       check (invited_email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  invite_token_hash  text check (invite_token_hash ~ '^[0-9a-f]{64}$'),
  invite_expires_at  timestamptz,
  invited_at         timestamptz not null default now(),
  accepted_at        timestamptz,
  revoked_at         timestamptz,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),

  constraint advisor_clients_user_id_fkey
    foreign key (user_id) references public.profiles (user_id) on delete cascade,
  constraint advisor_clients_advisor_id_fkey
    foreign key (advisor_id) references public.profiles (user_id) on delete cascade,
  constraint advisor_clients_no_self_link
    check (user_id is null or user_id <> advisor_id),
  constraint advisor_clients_status_consistency check (
       (status = 'invited' and user_id is null
          and invite_token_hash is not null and invite_expires_at is not null)
    or (status = 'active'  and user_id is not null and accepted_at is not null)
    or (status = 'revoked' and revoked_at is not null)
  )
);

comment on column public.advisor_clients.invite_token_hash is
  'SHA-256 (hex) des Einladungstokens. Das Klartext-Token existiert nur im E-Mail-Link.';

-- 3.3 accounts ---------------------------------------------------------
-- Vorzeichenkonvention: balance aus Sicht des Mandanten
-- (Guthaben positiv, Kredite/Kreditkartensalden negativ).
-- Provider-Zugangstokens gehören NICHT hierher (→ späteres Server-only-Schema + Vault).
create table public.accounts (
  id                   uuid primary key default gen_random_uuid(),
  user_id              uuid not null default auth.uid(),
  name                 text not null check (char_length(name) between 1 and 120),
  type                 public.account_type not null,
  provider             public.account_provider not null default 'manual',
  provider_account_id  text check (char_length(provider_account_id) <= 255),
  institution_name     text check (char_length(institution_name) <= 120),
  iban_last4           text check (iban_last4 ~ '^[0-9A-Z]{4}$'),
  currency             public.currency_code not null default 'EUR',
  balance              numeric(14,2) not null default 0,
  balance_updated_at   timestamptz,
  is_liability         boolean generated always as (
                         type in ('loan'::public.account_type, 'credit_card'::public.account_type)
                       ) stored,
  include_in_net_worth boolean not null default true,
  last_synced_at       timestamptz,
  archived_at          timestamptz,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),

  constraint accounts_user_id_fkey
    foreign key (user_id) references auth.users (id) on delete cascade,
  constraint accounts_id_user_id_key unique (id, user_id),
  constraint accounts_provider_ref_key unique (user_id, provider, provider_account_id)
);

-- 3.4 categories -------------------------------------------------------
-- Keine globalen System-Kategorien (user_id NULL würde das RLS-Muster brechen);
-- Standardkategorien werden je Nutzer beim Signup geseedet.
create table public.categories (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null default auth.uid(),
  parent_id   uuid,
  name        text not null check (char_length(name) between 1 and 60),
  kind        public.category_kind not null,
  color       text check (color ~ '^#[0-9a-fA-F]{6}$'),
  icon        text check (char_length(icon) <= 50),
  is_default  boolean not null default false,
  sort_order  smallint not null default 0,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),

  constraint categories_user_id_fkey
    foreign key (user_id) references auth.users (id) on delete cascade,
  constraint categories_id_user_id_key unique (id, user_id),
  constraint categories_parent_fkey
    foreign key (parent_id, user_id) references public.categories (id, user_id) on delete cascade,
  constraint categories_no_self_parent check (parent_id is null or parent_id <> id),
  constraint categories_name_key unique nulls not distinct (user_id, parent_id, name)
);

comment on column public.categories.icon is 'Lucide-Icon-Name (kebab-case), z. B. "shopping-cart".';

-- 3.5 transactions -----------------------------------------------------
-- amount: negativ = Ausgabe, positiv = Einnahme.
create table public.transactions (
  id                     uuid primary key default gen_random_uuid(),
  user_id                uuid not null default auth.uid(),
  account_id             uuid not null,
  category_id            uuid,
  booking_date           date not null,
  value_date             date,
  amount                 numeric(14,2) not null,
  currency               public.currency_code not null default 'EUR',
  counterparty_name      text check (char_length(counterparty_name) <= 200),
  purpose                text check (char_length(purpose) <= 1000),
  categorization_source  public.categorization_source,
  external_id            text check (char_length(external_id) <= 255),
  import_hash            text check (import_hash ~ '^[0-9a-f]{64}$'),
  notes                  text check (char_length(notes) <= 2000),
  exclude_from_budget    boolean not null default false,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),

  constraint transactions_user_id_fkey
    foreign key (user_id) references auth.users (id) on delete cascade,
  constraint transactions_account_fkey
    foreign key (account_id, user_id) references public.accounts (id, user_id) on delete cascade,
  constraint transactions_category_fkey
    foreign key (category_id, user_id) references public.categories (id, user_id)
    on delete set null (category_id)
);

comment on column public.transactions.import_hash is
  'SHA-256 (hex) über normalisierte CSV-Zeile – Duplikaterkennung bei Re-Imports.';

-- 3.6 portfolios -------------------------------------------------------
create table public.portfolios (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null default auth.uid(),
  account_id  uuid,
  name        text not null check (char_length(name) between 1 and 120),
  broker      text check (char_length(broker) <= 120),
  currency    public.currency_code not null default 'EUR',
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),

  constraint portfolios_user_id_fkey
    foreign key (user_id) references auth.users (id) on delete cascade,
  constraint portfolios_id_user_id_key unique (id, user_id),
  constraint portfolios_account_fkey
    foreign key (account_id, user_id) references public.accounts (id, user_id)
    on delete set null (account_id)
);

-- 3.7 assets -----------------------------------------------------------
-- Positionen im Depot oder frei (z. B. physisches Gold, Wallet) mit portfolio_id NULL.
-- exposure: Look-through-Gewichte (0..1) für ETFs/Fonds, z. B.
--   {"regions": {"north_america": 0.63, "europe": 0.15}, "sectors": {"it": 0.24}}
create table public.assets (
  id                  uuid primary key default gen_random_uuid(),
  user_id             uuid not null default auth.uid(),
  portfolio_id        uuid,
  name                text not null check (char_length(name) between 1 and 200),
  instrument_type     public.instrument_type not null,
  asset_class         public.asset_class not null,
  region              public.market_region not null default 'other',
  isin                text check (isin ~ '^[A-Z]{2}[A-Z0-9]{9}[0-9]$'),
  wkn                 text check (wkn ~ '^[A-Z0-9]{6}$'),
  ticker              text check (char_length(ticker) <= 20),
  sector              text check (char_length(sector) <= 80),
  currency            public.currency_code not null default 'EUR',
  quantity            numeric(24,8) not null default 0 check (quantity >= 0),
  avg_purchase_price  numeric(18,6) check (avg_purchase_price >= 0),
  current_price       numeric(18,6) check (current_price >= 0),
  price_updated_at    timestamptz,
  market_value        numeric(20,2) generated always as (
                        round(quantity * coalesce(current_price, 0), 2)
                      ) stored,
  exposure            jsonb not null default '{}'::jsonb
                        check (jsonb_typeof(exposure) = 'object'),
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),

  constraint assets_user_id_fkey
    foreign key (user_id) references auth.users (id) on delete cascade,
  constraint assets_id_user_id_key unique (id, user_id),
  constraint assets_portfolio_fkey
    foreign key (portfolio_id, user_id) references public.portfolios (id, user_id) on delete cascade
);

-- 3.8 real_estate_objects ----------------------------------------------
create table public.real_estate_objects (
  id                           uuid primary key default gen_random_uuid(),
  user_id                      uuid not null default auth.uid(),
  name                         text not null check (char_length(name) between 1 and 120),
  usage                        public.real_estate_usage not null default 'rented',
  street                       text check (char_length(street) <= 200),
  postal_code                  text check (postal_code ~ '^[0-9A-Za-z -]{3,10}$'),
  city                         text check (char_length(city) <= 120),
  country_code                 text not null default 'DE' check (country_code ~ '^[A-Z]{2}$'),
  purchase_date                date,
  purchase_price               numeric(14,2) check (purchase_price >= 0),
  ancillary_purchase_costs     numeric(14,2) not null default 0 check (ancillary_purchase_costs >= 0),
  current_value                numeric(14,2) check (current_value >= 0),
  valuation_date               date,
  living_area_sqm              numeric(8,2) check (living_area_sqm > 0),
  monthly_cold_rent            numeric(12,2) not null default 0 check (monthly_cold_rent >= 0),
  monthly_non_allocable_costs  numeric(12,2) not null default 0 check (monthly_non_allocable_costs >= 0),
  building_share_pct           numeric(5,2) check (building_share_pct between 0 and 100),
  loan_account_id              uuid,
  notes                        text check (char_length(notes) <= 2000),
  created_at                   timestamptz not null default now(),
  updated_at                   timestamptz not null default now(),

  constraint real_estate_objects_user_id_fkey
    foreign key (user_id) references auth.users (id) on delete cascade,
  constraint real_estate_objects_id_user_id_key unique (id, user_id),
  constraint real_estate_objects_loan_account_fkey
    foreign key (loan_account_id, user_id) references public.accounts (id, user_id)
    on delete set null (loan_account_id)
);

comment on column public.real_estate_objects.ancillary_purchase_costs is
  'Kaufnebenkosten: Grunderwerbsteuer, Notar, Grundbuch, Makler.';
comment on column public.real_estate_objects.building_share_pct is
  'Gebäudeanteil am Kaufpreis in % – Basis für AfA-Berechnung.';

-- ---------------------------------------------------------------------
-- 4. Indizes (user_id-Index auf JEDER Tabelle)
-- ---------------------------------------------------------------------
-- profiles: PK (user_id) ist der Pflicht-Index.

create index advisor_clients_user_id_idx        on public.advisor_clients (user_id);
create index advisor_clients_advisor_status_idx on public.advisor_clients (advisor_id, status);
create unique index advisor_clients_active_pair_key
  on public.advisor_clients (advisor_id, user_id) where status = 'active';
create unique index advisor_clients_open_invite_key
  on public.advisor_clients (advisor_id, invited_email) where status = 'invited';
create unique index advisor_clients_token_hash_key
  on public.advisor_clients (invite_token_hash) where invite_token_hash is not null;

create index accounts_user_id_idx on public.accounts (user_id);

create index categories_user_id_idx   on public.categories (user_id);
create index categories_parent_id_idx on public.categories (parent_id) where parent_id is not null;

-- Größte Tabelle: der zusammengesetzte Index beginnt mit user_id und IST damit
-- der Pflicht-Index; ein zusätzlicher Einzelindex wäre reiner Schreib-Overhead.
create index transactions_user_id_booking_date_idx
  on public.transactions (user_id, booking_date desc, id);
create index transactions_account_booking_date_idx
  on public.transactions (account_id, booking_date desc);
create index transactions_category_id_idx
  on public.transactions (category_id) where category_id is not null;
create unique index transactions_external_id_key
  on public.transactions (account_id, external_id) where external_id is not null;
create unique index transactions_import_hash_key
  on public.transactions (account_id, import_hash) where import_hash is not null;

create index portfolios_user_id_idx    on public.portfolios (user_id);
create index portfolios_account_id_idx on public.portfolios (account_id) where account_id is not null;

create index assets_user_id_idx      on public.assets (user_id);
create index assets_portfolio_id_idx on public.assets (portfolio_id) where portfolio_id is not null;
create unique index assets_portfolio_isin_key
  on public.assets (portfolio_id, isin) where portfolio_id is not null and isin is not null;

create index real_estate_objects_user_id_idx on public.real_estate_objects (user_id);
create index real_estate_objects_loan_account_idx
  on public.real_estate_objects (loan_account_id) where loan_account_id is not null;

-- ---------------------------------------------------------------------
-- 5. updated_at-Trigger
-- ---------------------------------------------------------------------
create trigger set_updated_at before update on public.profiles
  for each row execute function private.set_updated_at();
create trigger set_updated_at before update on public.advisor_clients
  for each row execute function private.set_updated_at();
create trigger set_updated_at before update on public.accounts
  for each row execute function private.set_updated_at();
create trigger set_updated_at before update on public.categories
  for each row execute function private.set_updated_at();
create trigger set_updated_at before update on public.transactions
  for each row execute function private.set_updated_at();
create trigger set_updated_at before update on public.portfolios
  for each row execute function private.set_updated_at();
create trigger set_updated_at before update on public.assets
  for each row execute function private.set_updated_at();
create trigger set_updated_at before update on public.real_estate_objects
  for each row execute function private.set_updated_at();

-- ---------------------------------------------------------------------
-- 6. advisor_clients: Statusübergänge absichern
-- ---------------------------------------------------------------------
-- Über die Data API (Rolle authenticated) ist nur der Übergang → 'revoked'
-- erlaubt (Widerruf durch Mandant oder Berater). 'active' entsteht ausschließlich
-- in accept_advisor_invitation(); dort läuft der Trigger als Funktions-Owner.
create or replace function private.advisor_clients_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.status is distinct from old.status then
    if current_user in ('authenticated', 'anon') and new.status <> 'revoked' then
      raise exception 'advisor_clients: Statuswechsel % -> % ist nicht erlaubt', old.status, new.status
        using errcode = '42501';
    end if;

    if new.status = 'revoked' then
      new.revoked_at        := now();
      new.invite_token_hash := null;
      new.invite_expires_at := null;
    end if;
  end if;

  return new;
end;
$$;

create trigger guard_status_transition before update on public.advisor_clients
  for each row execute function private.advisor_clients_guard();

-- ---------------------------------------------------------------------
-- 7. SECURITY-DEFINER-Helper für RLS (Schema private, nicht exponiert)
-- ---------------------------------------------------------------------
-- Laufen als Owner (bypasst RLS) → keine Rekursion zwischen Policies.
-- In Policies als `user_id in (select private.advisor_client_ids())` genutzt:
-- unkorrelierte Subquery → einmal pro Statement ausgewertet (hashed SubPlan).

create or replace function private.is_advisor()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.profiles p
    where p.user_id = (select auth.uid())
      and p.role = 'advisor'
  );
$$;

create or replace function private.advisor_client_ids()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select ac.user_id
  from public.advisor_clients ac
  where ac.advisor_id = (select auth.uid())
    and ac.status = 'active'
    and ac.user_id is not null;
$$;

create or replace function private.my_advisor_ids()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select ac.advisor_id
  from public.advisor_clients ac
  where ac.user_id = (select auth.uid());
$$;

-- ---------------------------------------------------------------------
-- 8. Signup: Profil anlegen & Standardkategorien seeden
-- ---------------------------------------------------------------------
create or replace function private.seed_default_categories(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.categories (user_id, name, kind, color, icon, is_default, sort_order)
  values
    (p_user_id, 'Gehalt & Lohn',        'income',   '#16a34a', 'banknote',         true,  10),
    (p_user_id, 'Kapitalerträge',       'income',   '#15803d', 'trending-up',      true,  20),
    (p_user_id, 'Mieteinnahmen',        'income',   '#166534', 'building-2',       true,  30),
    (p_user_id, 'Sonstige Einnahmen',   'income',   '#4ade80', 'circle-plus',      true,  40),
    (p_user_id, 'Wohnen',               'expense',  '#2563eb', 'house',            true, 100),
    (p_user_id, 'Lebensmittel',         'expense',  '#f59e0b', 'shopping-cart',    true, 110),
    (p_user_id, 'Mobilität',            'expense',  '#0ea5e9', 'car',              true, 120),
    (p_user_id, 'Versicherungen',       'expense',  '#6366f1', 'shield',           true, 130),
    (p_user_id, 'Gesundheit',           'expense',  '#ef4444', 'heart-pulse',      true, 140),
    (p_user_id, 'Freizeit & Reisen',    'expense',  '#ec4899', 'plane',            true, 150),
    (p_user_id, 'Abos & Medien',        'expense',  '#a855f7', 'tv',               true, 160),
    (p_user_id, 'Shopping',             'expense',  '#f97316', 'shopping-bag',     true, 170),
    (p_user_id, 'Bildung',              'expense',  '#14b8a6', 'graduation-cap',   true, 180),
    (p_user_id, 'Steuern & Abgaben',    'expense',  '#64748b', 'landmark',         true, 190),
    (p_user_id, 'Sonstige Ausgaben',    'expense',  '#94a3b8', 'ellipsis',         true, 200),
    (p_user_id, 'Sparen & Investieren', 'transfer', '#0f766e', 'piggy-bank',       true, 300),
    (p_user_id, 'Kredittilgung',        'transfer', '#475569', 'receipt',          true, 310),
    (p_user_id, 'Umbuchung',            'transfer', '#9ca3af', 'arrow-left-right', true, 320)
  on conflict on constraint categories_name_key do nothing;
end;
$$;

-- Die Rolle wird bewusst NICHT aus raw_user_meta_data übernommen: diese Daten
-- kontrolliert der Nutzer beim Signup selbst. Berater werden ausschließlich per
-- service_role hochgestuft.
create or replace function private.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (user_id, first_name, last_name)
  values (
    new.id,
    nullif(left(trim(new.raw_user_meta_data ->> 'first_name'), 100), ''),
    nullif(left(trim(new.raw_user_meta_data ->> 'last_name'), 100), '')
  );

  perform private.seed_default_categories(new.id);
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function private.handle_new_user();

-- ---------------------------------------------------------------------
-- 9. RPC: Berater-Einladung annehmen
-- ---------------------------------------------------------------------
-- Aufruf im Client: supabase.rpc('accept_advisor_invitation', { p_token })
-- Bedingungen: Token gültig & nicht abgelaufen, bestätigte E-Mail des
-- eingeloggten Nutzers entspricht invited_email.
create or replace function public.accept_advisor_invitation(p_token text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid     uuid := (select auth.uid());
  v_email   text;
  v_link_id uuid;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;

  if p_token is null or char_length(p_token) < 32 then
    raise exception 'invalid_or_expired_invitation' using errcode = 'P0001';
  end if;

  select lower(u.email)
    into v_email
  from auth.users u
  where u.id = v_uid
    and u.email_confirmed_at is not null;

  if v_email is null then
    raise exception 'email_not_confirmed' using errcode = '42501';
  end if;

  update public.advisor_clients ac
     set user_id           = v_uid,
         status            = 'active',
         accepted_at       = now(),
         invite_token_hash = null,
         invite_expires_at = null
   where ac.invite_token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex')
     and ac.status = 'invited'
     and ac.invite_expires_at > now()
     and ac.invited_email = v_email
     and ac.advisor_id <> v_uid
  returning ac.id into v_link_id;

  if v_link_id is null then
    raise exception 'invalid_or_expired_invitation' using errcode = 'P0001';
  end if;

  return v_link_id;
end;
$$;

-- ---------------------------------------------------------------------
-- 10. Row Level Security
-- ---------------------------------------------------------------------
alter table public.profiles            enable row level security;
alter table public.advisor_clients     enable row level security;
alter table public.accounts            enable row level security;
alter table public.categories          enable row level security;
alter table public.transactions        enable row level security;
alter table public.portfolios          enable row level security;
alter table public.assets              enable row level security;
alter table public.real_estate_objects enable row level security;

-- SELECT kombiniert Owner- und Berater-Zugriff in EINER permissiven Policy
-- (vermeidet den Supabase-Linter-Befund "multiple_permissive_policies").

-- 10.1 profiles
-- Sichtbar: eigenes Profil, Profile aktiver Mandanten (Berater),
-- Profile der eigenen Berater (Mandant).
create policy profiles_select_owner_or_linked on public.profiles
  for select to authenticated
  using (
    (select auth.uid()) = user_id
    or user_id in (select private.advisor_client_ids())
    or user_id in (select private.my_advisor_ids())
  );

create policy profiles_insert_owner on public.profiles
  for insert to authenticated
  with check ((select auth.uid()) = user_id);

create policy profiles_update_owner on public.profiles
  for update to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

create policy profiles_delete_owner on public.profiles
  for delete to authenticated
  using ((select auth.uid()) = user_id);

-- 10.2 advisor_clients
-- Mandant (user_id) und Berater (advisor_id) sehen die Verknüpfung.
-- INSERT nur durch Berater als offene Einladung; Aktivierung nur via RPC.
create policy advisor_clients_select_participant on public.advisor_clients
  for select to authenticated
  using (
    (select auth.uid()) = user_id
    or (select auth.uid()) = advisor_id
  );

create policy advisor_clients_insert_advisor_invite on public.advisor_clients
  for insert to authenticated
  with check (
    (select auth.uid()) = advisor_id
    and (select private.is_advisor())
    and status = 'invited'
    and user_id is null
  );

create policy advisor_clients_update_participant on public.advisor_clients
  for update to authenticated
  using (
    (select auth.uid()) = user_id
    or (select auth.uid()) = advisor_id
  )
  with check (
    (select auth.uid()) = user_id
    or (select auth.uid()) = advisor_id
  );

create policy advisor_clients_delete_participant on public.advisor_clients
  for delete to authenticated
  using (
    (select auth.uid()) = user_id
    or (select auth.uid()) = advisor_id
  );

-- 10.3 accounts
create policy accounts_select_owner_or_advisor on public.accounts
  for select to authenticated
  using (
    (select auth.uid()) = user_id
    or user_id in (select private.advisor_client_ids())
  );

create policy accounts_insert_owner on public.accounts
  for insert to authenticated
  with check ((select auth.uid()) = user_id);

create policy accounts_update_owner on public.accounts
  for update to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

create policy accounts_delete_owner on public.accounts
  for delete to authenticated
  using ((select auth.uid()) = user_id);

-- 10.4 categories
create policy categories_select_owner_or_advisor on public.categories
  for select to authenticated
  using (
    (select auth.uid()) = user_id
    or user_id in (select private.advisor_client_ids())
  );

create policy categories_insert_owner on public.categories
  for insert to authenticated
  with check ((select auth.uid()) = user_id);

create policy categories_update_owner on public.categories
  for update to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

create policy categories_delete_owner on public.categories
  for delete to authenticated
  using ((select auth.uid()) = user_id);

-- 10.5 transactions
create policy transactions_select_owner_or_advisor on public.transactions
  for select to authenticated
  using (
    (select auth.uid()) = user_id
    or user_id in (select private.advisor_client_ids())
  );

create policy transactions_insert_owner on public.transactions
  for insert to authenticated
  with check ((select auth.uid()) = user_id);

create policy transactions_update_owner on public.transactions
  for update to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

create policy transactions_delete_owner on public.transactions
  for delete to authenticated
  using ((select auth.uid()) = user_id);

-- 10.6 portfolios
create policy portfolios_select_owner_or_advisor on public.portfolios
  for select to authenticated
  using (
    (select auth.uid()) = user_id
    or user_id in (select private.advisor_client_ids())
  );

create policy portfolios_insert_owner on public.portfolios
  for insert to authenticated
  with check ((select auth.uid()) = user_id);

create policy portfolios_update_owner on public.portfolios
  for update to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

create policy portfolios_delete_owner on public.portfolios
  for delete to authenticated
  using ((select auth.uid()) = user_id);

-- 10.7 assets
create policy assets_select_owner_or_advisor on public.assets
  for select to authenticated
  using (
    (select auth.uid()) = user_id
    or user_id in (select private.advisor_client_ids())
  );

create policy assets_insert_owner on public.assets
  for insert to authenticated
  with check ((select auth.uid()) = user_id);

create policy assets_update_owner on public.assets
  for update to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

create policy assets_delete_owner on public.assets
  for delete to authenticated
  using ((select auth.uid()) = user_id);

-- 10.8 real_estate_objects
create policy real_estate_objects_select_owner_or_advisor on public.real_estate_objects
  for select to authenticated
  using (
    (select auth.uid()) = user_id
    or user_id in (select private.advisor_client_ids())
  );

create policy real_estate_objects_insert_owner on public.real_estate_objects
  for insert to authenticated
  with check ((select auth.uid()) = user_id);

create policy real_estate_objects_update_owner on public.real_estate_objects
  for update to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

create policy real_estate_objects_delete_owner on public.real_estate_objects
  for delete to authenticated
  using ((select auth.uid()) = user_id);

-- ---------------------------------------------------------------------
-- 11. Privilegien (Defense in Depth zusätzlich zu RLS)
-- ---------------------------------------------------------------------
-- anon hat auf keine Tabelle Zugriff; auch künftige Tabellen nicht.
revoke all on
  public.profiles, public.advisor_clients, public.accounts, public.categories,
  public.transactions, public.portfolios, public.assets, public.real_estate_objects
from anon, authenticated;

alter default privileges in schema public revoke all on tables from anon;

-- Datentabellen: volle CRUD-Rechte, Einschränkung erfolgt über RLS.
grant select, insert, update, delete on
  public.accounts, public.categories, public.transactions,
  public.portfolios, public.assets, public.real_estate_objects
to authenticated;

-- profiles: role ist weder beim INSERT noch beim UPDATE beschreibbar.
grant select, delete on public.profiles to authenticated;
grant insert (user_id, first_name, last_name, locale, base_currency, onboarding_completed_at)
  on public.profiles to authenticated;
grant update (first_name, last_name, locale, base_currency, onboarding_completed_at)
  on public.profiles to authenticated;

-- advisor_clients: Einladung anlegen, Status (nur → revoked, s. Trigger) ändern.
grant select, delete on public.advisor_clients to authenticated;
grant insert (advisor_id, invited_email, invite_token_hash, invite_expires_at)
  on public.advisor_clients to authenticated;
grant update (status) on public.advisor_clients to authenticated;

-- Funktionen: standardmäßig kein EXECUTE; nur die in Policies benötigten Helper.
revoke all on all functions in schema private from public, anon, authenticated;
grant execute on function private.is_advisor()         to authenticated;
grant execute on function private.advisor_client_ids() to authenticated;
grant execute on function private.my_advisor_ids()     to authenticated;

revoke all on function public.accept_advisor_invitation(text) from public, anon;
grant execute on function public.accept_advisor_invitation(text) to authenticated;

commit;
