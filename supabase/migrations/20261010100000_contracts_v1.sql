-- =====================================================================
--  20261010100000_contracts_v1.sql
--
--  Verträge, Schritt V1: Erkennung, Vorschlagsliste, manuelle Verträge.
--
--  Erkennung (private.refresh_contracts) aus den Ausgaben eines Nutzers:
--    – Serie = gleiche Gegenpartei (transactions.counterparty_key, bei
--      Zahlungsvermittlern der Händler aus dem Zweck), gleiche Währung,
--      Betrag bis +20 % über dem kleinsten, regelmäßiger Abstand (mindestens
--      75 % der Abstände im Band des Rhythmus). Mindestens 3 Buchungen; bei
--      halbjährlich/jährlich genügen 2 (geringere Sicherheit).
--    – Rhythmen: wöchentlich, 14-tägig, monatlich, zweimonatlich,
--      quartalsweise, halbjährlich, jährlich (14-tägig = weekly ×2,
--      zweimonatlich = monthly ×2 über interval_count).
--    – Fortsetzung: Teilserien derselben Gegenpartei mit gleichem Rhythmus,
--      die zeitlich aufeinander folgen und im Betrag höchstens 50 %
--      auseinanderliegen, sind ein Vertrag (Preisänderung, Hinweis in V2).
--      Zeitlich parallele Serien bleiben getrennte Verträge.
--    – Nicht vorgeschlagen: Umbuchungen (Kategorie transfer), Überweisungen
--      an eigene Konten (IBAN- oder Namensregel), Einnahmen, beendete
--      Serien (seit über zwei Perioden keine Abbuchung, gemessen an der
--      letzten Buchung der betroffenen Konten).
--    – Bestehende Verträge: Serie mit schon verknüpften Buchungen gehört
--      zu diesem Vertrag; sonst Fortsetzung eines Vertrags mit gleicher
--      Gegenpartei und gleichem Rhythmus bis ±50 %. Verworfene Vorschläge
--      unterdrücken Serien derselben Buchungen und – ohne gemeinsame
--      Buchungen – Serien gleicher Gegenpartei/Rhythmus bis ±20 %.
--  Verknüpfen: Buchungen gleicher Gegenpartei innerhalb der Toleranz des
--  Vertrags (Standard 10 %) über alle Konten; manuell gelöste oder
--  verknüpfte Buchungen (contract_link_manual) fasst die Automatik nicht an.
--
--  Später (nicht in V1): Versicherungsdetails (Sparte, Versicherer,
--  Vertragsnummer, Hauptfälligkeit) als 1:1-Tabelle mit zusammengesetztem
--  Fremdschlüssel (contract_id, user_id) → recurring_contracts bleibt dafür
--  unverändert.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- Vertragstyp, Gegenpartei-Schlüssel, manuelle Verknüpfung
-- ---------------------------------------------------------------------
create type public.contract_type as enum (
  'subscription', 'telecom', 'energy', 'insurance', 'housing',
  'loan', 'membership', 'public_fee', 'savings', 'other'
);

alter table public.recurring_contracts
  add column contract_type public.contract_type not null default 'other',
  add column counterparty_key text check (char_length(counterparty_key) <= 300);

comment on column public.recurring_contracts.contract_type is
  'Vertragstyp (Abo, Mobilfunk/Internet, Energie, Versicherung, Wohnen, Kredit, Mitgliedschaft, Gebühren, Sparplan, Sonstiges).';
comment on column public.recurring_contracts.counterparty_key is
  'Gegenpartei wie transactions.counterparty_key: verknüpft Buchungen und erkennt Serien.';

create index recurring_contracts_user_key_idx
  on public.recurring_contracts (user_id, counterparty_key) where counterparty_key is not null;

alter table public.transactions
  add column contract_link_manual boolean not null default false;

comment on column public.transactions.contract_link_manual is
  'Vertragsverknüpfung vom Nutzer gesetzt oder gelöst – die automatische Verknüpfung ändert sie nicht.';

-- ---------------------------------------------------------------------
-- Rhythmen
-- ---------------------------------------------------------------------
-- Bänder der Abstände in Tagen je Rhythmus (für Serien und Verträge).
create or replace function private.rhythm_bands()
returns table (rhythm_key text, rhythm public.contract_rhythm, interval_count integer, low integer, high integer)
language sql
immutable
parallel safe
set search_path = ''
as $$
  select b.rhythm_key, b.rhythm::public.contract_rhythm, b.interval_count, b.low, b.high
    from (values ('weekly',     'weekly',     1,   5,   9),
                 ('biweekly',   'weekly',     2,  12,  16),
                 ('monthly',    'monthly',    1,  25,  36),
                 ('bimonthly',  'monthly',    2,  55,  66),
                 ('quarterly',  'quarterly',  1,  80, 100),
                 ('semiannual', 'semiannual', 1, 170, 195),
                 ('yearly',     'yearly',     1, 350, 380)) as b (rhythm_key, rhythm, interval_count, low, high);
