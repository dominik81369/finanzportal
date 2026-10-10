-- =====================================================================
--  20261017100000_pdf_import_speed.sql
--  PDF-Import: Zeitlimit beim Schreiben
--
--  Ursache: public.import_statement() wandte jede neu erfasste eigene IBAN
--  einzeln über private.apply_rules_for_user() an – jedes Mal mit allen
--  Regeln auf ALLE Buchungen des Nutzers. Bei einem Auszug mit sieben
--  Konten und einigen hundert bis tausend Buchungen überschritt das das
--  Zeitlimit der Rolle authenticated (8 s, SQLSTATE 57014); der Probelauf
--  ist davon nicht betroffen.
--
--  Neu: private.apply_own_iban_rules() ordnet nur Buchungen neu zu, deren
--  Gegenkonto eine der neuen IBANs ist – in einer Anweisung, mit denselben
--  Schichten (private.classify) und derselben Regel wie bisher: automatisch
--  zugeordnete oder offene Buchungen, auf die die neue Regel jetzt zuerst
--  passt; manuelle Zuordnungen nie. Ebenso „Eigenes Konto hinzufügen“
--  (IBAN) und „Zielkategorie ändern“ auf der Regeln-Seite.
-- =====================================================================

begin;

create function private.apply_own_iban_rules(p_user_id uuid, p_rule_ids uuid[])
returns integer
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_ibans text[];
  v_count integer;
begin
  select coalesce(array_agg(upper(r.pattern)), '{}') into v_ibans
    from public.categorization_rules r
   where r.user_id = p_user_id and r.id = any (p_rule_ids)
     and r.origin = 'own_account' and r.match_field = 'counterparty_iban';
  if cardinality(v_ibans) = 0 then
    return 0;
  end if;

  update public.transactions t
     set category_id            = c.category_id,
         categorization_source  = c.source,
         categorization_rule_id = c.rule_id,
         auto_category_id       = coalesce(t.auto_category_id, c.category_id),
         auto_source            = case when t.auto_category_id is null then c.source else t.auto_source end,
         auto_rule_id           = case when t.auto_category_id is null then c.rule_id else t.auto_rule_id end
    from public.transactions s
    cross join lateral private.classify(p_user_id, s.account_id, s.amount, s.counterparty_name, s.purpose,
                                        s.description, s.transaction_type, s.counterparty_iban,
                                        s.counterparty_key) c
   where s.id = t.id
     and s.user_id = p_user_id
     and s.counterparty_iban = any (v_ibans)
     and t.user_id = p_user_id
     and (t.category_id is null
          or (t.categorization_source in ('rule', 'learned') and t.category_id is distinct from c.category_id))
     and c.rule_id = any (p_rule_ids);
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

comment on function private.apply_own_iban_rules(uuid, uuid[]) is
  'Neue Regeln für eigene IBANs anwenden – nur auf Buchungen mit diesen IBANs als Gegenkonto (statt aller '
  'Buchungen); automatisch zugeordnete werden überschrieben, manuelle nie. Liefert die Zahl der Buchungen.';

