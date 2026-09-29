-- =====================================================================
--  20261002160000_account_foreign_currency_totals.sql
--
--  Buchungen in einer anderen Währung als der Kontowährung zählen nicht
--  zum berechneten Saldo (20261002140000, keine Umrechnung). Die App weist
--  sie getrennt aus („zzgl. 120,00 CHF nicht im Saldo“).
--
--  public.account_foreign_currency_totals(p_user_id): je Konto und
--  Fremdwährung die Summe dieser Buchungen. Nur manuelle und CSV-Konten
--  (bei synchronisierten Konten liefert die Bank den Saldo). Summen von 0
--  entfallen.
--
--  SECURITY INVOKER – RLS gilt: Nutzer sehen eigene Konten, Berater die
--  ihrer aktiven Mandanten.
-- =====================================================================

begin;

create or replace function public.account_foreign_currency_totals(p_user_id uuid)
returns table (
  account_id uuid,
  currency   text,
  total      numeric
)
language sql
stable
security invoker
set search_path = ''
as $$
  select t.account_id, t.currency::text, sum(t.amount)
    from public.transactions t
    join public.accounts a
      on a.id = t.account_id
     and a.user_id = t.user_id
   where t.user_id = p_user_id
     and a.provider in ('manual', 'csv')
     and t.currency <> a.currency
   group by t.account_id, t.currency
  having sum(t.amount) <> 0
   order by t.account_id, t.currency;
$$;

comment on function public.account_foreign_currency_totals(uuid) is
  'Summe der Buchungen je Konto in Fremdwährung (nicht im berechneten Saldo). '
  'Nur manual/csv-Konten; SECURITY INVOKER, RLS aktiv.';

revoke all on function public.account_foreign_currency_totals(uuid) from public, anon;
grant execute on function public.account_foreign_currency_totals(uuid) to authenticated;

commit;