$$;

comment on function private.rhythm_bands() is
  'Rhythmen mit Band der Abstände in Tagen; 14-tägig = weekly ×2, zweimonatlich = monthly ×2.';

-- Abstand einer Periode.
create or replace function private.contract_period(p_rhythm public.contract_rhythm, p_interval_count integer)
returns interval
language sql
immutable
parallel safe
set search_path = ''
as $$
  select case p_rhythm
           when 'weekly'     then make_interval(days => 7 * p_interval_count)
           when 'monthly'    then make_interval(months => p_interval_count)
           when 'quarterly'  then make_interval(months => 3 * p_interval_count)
           when 'semiannual' then make_interval(months => 6 * p_interval_count)
           when 'yearly'     then make_interval(years => p_interval_count)
         end;
$$;

-- Rhythmus einer Datumsreihe: Median der Abstände (gleiche Tage zählen
-- nicht) im Band; share = Anteil der Abstände im Band. Keine Zeile, wenn
-- der Median in keinem Band liegt oder es weniger als zwei Tage gibt.
create or replace function private.series_rhythm(p_dates date[])
returns table (rhythm_key text, rhythm public.contract_rhythm, interval_count integer,
               low integer, high integer, share numeric, intervals integer)
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_dates     date[] := array(select distinct x from unnest(p_dates) x where x is not null order by x);
  v_intervals integer[];
  v_median    integer;
begin
  if cardinality(v_dates) < 2 then
    return;
  end if;
  v_intervals := array(select v_dates[k + 1] - v_dates[k] from generate_series(1, cardinality(v_dates) - 1) k);
  select percentile_disc(0.5) within group (order by x) into v_median from unnest(v_intervals) x;
  return query
    select b.rhythm_key, b.rhythm, b.interval_count, b.low, b.high,
           (select count(*) from unnest(v_intervals) x where x between b.low and b.high)::numeric
             / cardinality(v_intervals),
           cardinality(v_intervals)
      from private.rhythm_bands() b
     where v_median between b.low and b.high;
end;
$$;

comment on function private.series_rhythm(date[]) is
  'Rhythmus einer Datumsreihe (Median der Abstände im Band) mit Anteil regelmäßiger Abstände.';

-- ---------------------------------------------------------------------
-- B1: wiederkehrende Buchungen kennen die neuen Rhythmen
-- ---------------------------------------------------------------------
alter table public.transactions drop constraint transactions_recurrence_check;
alter table public.transactions add constraint transactions_recurrence_check
  check (recurrence in ('weekly', 'biweekly', 'monthly', 'bimonthly', 'quarterly', 'semiannual', 'yearly'));

comment on column public.transactions.recurrence is
  'Wiederkehrend (gleiche Gegenpartei, ähnlicher Betrag, regelmäßiger Abstand): weekly, biweekly, monthly, '
  'bimonthly, quarterly, semiannual, yearly.';

create or replace function private.mark_recurring_series(p_ids uuid[])
returns integer
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_key       text;
  v_share     numeric;
  v_intervals integer;
begin
  if cardinality(p_ids) < 3 then
    return 0;
  end if;
  select r.rhythm_key, r.share, r.intervals into v_key, v_share, v_intervals
    from private.series_rhythm(array(select t.booking_date from public.transactions t where t.id = any (p_ids))) r;
  if v_key is null or v_intervals < 2 or v_share < 0.75 then
    return 0;
  end if;
  update public.transactions t set recurrence = v_key where t.id = any (p_ids);
  return cardinality(p_ids);
end;
$$;

