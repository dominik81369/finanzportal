-- =====================================================================
--  20261002140000_account_balance_from_transactions.sql
--
--  Kontostand manueller und CSV-Konten aus den Buchungen berechnen.
--
--  balance = opening_balance + Summe(amount) aller Buchungen des Kontos
--            in KONTOWÄHRUNG
--
--  - opening_balance (neu): Anfangsbestand vor der ersten erfassten Buchung.
--  - Buchungen in anderer Währung (erlaubt seit 20261001000000) zählen
--    NICHT zum Saldo – es gibt keine Umrechnung. Die App weist sie getrennt
--    aus (lib/currency.ts: Währungen nie addieren).
--  - Nur provider 'manual' und 'csv'. Bei synchronisierten Konten
--    (gocardless, enable_banking, plaid) liefert die Bank den Saldo; er
--    bleibt unberührt.
--
--  Die Trigger-Funktionen laufen als SECURITY DEFINER: Die Neuberechnung
--  muss auch gelingen, wenn der Auslöser keine Rechte auf accounts hat
--  (z. B. Kaskaden-Löschung beim Entfernen eines auth-Nutzers). Sie
--  berühren nur Konten der gerade geänderten Buchungen.
--
--  Umsetzung: Statement-Trigger auf transactions berechnen die betroffenen
--  Konten jedes Mal VOLLSTÄNDIG neu (keine inkrementelle Fortschreibung →
--  kein Drift). Ein CSV-Import mit vielen Zeilen rechnet jedes Konto einmal.
--
--  Schutz: balance ist bei manuellen/CSV-Konten nicht direkt schreibbar
--  (Fehler balance_is_calculated, 22023). Änderbar ist opening_balance;
--  das löst die Neuberechnung aus (ebenso ein Wechsel von Währung oder
--  Provider des Kontos).
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. Spalte und einmalige Neuberechnung des Bestands
-- ---------------------------------------------------------------------
alter table public.accounts
  add column opening_balance numeric(14,2) not null default 0;

comment on column public.accounts.opening_balance is
  'Anfangsbestand vor der ersten erfassten Buchung. Bei manuellen und CSV-Konten gilt '
  'balance = opening_balance + Summe der Buchungen in Kontowährung (Trigger).';
comment on column public.accounts.balance is
  'Saldo aus Sicht des Mandanten. manual/csv: berechnet (opening_balance + Buchungen in '
  'Kontowährung, nicht direkt schreibbar); synchronisierte Konten: Saldo der Bank.';

-- Vor Anlage der Trigger: Der Schutz-Trigger würde dieses UPDATE abweisen.
update public.accounts a
   set balance = coalesce((
         select sum(t.amount)
           from public.transactions t
          where t.account_id = a.id
            and t.currency = a.currency
       ), 0),
       balance_updated_at = now()
 where a.provider in ('manual', 'csv');

-- Summe je Konto; Index statt Seq Scan bei jeder Neuberechnung.
create index transactions_account_currency_idx
  on public.transactions (account_id, currency) include (amount);

-- ---------------------------------------------------------------------
-- 2. Schutz und Neuberechnung auf accounts (BEFORE INSERT/UPDATE)
-- ---------------------------------------------------------------------
-- pg_trigger_depth() = 1: Schreibzugriff des Nutzers bzw. der App.
-- > 1: Neuberechnung aus dem transactions-Trigger – erlaubt.
create or replace function private.accounts_balance_guard()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.provider not in ('manual', 'csv') then
    return new;
  end if;

  if tg_op = 'INSERT' then
    -- Ein neues Konto hat noch keine Buchungen: Saldo = Anfangsbestand.
    if new.balance <> 0 and new.balance <> new.opening_balance then
      raise exception 'balance_is_calculated'
        using errcode = '22023',
              hint = 'Set opening_balance instead of balance.';
    end if;
    new.balance := new.opening_balance;
    new.balance_updated_at := now();
    return new;
  end if;

  if pg_trigger_depth() > 1 then
    return new;
  end if;

  if new.balance is distinct from old.balance then
    raise exception 'balance_is_calculated'
      using errcode = '22023',
            hint = 'Set opening_balance instead of balance.';
  end if;

  if new.opening_balance is distinct from old.opening_balance
     or new.currency is distinct from old.currency
     or new.provider is distinct from old.provider then
    new.balance := new.opening_balance + coalesce((
      select sum(t.amount)
        from public.transactions t
       where t.account_id = new.id
         and t.currency = new.currency
    ), 0);
    new.balance_updated_at := now();
  end if;

  return new;
end;
$$;

create trigger accounts_balance_guard
  before insert or update on public.accounts
  for each row execute function private.accounts_balance_guard();

-- ---------------------------------------------------------------------
-- 3. Neuberechnung nach Änderungen an transactions (AFTER, je Anweisung)
-- ---------------------------------------------------------------------
-- Transition Tables erlauben nur ein Ereignis je Trigger → drei Trigger,
-- eine Funktion. UPDATE berücksichtigt nur Zeilen, deren Konto, Betrag
-- oder Währung sich geändert hat (bei Kontowechsel altes UND neues Konto).
--
-- Nebenläufigkeit: Erst die Kontozeilen sperren (feste Reihenfolge gegen
-- Deadlocks), dann summieren. In READ COMMITTED sieht die Summe als neue
-- Anweisung damit auch Buchungen, die eine parallele Transaktion während
-- der Wartezeit committet hat.
create or replace function private.transactions_refresh_account_balances()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_account_ids uuid[];
begin
  if tg_op = 'INSERT' then
    select array_agg(distinct n.account_id) into v_account_ids from new_rows n;
  elsif tg_op = 'DELETE' then
    select array_agg(distinct o.account_id) into v_account_ids from old_rows o;
  else
    select array_agg(distinct changed.account_id) into v_account_ids
      from (
        select n.account_id, o.account_id as old_account_id
          from new_rows n
          join old_rows o using (id)
         where (n.account_id, n.amount, n.currency) is distinct from (o.account_id, o.amount, o.currency)
      ) c
      cross join lateral (values (c.account_id), (c.old_account_id)) as changed (account_id);
  end if;

  if v_account_ids is null then
    return null;
  end if;

  perform 1
     from public.accounts a
    where a.id = any (v_account_ids)
      and a.provider in ('manual', 'csv')
    order by a.id
      for update;

  update public.accounts a
     set balance = a.opening_balance + coalesce((
           select sum(t.amount)
             from public.transactions t
            where t.account_id = a.id
              and t.currency = a.currency
         ), 0),
         balance_updated_at = now()
   where a.id = any (v_account_ids)
     and a.provider in ('manual', 'csv');

  return null;
end;
$$;

create trigger transactions_refresh_balances_insert
  after insert on public.transactions
  referencing new table as new_rows
  for each statement execute function private.transactions_refresh_account_balances();

create trigger transactions_refresh_balances_update
  after update on public.transactions
  referencing old table as old_rows new table as new_rows
  for each statement execute function private.transactions_refresh_account_balances();

create trigger transactions_refresh_balances_delete
  after delete on public.transactions
  referencing old table as old_rows
  for each statement execute function private.transactions_refresh_account_balances();

commit;