create or replace function public.import_statement(p_sections jsonb, p_dry_run boolean default false)
returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_uid         uuid := auth.uid();
  v_section     record;
  v_account     record;
  v_run         record;
  v_ibans       text[];
  v_targets     uuid[] := '{}';
  v_transfer    uuid;
  v_rule_id     uuid;
  v_new_rules   uuid[] := '{}';
  v_own_missing integer;
  v_result      jsonb := '[]'::jsonb;
  v_account_id  uuid;
  v_account_name text;
  v_new_account boolean;
  v_opening_set boolean;
  v_opening     numeric;
  v_balance     numeric;
  v_internal    integer;
  v_learned     integer := 0;
  v_suggested   integer := 0;
  v_total       integer := 0;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if p_sections is null or jsonb_typeof(p_sections) <> 'array' or jsonb_array_length(p_sections) = 0 then
    raise exception 'invalid_sections' using errcode = '22023';
  end if;
  if jsonb_array_length(p_sections) > 50 then
    raise exception 'too_many_sections' using errcode = '22023';
  end if;

  -- Abschnitte lesen und prüfen
  if to_regclass('pg_temp.statement_sections') is not null then
    drop table pg_temp.statement_sections;
  end if;
  create temporary table statement_sections (
    idx integer, iban text, account_id uuid, new_name text, institution text,
    opening numeric(14,2), closing numeric(14,2), period_from date, period_to date, rows jsonb
  ) on commit drop;

  begin
    insert into pg_temp.statement_sections
    select e.ordinality::integer,
           upper(regexp_replace(coalesce(e.value ->> 'iban', ''), '\s', '', 'g')),
           nullif(e.value ->> 'account_id', '')::uuid,
           nullif(btrim(e.value ->> 'new_account_name'), ''),
           nullif(btrim(e.value ->> 'institution'), ''),
           (e.value ->> 'opening')::numeric,
           (e.value ->> 'closing')::numeric,
           (e.value ->> 'period_from')::date,
           (e.value ->> 'period_to')::date,
           e.value -> 'rows'
      from jsonb_array_elements(p_sections) with ordinality as e;
  exception when others then
    raise exception 'invalid_section' using errcode = '22023';
  end;

  for v_section in select * from pg_temp.statement_sections s order by s.idx loop
    if v_section.iban !~ '^[A-Z]{2}[0-9]{2}[0-9A-Z]{11,30}$'
       or v_section.opening is null or v_section.closing is null
       or v_section.period_from is null or v_section.period_to is null
       or v_section.period_from > v_section.period_to
       or v_section.rows is null or jsonb_typeof(v_section.rows) <> 'array'
       or char_length(v_section.institution) > 120 then
      raise exception 'invalid_section' using errcode = '22023', detail = v_section.idx::text;
    end if;
    v_total := v_total + jsonb_array_length(v_section.rows);
  end loop;
  if v_total > 5000 then
    raise exception 'too_many_rows' using errcode = '22023';
  end if;
  if (select count(distinct s.iban) from pg_temp.statement_sections s) <> (select count(*) from pg_temp.statement_sections) then
    raise exception 'duplicate_section' using errcode = '22023';
  end if;
  select array_agg(s.iban order by s.idx) into v_ibans from pg_temp.statement_sections s;

  -- Saldenprüfung je Abschnitt (Zeilen erst hier vollständig geprüft)
  for v_section in select * from pg_temp.statement_sections s order by s.idx loop
    if v_section.opening + coalesce((select sum(r.amount) from private.import_rows(v_section.rows, 'EUR') r), 0)
       <> v_section.closing then
      raise exception 'balance_mismatch' using errcode = '22023', detail = v_section.iban;
    end if;
  end loop;

  -- Zielkonten prüfen
  for v_section in select * from pg_temp.statement_sections s order by s.idx loop
    if v_section.account_id is not null then
      select a.id, a.iban, a.provider into v_account
        from public.accounts a
       where a.id = v_section.account_id and a.user_id = v_uid and a.archived_at is null;
      if not found then
        raise exception 'account_not_found' using errcode = 'P0002', detail = v_section.iban;
      end if;
      if v_account.provider not in ('manual', 'csv') then
        raise exception 'account_not_importable' using errcode = '22023', detail = v_section.iban;
      end if;
      if v_account.iban is not null and v_account.iban <> v_section.iban then
        raise exception 'iban_mismatch' using errcode = '22023', detail = v_section.iban;
      end if;
      if v_section.account_id = any (v_targets) then
        raise exception 'duplicate_target' using errcode = '22023', detail = v_section.iban;
      end if;
      v_targets := v_targets || v_section.account_id;
    elsif v_section.new_name is null or char_length(v_section.new_name) > 120 then
      raise exception 'invalid_account_name' using errcode = '22023', detail = v_section.iban;
    end if;
    if exists (
      select 1 from public.accounts a
       where a.user_id = v_uid and a.iban = v_section.iban and a.id is distinct from v_section.account_id
    ) then
      raise exception 'iban_in_use' using errcode = '23505', detail = v_section.iban;
    end if;
  end loop;

  -- IBANs der Abschnitte als eigene Konten (Zielkategorie Umbuchung)
  select c.id into v_transfer from public.categories c where c.user_id = v_uid and c.default_key = 'transfer';
  select count(*) into v_own_missing
    from unnest(v_ibans) i (iban)
   where not exists (
     select 1 from public.categorization_rules r
      where r.user_id = v_uid and r.origin = 'own_account' and r.match_field = 'counterparty_iban'
        and upper(r.pattern) = i.iban
   );
  if v_transfer is null then
    v_own_missing := 0;
  elsif not p_dry_run then
    for v_section in select * from pg_temp.statement_sections s order by s.idx loop
      if not exists (
        select 1 from public.categorization_rules r
         where r.user_id = v_uid and r.origin = 'own_account' and r.match_field = 'counterparty_iban'
           and upper(r.pattern) = v_section.iban
      ) then
        insert into public.categorization_rules (user_id, category_id, pattern, match_type, match_field, priority, origin)
        values (v_uid, v_transfer, v_section.iban, 'equals', 'counterparty_iban', 100, 'own_account')
        returning id into v_rule_id;
        v_new_rules := v_new_rules || v_rule_id;
      end if;
    end loop;
  end if;

  -- Abschnitte importieren
  for v_section in select * from pg_temp.statement_sections s order by s.idx loop
    v_account_id := v_section.account_id;
    v_new_account := v_account_id is null;
    if v_new_account and not p_dry_run then
      insert into public.accounts (user_id, name, type, provider, currency, institution_name, iban, iban_last4,
                                   opening_balance)
      values (v_uid, v_section.new_name, 'checking', 'csv', 'EUR', v_section.institution, v_section.iban,
              right(v_section.iban, 4), v_section.opening)
      returning id into v_account_id;
    elsif not v_new_account and not p_dry_run then
      update public.accounts a
         set iban = v_section.iban, iban_last4 = right(v_section.iban, 4)
       where a.id = v_account_id and a.iban is null;
    end if;

    perform private.import_batch_prepare();
    insert into pg_temp.import_batch (ord, booking_date, value_date, amount, currency, counterparty, purpose,
                                      transaction_type, counterparty_iban, description, mandate_reference,
                                      creditor_id, import_hash)
    select r.ord, r.booking_date, r.value_date, r.amount, r.currency, r.counterparty, r.purpose,
           r.transaction_type, r.counterparty_iban, r.description, r.mandate_reference, r.creditor_id,
           private.import_hash(r.booking_date, r.amount, concat_ws(' | ', r.counterparty, r.purpose),
             row_number() over (
               partition by r.booking_date, r.amount,
                            btrim(regexp_replace(lower(concat_ws(' | ', r.counterparty, r.purpose)), '\s+', ' ', 'g'))
               order by r.ord))
      from private.import_rows(v_section.rows, 'EUR') r;

    select * into v_run from private.import_batch_run(v_uid, v_account_id, 'pdf_import', p_dry_run, true);

    -- Vorschau: Umbuchungen zwischen den Konten des Auszugs gelten als
    -- zugeordnet (die Regeln für die eigenen IBANs entstehen erst beim Import).
    v_internal := 0;
    if p_dry_run and v_transfer is not null then
      select count(*) into v_internal
        from pg_temp.import_batch b
       where not b.duplicate and not b.probable and b.category_id is null
         and b.counterparty_iban = any (v_ibans);
    end if;

    -- Anfangsbestand: Ist dies der früheste Auszug des Kontos, gilt sein
    -- alter Kontostand (auch beim Nachimport eines früheren Monats).
    v_opening_set := false;
    if v_new_account then
      v_opening := v_section.opening;
      v_opening_set := true;
    else
      select a.opening_balance into v_opening from public.accounts a where a.id = v_account_id;
      if not exists (
        select 1 from public.transactions t
         where t.account_id = v_account_id and t.booking_date < v_section.period_from
      ) and v_opening is distinct from v_section.opening then
        v_opening := v_section.opening;
        v_opening_set := true;
        if not p_dry_run then
          update public.accounts a set opening_balance = v_section.opening where a.id = v_account_id;
        end if;
      end if;
    end if;

    -- Kontostand der App zum Ende des Auszugs (Vorschau: hochgerechnet)
    v_balance := v_opening
      + coalesce((select sum(t.amount)
                    from public.transactions t
                    join public.accounts a on a.id = t.account_id
                   where t.account_id = v_account_id
                     and t.currency = a.currency
                     and t.booking_date <= v_section.period_to), 0)
      + case when p_dry_run
             then coalesce((select sum(b.amount) from pg_temp.import_batch b
                             where not b.duplicate and not b.probable and b.booking_date <= v_section.period_to), 0)
             else 0 end;

    v_account_name := null;
    select a.name into v_account_name from public.accounts a where a.id = v_account_id;

    v_result := v_result || jsonb_build_object(
      'iban',          v_section.iban,
      'account_id',    v_account_id,
      'account_name',  coalesce(v_account_name, v_section.new_name),
      'new_account',   v_new_account,
      'total',         jsonb_array_length(v_section.rows),
      'new',           v_run.new_rows,
      'duplicates',    v_run.duplicates,
      'probable',      v_run.probable,
      'probable_rows', coalesce((
        select jsonb_agg(jsonb_build_object('booking_date', b.booking_date, 'amount', b.amount,
                                            'counterparty', b.counterparty) order by b.ord)
          from (select * from pg_temp.import_batch b where b.probable order by b.ord limit 20) b), '[]'::jsonb),
      'categorized',   v_run.categorized + v_internal,
      'enriched',      v_run.enriched,
      'opening_set',   v_opening_set,
      'closing',       v_section.closing,
      'balance',       v_balance
    );
  end loop;

  if not p_dry_run then
    -- Neue eigene IBANs auch auf vorhandene Buchungen anwenden (z. B. die
    -- Gegenseite auf einem anderen Konto).
    perform private.apply_own_iban_rules(v_uid, v_new_rules);
    perform private.refresh_recurrence(v_uid);
    select b.assigned, b.suggested into v_learned, v_suggested from private.bayes_run(v_uid, true) b;
  end if;

  return jsonb_build_object(
    'sections',       v_result,
    'own_ibans_added', case when p_dry_run then v_own_missing else coalesce(array_length(v_new_rules, 1), 0) end,
    'learned',        v_learned,
    'suggested',      v_suggested,
    'dry_run',        p_dry_run
  );