-- ---------------------------------------------------------------------
-- Vertragstyp raten (nur für neue Vorschläge; änderbar)
-- ---------------------------------------------------------------------
create or replace function private.guess_contract_type(p_text text, p_category_key text)
returns public.contract_type
language sql
immutable
parallel safe
set search_path = ''
as $$
  with v as (select coalesce(private.normalize_booking_text(p_text), '') as t)
  select case
    when v.t ~ '\m(versicherung\w*|versicherer|allianz|huk|ergo|axa|generali|debeka|signal iduna|devk|lvm|provinzial|barmenia|gothaer|hdi|zurich|wwk|cosmosdirekt|hansemerkur|arag|wgv|vhv|haftpflicht|hausrat)\M'
      then 'insurance'
    when v.t ~ '\m(telekom|vodafone|o2|telefonica|congstar|freenet|drillisch|1&1|1und1|unitymedia|netcologne|m-net|klarmobil|mobilfunk|dsl|glasfaser)\M'
      then 'telecom'
    when v.t ~ '\m(stadtwerke|swm|e\.?on|vattenfall|enbw|rwe|entega|naturstrom|lichtblick|yello|eprimo|tibber|ostrom|polarstern|strom|gas|energie|fernwaerme)\M'
      then 'energy'
    when v.t ~ '\m(beitragsservice|rundfunk\w*|finanzamt|bundeskasse|stadtkasse|gemeindekasse|kfz-steuer|hundesteuer)\M'
      then 'public_fee'
    when v.t ~ '\m(fitness\w*|mcfit|urban sports|clever fit|john reed|fitx|easyfit|gym|sportverein|mitgliedsbeitrag|adac|gewerkschaft)\M'
      then 'membership'
    when v.t ~ '\m(netflix|spotify|disney|dazn|sky|audible|youtube|icloud|amazon prime|prime video|apple|zeit|spiegel|faz|sueddeutsche|abo|abonnement|microsoft|adobe|dropbox|openai|chatgpt|patreon|readly|kindle)\M'
      then 'subscription'
    when v.t ~ '\m(miete|mietzahlung|hausverwaltung|wohnungsbau\w*|vonovia|nebenkosten|hausgeld)\M'
      then 'housing'
    when v.t ~ '\m(kredit|darlehen|leasing|finanzierung|ratenkauf|tilgung)\M'
      then 'loan'
    when v.t ~ '\m(sparplan|bausparkasse|bausparvertrag|schwaebisch hall|wuestenrot|trade republic|scalable)\M'
      then 'savings'
    else case p_category_key
           when 'insurance'           then 'insurance'
           when 'subscriptions_media' then 'subscription'
           when 'housing'             then 'housing'
           when 'loan_repayment'      then 'loan'
           when 'savings_investments' then 'savings'
           when 'taxes'               then 'public_fee'
           else 'other'
         end
  end::public.contract_type
  from v;
$$;

comment on function private.guess_contract_type(text, text) is
  'Vertragstyp aus Name/Gegenpartei/Zweck (Marken, ganze Wörter), sonst aus der Kategorie; Standard other.';

-- ---------------------------------------------------------------------
-- Verknüpfen und Daten nachführen
-- ---------------------------------------------------------------------
-- Buchungen gleicher Gegenpartei und Währung innerhalb der Toleranz an
-- bestätigte Verträge hängen (über alle Konten). Bestätigte Verträge
-- gehen Vorschlägen und verworfenen vor; bei mehreren passt der mit dem
-- nächsten Betrag. Liefert die Anzahl neu verknüpfter Buchungen.
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
       and t.amount < 0
       and not t.contract_link_manual
       and (t.recurring_contract_id is null or cur.status in ('suggested', 'dismissed'))
       and rc.status in ('active', 'cancellation_pending', 'cancelled')
       and rc.expected_amount is not null
       and abs(abs(t.amount) - abs(rc.expected_amount)) <= abs(rc.expected_amount) * rc.amount_tolerance_pct / 100
     order by t.id, abs(abs(t.amount) - abs(rc.expected_amount)), rc.created_at, rc.id
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

-- Erste/letzte Abbuchung aus den verknüpften Buchungen; die nächste
-- erwartete rückt nach, sobald die erwartete Abbuchung eingegangen ist
-- (bei Vorschlägen immer letzte + Periode). Manuell eingetragene spätere
-- Termine bleiben.
create or replace function private.update_contract_dates(p_user_id uuid)
returns void
language plpgsql
volatile
set search_path = ''
as $$
begin
  with agg as (
    select t.recurring_contract_id as id, min(t.booking_date) as first_date, max(t.booking_date) as last_date
      from public.transactions t
     where t.user_id = p_user_id and t.recurring_contract_id is not null
     group by 1
  )
  update public.recurring_contracts rc
     set first_booking_date = agg.first_date,
         last_booking_date  = agg.last_date,
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
          or rc.next_expected_date is null
          or (rc.status = 'suggested'
              and rc.next_expected_date is distinct from
                  (agg.last_date + private.contract_period(rc.rhythm, rc.interval_count))::date));

  -- Ohne verknüpfte Buchungen: keine erste/letzte Abbuchung.
  update public.recurring_contracts rc
     set first_booking_date = null, last_booking_date = null
   where rc.user_id = p_user_id
     and rc.last_booking_date is not null
     and not exists (select 1 from public.transactions t
                      where t.user_id = p_user_id and t.recurring_contract_id = rc.id);
