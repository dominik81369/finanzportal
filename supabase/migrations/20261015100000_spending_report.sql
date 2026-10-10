-- =====================================================================
--  20261015100000_spending_report.sql
--  Ausgaben-Dashboard: eine Auswertungsfunktion für Kopfzahlen, Verlauf,
--  Kategorien, Hinweise, Top-Gegenparteien und größte Buchungen.
--
--  Einordnung jeder Buchung (nicht „vom Budget ausgenommen“):
--    saved    – Kategorie „Sparen & Investieren“ oder „Kredittilgung“
--               (auch Unterkategorien): Gespart/getilgt, eigene Kopfzahl.
--    transfer – Gegenkonto ist ein erfasstes eigenes Konto (IBAN-Regel der
--               Erkennung eigener Konten): Umbuchung, zählt nirgends. Nur
--               die IBAN entscheidet, nicht die Kategorie „Umbuchung“.
--    income   – Einnahmenkategorie (netto, Korrekturen mindern).
--    expense  – Ausgabenkategorie (netto, Erstattungen mindern; credits
--               weist die Erstattungen aus).
--    Ohne Kategorie und andere Kategorien (z. B. „Umbuchung“ ohne eigene
--    IBAN): Abbuchung = expense, Gutschrift = income.
--
--  Hinweise:
--    flagged     – gezählte Buchungen ohne Kategorie oder in den
--                  Sammelkategorien „Sonstige Ausgaben/Einnahmen“.
--    same_holder – gezählte Buchungen an/von einer IBAN, die kein erfasstes
--                  eigenes Konto ist, mit dem eigenen Namen als Gegenpartei
--                  (Namensregel der Erkennung eigener Konten, sonst Vor- und
--                  Nachname aus dem Profil): vermutlich fehlende eigene Konten.
--
--  SECURITY INVOKER: RLS gibt nur eigene Daten und die Daten aktiver
--  Mandanten (Berater, nur lesend) frei.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- Eingeordnete Buchungen eines Zeitraums
-- ---------------------------------------------------------------------
create function private.spending_transactions(p_user_id uuid, p_from date, p_to date)
returns table (
  id                uuid,
  booking_date      date,
  currency          text,
  amount            numeric,
  category_id       uuid,
  class             text,
  flagged           boolean,
  same_holder       boolean,
  counterparty_key  text,
  counterparty_iban text,
  counterparty_name text,
  purpose           text
)
language sql
stable
security invoker
set search_path = ''
as $$
  with own_ibans as (
    select upper(r.pattern) as iban
      from public.categorization_rules r
     where r.user_id = p_user_id
       and r.origin = 'own_account'
       and r.is_active
       and r.match_field = 'counterparty_iban'
  ),
  own_names as (
    select string_to_array(r.pattern, ' ') as words
      from public.categorization_rules r
     where r.user_id = p_user_id
       and r.origin = 'own_account'
       and r.is_active
       and r.match_field = 'counterparty'
    union all
    -- Ohne Namensregel: Vor- und Nachname aus dem Profil (mindestens zwei Wörter).
    select string_to_array(n.name, ' ')
      from (select private.normalize_booking_text(concat_ws(' ', p.first_name, p.last_name)) as name
              from public.profiles p
             where p.user_id = p_user_id) n
     where n.name ~ ' '
       and not exists (select 1 from public.categorization_rules r
                        where r.user_id = p_user_id and r.origin = 'own_account' and r.match_field = 'counterparty')
  ),
  base as (
    select t.id, t.booking_date, t.currency::text as currency, t.amount, t.category_id,
           t.counterparty_key, t.counterparty_iban, t.counterparty_name, t.purpose,
           c.kind,
           array[c.default_key, pc.default_key] as keys,
           coalesce(upper(t.counterparty_iban) in (select o.iban from own_ibans o), false) as own
      from public.transactions t
      left join public.categories c on c.id = t.category_id and c.user_id = t.user_id
      left join public.categories pc on pc.id = c.parent_category_id and pc.user_id = c.user_id
     where t.user_id = p_user_id
       and t.booking_date between p_from and p_to
       and not t.exclude_from_budget
  ),
  classified as (
    select b.*,
           case
             when b.keys && array['savings_investments', 'loan_repayment'] then 'saved'
             when b.own then 'transfer'
             when b.kind = 'income' then 'income'
             when b.kind = 'expense' then 'expense'
             when b.amount < 0 then 'expense'
             else 'income'
           end as class
      from base b
  )
  select x.id, x.booking_date, x.currency, x.amount, x.category_id, x.class,
         x.class in ('expense', 'income')
           and (x.category_id is null or x.keys && array['other_expenses', 'other_income']),
         x.class in ('expense', 'income')
           and x.counterparty_iban is not null
           and exists (
             select 1
               from own_names n
              where cardinality(n.words) >= 2
                and not exists (
                  select 1 from unnest(n.words) w
                   where position(' ' || w || ' ' in ' ' || private.normalize_booking_text(x.counterparty_name) || ' ') = 0
                )
           ),
         x.counterparty_key, x.counterparty_iban, x.counterparty_name, x.purpose
    from classified x;