end;
$$;

-- Dasselbe für „Eigenes Konto hinzufügen“ (IBAN) und das Ändern der
-- Zielkategorie auf der Regeln-Seite: nur Buchungen mit dieser IBAN.
create or replace function public.add_own_account_identifier(p_kind text, p_value text, p_category_id uuid default null)
returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_uid      uuid := auth.uid();
  v_category uuid;
  v_pattern  text;
  v_id       uuid;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if p_kind = 'name' then
    v_pattern := private.normalize_booking_text(p_value);
    -- Mindestens zwei Wörter (Vor- und Nachname).
    if char_length(v_pattern) > 200 or coalesce(array_length(regexp_split_to_array(v_pattern, ' '), 1), 0) < 2
       or v_pattern !~ '[[:alpha:]]{2}' then
      raise exception 'invalid_name' using errcode = '22023';
    end if;
  elsif p_kind = 'iban' then
    v_pattern := upper(regexp_replace(coalesce(p_value, ''), '\s', '', 'g'));
    if v_pattern !~ '^[A-Z]{2}[0-9]{2}[0-9A-Z]{11,30}$' then
      raise exception 'invalid_iban' using errcode = '22023';
    end if;
  else
    raise exception 'invalid_kind' using errcode = '22023';
  end if;

  if p_category_id is not null then
    select c.id into v_category from public.categories c where c.id = p_category_id and c.user_id = v_uid;
  else
    select c.id into v_category from public.categories c where c.user_id = v_uid and c.default_key = 'transfer';
  end if;
  if v_category is null then
    raise exception 'category_not_found' using errcode = 'P0002';
  end if;

  if exists (
    select 1 from public.categorization_rules r
     where r.user_id = v_uid and r.origin = 'own_account' and r.pattern = v_pattern
  ) then
    raise exception 'rule_exists' using errcode = '23505';
  end if;

  insert into public.categorization_rules (user_id, category_id, pattern, match_type, match_field, priority, origin)
  values (v_uid, v_category, v_pattern,
          case when p_kind = 'name' then 'all_words' else 'equals' end::public.rule_match_type,
          case when p_kind = 'name' then 'counterparty' else 'counterparty_iban' end::public.rule_match_field,
          100, 'own_account')
  returning id into v_id;

  if p_kind = 'name' then
    -- Nur Vorschlag (Gruppenansicht): zählen, nichts zuordnen.
    return jsonb_build_object('rule_id', v_id, 'applied', 0, 'suggested', (
      select count(*)
        from public.transactions t
        cross join lateral private.match_rule_detail(v_uid, t.account_id, t.amount, t.counterparty_name, t.purpose,
                                                     null, null, null, array['own_account'], true) d
       where t.user_id = v_uid and t.category_id is null and d.rule_id = v_id));
  end if;
  return jsonb_build_object('rule_id', v_id,
                            'applied', private.apply_own_iban_rules(v_uid, array[v_id]),
                            'suggested', 0);
end;
$$;

create or replace function public.set_own_account_category(p_rule_id uuid, p_category_id uuid)
returns integer
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
  if not exists (select 1 from public.categories c where c.id = p_category_id and c.user_id = v_uid) then
    raise exception 'category_not_found' using errcode = 'P0002';
  end if;
  update public.categorization_rules r
     set category_id = p_category_id
   where r.id = p_rule_id and r.user_id = v_uid and r.origin = 'own_account';
  if not found then
    raise exception 'rule_not_found' using errcode = 'P0002';
  end if;
  -- Namensregeln ordnen nichts zu (nur Vorschläge); IBAN-Regeln gezielt.
  return private.apply_own_iban_rules(v_uid, array[p_rule_id]);
end;
$$;

revoke all on function private.apply_own_iban_rules(uuid, uuid[]) from public, anon;
grant execute on function private.apply_own_iban_rules(uuid, uuid[]) to authenticated;

commit;