end;
$$;

-- ---------------------------------------------------------------------
-- Erkennung
-- ---------------------------------------------------------------------
-- Sicherheit der Erkennung: zwei Abbuchungen 0,5 × Anteil; 3–5 Tage
-- 0,8 × Anteil; ab 6 der Anteil regelmäßiger Abstände.
create or replace function private.series_confidence(p_dates integer, p_share numeric)
returns numeric
language sql
immutable
parallel safe
set search_path = ''
as $$
  select round(least(1, greatest(0, coalesce(p_share, 0)
               * case when p_dates <= 2 then 0.5 when p_dates <= 5 then 0.8 else 1 end)), 2);
$$;

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
         cov.coverage
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
  analyze pg_temp.contract_tx;

  if to_regclass('pg_temp.contract_series') is not null then
    drop table pg_temp.contract_series;
  end if;
  create temporary table contract_series (
    no             integer primary key,
    key            text,
    currency       text,
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

  -- 3. Je Gegenpartei und Währung nach Betrag bündeln (bis +20 % über dem
  --    kleinsten der Gruppe).
  for v_tx in
    select x.id, x.key, x.currency, x.amt
      from pg_temp.contract_tx x
     order by x.key, x.currency, x.amt, x.d, x.id
  loop
    if v_key is distinct from v_tx.key or v_currency is distinct from v_tx.currency or v_tx.amt > v_start * 1.2 then
      if cardinality(v_ids) > 0 then
        v_no := v_no + 1;
        insert into pg_temp.contract_series (no, key, currency, ids) values (v_no, v_key, v_currency, v_ids);
      end if;
      v_ids := '{}';
      v_key := v_tx.key;
      v_currency := v_tx.currency;
      v_start := v_tx.amt;
    end if;
    v_ids := v_ids || v_tx.id;
  end loop;
  if cardinality(v_ids) > 0 then
    v_no := v_no + 1;
    insert into pg_temp.contract_series (no, key, currency, ids) values (v_no, v_key, v_currency, v_ids);
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
  'Verknüpft Buchungen mit bestätigten Verträgen, erkennt Serien (Vorschläge anlegen/aktualisieren, '
  'verworfene unterdrücken, verwaiste entfernen) und führt die Daten nach. Liefert {created, removed, linked}.';

-- ---------------------------------------------------------------------
-- Schnittstelle
-- ---------------------------------------------------------------------
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
  return private.refresh_contracts(auth.uid());
end;
$$;

comment on function public.refresh_contracts() is
  'Erkennt Verträge des angemeldeten Nutzers neu und verknüpft Buchungen. Liefert {created, removed, linked}.';

-- Gegenparteien der eigenen Ausgaben (für das Formular), häufigste zuerst.
create or replace function public.contract_counterparties(p_limit integer default 300)
returns table (counterparty_key text, label text, tx_count integer, last_amount numeric, last_date date)
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
         max(t.booking_date)
    from public.transactions t
   where t.user_id = auth.uid()
     and t.amount < 0
     and t.counterparty_key is not null
   group by t.counterparty_key
   order by count(*) desc, 2
   limit least(greatest(coalesce(p_limit, 300), 1), 1000);
$$;

-- Vertrag anlegen (p_id null) oder ändern. p_amount ist der Betrag der
-- Abbuchung (positiv). Ohne p_counterparty_key wird der Schlüssel aus
-- p_counterparty_name gebildet. Danach werden Buchungen verknüpft.
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

  perform private.refresh_contracts(v_uid);
  return v_id;
end;
$$;

comment on function public.save_contract(uuid, text, text, text, public.contract_rhythm, integer, numeric, date,
                                         public.contract_type, uuid, uuid, text, numeric) is
  'Vertrag anlegen (p_id null, Status active, manuell) oder ändern (nicht bei Vorschlägen/verworfenen). '
  'Fehler: invalid_name, invalid_counterparty, invalid_rhythm, invalid_amount, invalid_tolerance, '
  'invalid_notes, contract_not_editable (22023), account_not_found, category_not_found, contract_not_found (P0002).';

-- Status wechseln: Vorschlag bestätigen (optional mit Typ) oder verwerfen,
-- erkannten Vertrag verwerfen, Verworfenen wiederherstellen (als Vorschlag).
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
  perform private.refresh_contracts(v_uid);
end;
$$;

comment on function public.set_contract_status(uuid, public.contract_status, public.contract_type) is
  'Statuswechsel: suggested → active/dismissed, active → dismissed (nur erkannte), dismissed → suggested. '
  'Fehler: contract_not_found (P0002), invalid_transition (22023).';

-- Manuell angelegten Vertrag löschen (erkannte werden verworfen, damit sie
-- nicht wieder vorgeschlagen werden).
create or replace function public.delete_contract(p_id uuid)
returns void
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_uid    uuid := auth.uid();
  v_source public.contract_detection;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  select rc.detection_source into v_source
    from public.recurring_contracts rc where rc.id = p_id and rc.user_id = v_uid;
  if not found then
    raise exception 'contract_not_found' using errcode = 'P0002';
  end if;
  if v_source <> 'manual' then
    raise exception 'contract_not_deletable' using errcode = '22023';
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
  'Löscht einen manuell angelegten Vertrag (Buchungen werden gelöst und wieder automatisch verknüpfbar). '
  'Fehler: contract_not_found (P0002), contract_not_deletable (22023, erkannte Verträge verwerfen).';

-- Buchung manuell verknüpfen (p_contract_id) oder lösen (null). Die
-- Automatik ändert diese Buchung danach nicht mehr.
create or replace function public.set_contract_link(p_transaction_id uuid, p_contract_id uuid)
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
  if p_contract_id is not null and not exists (
    select 1 from public.recurring_contracts rc
     where rc.id = p_contract_id and rc.user_id = v_uid and rc.status <> 'dismissed'
  ) then
    raise exception 'contract_not_found' using errcode = 'P0002';
  end if;
  update public.transactions t
     set recurring_contract_id = p_contract_id, contract_link_manual = true
   where t.id = p_transaction_id and t.user_id = v_uid;
  if not found then
    raise exception 'transaction_not_found' using errcode = 'P0002';
  end if;
  perform private.update_contract_dates(v_uid);
end;
$$;

comment on function public.set_contract_link(uuid, uuid) is
  'Buchung manuell mit einem eigenen Vertrag verknüpfen oder (p_contract_id null) lösen; bleibt so. '
  'Fehler: contract_not_found, transaction_not_found (P0002).';

-- ---------------------------------------------------------------------
-- Bestand: wiederkehrende Buchungen mit den neuen Rhythmen
-- ---------------------------------------------------------------------
do $$
declare
  v_user uuid;
begin
  for v_user in select distinct t.user_id from public.transactions t loop
    perform private.refresh_recurrence(v_user);
  end loop;
end;
$$;

-- ---------------------------------------------------------------------
-- Rechte
-- ---------------------------------------------------------------------
grant execute on function private.rhythm_bands()                                to authenticated;
grant execute on function private.contract_period(public.contract_rhythm, integer) to authenticated;
grant execute on function private.series_rhythm(date[])                         to authenticated;
grant execute on function private.series_confidence(integer, numeric)           to authenticated;
grant execute on function private.guess_contract_type(text, text)               to authenticated;
grant execute on function private.link_contract_bookings(uuid)                  to authenticated;
grant execute on function private.update_contract_dates(uuid)                   to authenticated;
grant execute on function private.refresh_contracts(uuid)                       to authenticated;

revoke all on function public.refresh_contracts()                               from public, anon;
revoke all on function public.contract_counterparties(integer)                  from public, anon;
revoke all on function public.save_contract(uuid, text, text, text, public.contract_rhythm, integer, numeric, date,
                                            public.contract_type, uuid, uuid, text, numeric) from public, anon;
revoke all on function public.set_contract_status(uuid, public.contract_status, public.contract_type) from public, anon;
revoke all on function public.delete_contract(uuid)                             from public, anon;
revoke all on function public.set_contract_link(uuid, uuid)                     from public, anon;

grant execute on function public.refresh_contracts()                            to authenticated;
grant execute on function public.contract_counterparties(integer)               to authenticated;
grant execute on function public.save_contract(uuid, text, text, text, public.contract_rhythm, integer, numeric, date,
                                               public.contract_type, uuid, uuid, text, numeric) to authenticated;
grant execute on function public.set_contract_status(uuid, public.contract_status, public.contract_type) to authenticated;
grant execute on function public.delete_contract(uuid)                          to authenticated;
grant execute on function public.set_contract_link(uuid, uuid)                  to authenticated;

commit;