$$;

comment on function private.spending_transactions(uuid, date, date) is
  'Buchungen eines Zeitraums mit Einordnung (saved, transfer über eigene IBAN, income, expense) und Hinweisen '
  '(flagged: ohne Kategorie/Sammelkategorie; same_holder: fremde IBAN mit eigenem Namen).';

-- ---------------------------------------------------------------------
-- Auswertung
-- ---------------------------------------------------------------------
-- p_bucket: day | week (ab Montag) | month – Teilzeiträume des Verlaufs.
-- p_details: zusätzlich Top-Gegenparteien und größte Buchungen (je Währung
-- höchstens p_limit) – für den Vergleichszeitraum nicht nötig.
create function public.spending_report(
  p_user_id uuid,
  p_from    date,
  p_to      date,
  p_bucket  text,
  p_details boolean default false,
  p_limit   integer default 10
)
returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_limit  integer := least(greatest(coalesce(p_limit, 10), 1), 50);
  v_result jsonb;
begin
  if p_user_id is null or p_from is null or p_to is null or p_from > p_to
     or p_to > (p_from + interval '5 years 3 months') then
    raise exception 'invalid_period' using errcode = '22023';
  end if;
  if p_bucket is null or p_bucket not in ('day', 'week', 'month')
     or (p_bucket = 'day' and p_to > p_from + 400)
     or (p_bucket = 'week' and p_to > p_from + 1000) then
    raise exception 'invalid_bucket' using errcode = '22023';
  end if;

  with tx as materialized (
    select s.*,
           case p_bucket
             when 'day' then s.booking_date
             when 'week' then date_trunc('week', s.booking_date)::date
             else date_trunc('month', s.booking_date)::date
           end as bucket
      from private.spending_transactions(p_user_id, p_from, p_to) s
  ),
  counted as (
    select * from tx where tx.class <> 'transfer'
  )
  select jsonb_build_object(
    'categories', coalesce((
      select jsonb_agg(jsonb_build_object('currency', g.currency, 'category_id', g.category_id, 'class', g.class,
                                          'amount', g.amount, 'credits', g.credits, 'count', g.n)
                       order by g.currency, g.class, g.amount)
        from (select c.currency, c.category_id, c.class, sum(c.amount) as amount,
                     coalesce(sum(c.amount) filter (where c.amount > 0), 0) as credits, count(*) as n
                from counted c group by c.currency, c.category_id, c.class) g), '[]'::jsonb),
    'buckets', coalesce((
      select jsonb_agg(jsonb_build_object('currency', g.currency, 'bucket', g.bucket, 'expenses', g.expenses,
                                          'income', g.income, 'saved', g.saved)
                       order by g.currency, g.bucket)
        from (select c.currency, c.bucket,
                     coalesce(-sum(c.amount) filter (where c.class = 'expense'), 0) as expenses,
                     coalesce(sum(c.amount) filter (where c.class = 'income'), 0) as income,
                     coalesce(-sum(c.amount) filter (where c.class = 'saved'), 0) as saved
                from counted c group by c.currency, c.bucket) g), '[]'::jsonb),
    'flagged', coalesce((
      select jsonb_agg(jsonb_build_object('currency', g.currency, 'count', g.n, 'expenses', g.expenses,
                                          'income', g.income) order by g.currency)
        from (select c.currency, count(*) as n,
                     coalesce(-sum(c.amount) filter (where c.class = 'expense'), 0) as expenses,
                     coalesce(sum(c.amount) filter (where c.class = 'income'), 0) as income
                from counted c where c.flagged group by c.currency) g), '[]'::jsonb),
    'same_holder', coalesce((
      select jsonb_agg(jsonb_build_object('currency', g.currency, 'count', g.n, 'ibans', g.ibans,
                                          'outflow', g.outflow, 'inflow', g.inflow) order by g.currency)
        from (select c.currency, count(*) as n, count(distinct c.counterparty_iban) as ibans,
                     coalesce(-sum(c.amount) filter (where c.amount < 0), 0) as outflow,
                     coalesce(sum(c.amount) filter (where c.amount > 0), 0) as inflow
                from counted c where c.same_holder group by c.currency) g), '[]'::jsonb),
    'transfers', coalesce((
      select jsonb_agg(jsonb_build_object('currency', g.currency, 'count', g.n, 'outflow', g.outflow,
                                          'inflow', g.inflow) order by g.currency)
        from (select t.currency, count(*) as n,
                     coalesce(-sum(t.amount) filter (where t.amount < 0), 0) as outflow,
                     coalesce(sum(t.amount) filter (where t.amount > 0), 0) as inflow
                from tx t where t.class = 'transfer' group by t.currency) g), '[]'::jsonb),
    'counterparties', case when p_details then coalesce((
      select jsonb_agg(jsonb_build_object('currency', g.currency, 'counterparty_key', g.counterparty_key,
                                          'label', g.label, 'count', g.n, 'expenses', g.expenses)
                       order by g.currency, g.expenses desc, g.label)
        from (select r.*, row_number() over (partition by r.currency order by r.expenses desc, r.label) as rank
                from (select c.currency, c.counterparty_key,
                             left(coalesce(case when c.counterparty_key like 'm:%' then initcap(substr(c.counterparty_key, 3)) end,
                                           mode() within group (order by btrim(c.counterparty_name)),
                                           case when c.counterparty_key like 'n:%' then initcap(substr(c.counterparty_key, 3)) end,
                                           mode() within group (order by btrim(c.purpose))), 120) as label,
                             count(*) filter (where c.amount < 0) as n,
                             -sum(c.amount) as expenses
                        from counted c
                       where c.class = 'expense' and c.counterparty_key is not null
                       group by c.currency, c.counterparty_key) r
               where r.expenses > 0) g
       where g.rank <= v_limit), '[]'::jsonb) else '[]'::jsonb end,
    'largest', case when p_details then coalesce((
      select jsonb_agg(jsonb_build_object('currency', g.currency, 'id', g.id, 'booking_date', g.booking_date,
                                          'amount', g.amount, 'counterparty', g.counterparty_name,
                                          'purpose', g.purpose, 'category_id', g.category_id)
                       order by g.currency, g.amount, g.booking_date desc, g.id)
        from (select c.*, row_number() over (partition by c.currency order by c.amount, c.booking_date desc, c.id) as rank
                from counted c
               where c.class = 'expense' and c.amount < 0) g
       where g.rank <= v_limit), '[]'::jsonb) else '[]'::jsonb end
  ) into v_result;

  return v_result;
end;
$$;

comment on function public.spending_report(uuid, date, date, text, boolean, integer) is
  'Ausgaben-Dashboard: Summen je Währung, Kategorie und Einordnung (expense, income, saved), Verlauf je Tag/Woche/'
  'Monat, Hinweise (ohne Kategorie/Sammelkategorie, fremde IBAN mit eigenem Namen), Umbuchungen über eigene IBAN; '
  'mit p_details Top-Gegenparteien und größte Buchungen. Fehler: invalid_period, invalid_bucket (22023).';

-- ---------------------------------------------------------------------
-- Rechte
-- ---------------------------------------------------------------------
revoke all on function private.spending_transactions(uuid, date, date) from public, anon;
grant execute on function private.spending_transactions(uuid, date, date) to authenticated;
revoke all on function public.spending_report(uuid, date, date, text, boolean, integer) from public, anon;
grant execute on function public.spending_report(uuid, date, date, text, boolean, integer) to authenticated;

commit;
