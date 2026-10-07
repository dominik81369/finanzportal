-- =====================================================================
--  20261009100000_categorization_b2.sql
--
--  Kategorisierung, PR B2: lernender Klassifikator (Naive Bayes mit
--  Laplace-Glättung), Prüfliste, Einstellungen, Genauigkeit an
--  zurückgehaltenen Daten.
--
--  Merkmale je Buchung (transactions.features, per Trigger):
--    Wörter aus Empfänger, Verwendungszweck, Beschreibung – normalisiert
--    (NFKC, klein, Umlaute ausgeschrieben), ohne IBANs, Datum, Uhrzeit,
--    reine Zahlen, Codes (≥ 2 Ziffern und ≥ 4 Zeichen; „mcfit24“ → „mcfit“),
--    Ein-Zeichen-Wörter und Stoppwörter; je Wort einmal, höchstens 30.
--    t:<transaktionstyp>   immer, falls vorhanden
--    s:aus | s:ein         immer
--    p:<1–3 wörter>        Empfänger als ein Merkmal (nicht bei Vermittlern)
--  Beim Rechnen ergänzt:
--    r:<rhythmus>          wiederkehrende Buchung
--    i:<hash der iban>, b:<betragsklasse>
--                          nur wenn derselbe Händler (Gegenpartei) im
--                          Training schon in mindestens 2 Kategorien vorkam
--  Es gibt keine Zähltabellen: das Modell wird je Lauf in temporären
--  Tabellen gebaut (keine IBAN im Klartext, nichts veraltet).
--
--  Training NUR aus manuellen Zuordnungen (inkl. bestätigter Vorschläge)
--  und eigenen Regeln (origin manual/learned/own_account) – nie aus
--  Zuordnungen mit Herkunft learned (kein Selbsttraining), nie aus
--  Standardregeln.
--
--  Schicht 6 (nach eigenen Regeln, Gedächtnis, eigenen Konten und
--  Standardregeln): Sicherheit ≥ Schwelle (Standard 0,90) und Betrag unter
--  der Prüfgrenze (Standard 1.000) → automatisch (learned, mit Sicherheit);
--  sonst Vorschlag in der Prüfliste (unsicherste zuerst). Konflikte (ein
--  Händler, mehrere Kategorien) unterscheidet der Klassifikator über IBAN
--  und Betragsklasse; reicht das nicht, landet die Buchung in der Prüfliste.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- Spalten und Einstellungen
-- ---------------------------------------------------------------------
alter table public.transactions
  add column features text[],
  add column categorization_confidence numeric(5,4) check (categorization_confidence between 0 and 1),
  add column auto_confidence numeric(5,4) check (auto_confidence between 0 and 1),
  add column suggested_category_id uuid,
  add column suggestion_confidence numeric(5,4) check (suggestion_confidence between 0 and 1),
  add constraint transactions_suggested_category_fkey
    foreign key (suggested_category_id, user_id) references public.categories (id, user_id)
    on delete set null (suggested_category_id);

comment on column public.transactions.features is
  'Wortmerkmale für den Klassifikator (private.bayes_base_features), ohne IBAN im Klartext.';
comment on column public.transactions.categorization_confidence is
  'Sicherheit der gelernten Zuordnung (Klassifikator); NULL bei Regeln, Gedächtnis und manuell.';
comment on column public.transactions.auto_confidence is 'Sicherheit der ersten automatischen Zuordnung (Klassifikator).';
comment on column public.transactions.suggested_category_id is 'Vorschlag des Klassifikators (Prüfliste).';
comment on column public.transactions.suggestion_confidence is 'Sicherheit des Vorschlags.';

create index transactions_user_suggestion_idx
  on public.transactions (user_id, suggestion_confidence)
  where category_id is null and suggested_category_id is not null;

create table public.categorization_settings (
  user_id             uuid primary key default auth.uid() references auth.users (id) on delete cascade,
  bayes_threshold     numeric(4,3)  not null default 0.900 check (bayes_threshold between 0.5 and 0.999),
  review_amount_limit numeric(14,2) not null default 1000 check (review_amount_limit > 0),
  updated_at          timestamptz   not null default now()
);

comment on table public.categorization_settings is
  'Je Nutzer: Schwelle für automatische Zuordnung durch den Klassifikator und Betrag, ab dem seine Treffer '
  'immer in die Prüfliste gehen (gilt nicht für Regeln und Gedächtnis).';

alter table public.categorization_settings enable row level security;
create policy categorization_settings_select_owner on public.categorization_settings
  for select to authenticated using (user_id = (select auth.uid()));
create policy categorization_settings_insert_owner on public.categorization_settings
  for insert to authenticated with check (user_id = (select auth.uid()));
create policy categorization_settings_update_owner on public.categorization_settings
  for update to authenticated using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
grant select, insert, update on public.categorization_settings to authenticated;

-- ---------------------------------------------------------------------
-- Merkmale
-- ---------------------------------------------------------------------
-- Wörter eines Textes in Reihenfolge (Normalisierung wie oben).
create or replace function private.bayes_words(p_text text)
returns text[]
language sql
immutable
parallel safe
set search_path = ''
as $$
  select coalesce(array_agg(y.word order by y.position), '{}')
    from (
      select case when x.word ~ '^[a-z]{3,}[0-9]+$' then regexp_replace(x.word, '[0-9]+$', '') else x.word end as word,
             x.position
        from regexp_split_to_table(
               regexp_replace(regexp_replace(regexp_replace(regexp_replace(
                 replace(replace(replace(replace(lower(normalize(coalesce(p_text, ''), NFKC)),
                   'ä', 'ae'), 'ö', 'oe'), 'ü', 'ue'), 'ß', 'ss'),
                 -- IBAN (auch mit Leerzeichen)
                 '\m[a-z]{2}[0-9]{2}( ?[a-z0-9]{4}){2,7}( ?[a-z0-9]{1,4})?\M', ' ', 'g'),
                 -- Datum 01.09.2026 / 05.09.26
                 '\m[0-9]{1,2}\.[0-9]{1,2}\.([0-9]{4}|[0-9]{2})\M', ' ', 'g'),
                 -- Datum 2026-09-01
                 '\m[0-9]{4}-[0-9]{2}-[0-9]{2}\M', ' ', 'g'),
                 -- Uhrzeit 18:45 / 18:45:12
                 '\m[0-9]{1,2}:[0-9]{2}(:[0-9]{2})?\M', ' ', 'g'),
               '[^a-z0-9]+') with ordinality as x (word, position)
    ) y
   where char_length(y.word) >= 2
     and y.word !~ '^[0-9]+$'
     and not (y.word ~ '[0-9].*[0-9]' and char_length(y.word) >= 4)
     and y.word <> all (array[
       -- Füllwörter
       'und', 'oder', 'der', 'die', 'das', 'den', 'dem', 'des', 'ein', 'eine', 'einer', 'eines', 'fuer',
       'bei', 'von', 'vom', 'zum', 'zur', 'mit', 'im', 'in', 'an', 'am', 'auf', 'aus', 'zu', 'per', 'ihr',
       'ihre', 'ihren', 'nr', 'the', 'of', 'and', 'for',
       -- Rechtsformen
       'gmbh', 'mbh', 'ag', 'kg', 'kgaa', 'se', 'sarl', 'sca', 'ltd', 'gbr', 'ab', 'inc', 'co', 'et', 'cie',
       'sa', 'sas', 'bv', 'nv', 'ug', 'ohg', 'ev', 'eg', 'llc', 'corp', 'limited', 'haftungsbeschraenkt',
       -- Web-Reste
       'www', 'com', 'de', 'http', 'https',
       -- SEPA-Feldkürzel
       'eref', 'mref', 'cred', 'svwz', 'abwa', 'iban', 'bic', 'end', 'to', 'notprovided', 'kref']);
$$;

comment on function private.bayes_words(text) is
  'Wörter für den Klassifikator: NFKC, klein, Umlaute ausgeschrieben; ohne IBAN, Datum, Uhrzeit, Zahlen, '
  'Codes (≥ 2 Ziffern und ≥ 4 Zeichen; Buchstaben+Ziffern-Ende wie mcfit24 → mcfit), Ein-Zeichen-Wörter '
  'und Stoppwörter.';

-- Feste Merkmale einer Buchung (ohne r:, i:, b:).
create or replace function private.bayes_base_features(
  p_counterparty     text,
  p_purpose          text,
  p_description      text,
  p_transaction_type text,
  p_amount           numeric
)
returns text[]
language plpgsql
immutable
parallel safe
set search_path = ''
as $$
declare
  v_counterparty text[] := private.bayes_words(p_counterparty);
  v_words        text[];
  v_type         text[] := private.bayes_words(p_transaction_type);
  v_result       text[];
begin
  -- Gemeinsamer Wortschatz, jedes Wort einmal (erste Fundstelle), max. 30.
  select coalesce(array_agg(d.word order by d.position), '{}') into v_words
    from (
      select w.word, min(w.position) as position
        from unnest(v_counterparty || private.bayes_words(p_purpose) || private.bayes_words(p_description))
             with ordinality as w (word, position)
       group by w.word
       order by min(w.position)
       limit 30
    ) d;
  v_result := v_words;
  if cardinality(v_type) > 0 then
    v_result := v_result || ('t:' || array_to_string(v_type, '_'));
  end if;
  v_result := v_result || (case when p_amount < 0 then 's:aus' else 's:ein' end);
  -- Empfänger als ein Merkmal – nicht bei Zahlungsvermittlern.
  if cardinality(v_counterparty) > 0 and not private.is_payment_processor(p_counterparty) then
    v_result := v_result || ('p:' || array_to_string(v_counterparty[1:3], '_'));
  end if;
  return v_result;
end;
$$;

-- Zur Rechenzeit ergänzte Merkmale.
create or replace function private.bayes_features(
  p_base       text[],
  p_recurrence text,
  p_iban       text,
  p_amount     numeric,
  p_ambiguous  boolean
)
returns text[]
language sql
immutable
parallel safe
set search_path = ''
as $$
  select coalesce(p_base, '{}')
         || case when p_recurrence is not null then array['r:' || p_recurrence] else '{}'::text[] end
         || case when p_ambiguous then
              array_remove(array[
                case when p_iban is not null
                     then 'i:' || left(md5(upper(regexp_replace(p_iban, '\s', '', 'g'))), 12) end,
                'b:' || case when abs(p_amount) < 10 then '<10'
                             when abs(p_amount) < 50 then '10-50'
                             when abs(p_amount) < 200 then '50-200'
                             when abs(p_amount) < 1000 then '200-1000'
                             else '>1000' end
              ], null)
            else '{}'::text[] end;
$$;

-- SECURITY DEFINER: auch für service_role und Kaskaden.
create or replace function private.transactions_set_features()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  new.features := private.bayes_base_features(new.counterparty_name, new.purpose, new.description,
                                              new.transaction_type, new.amount);
  return new;
end;
$$;

create trigger transactions_features
  before insert or update of counterparty_name, purpose, description, transaction_type, amount on public.transactions
  for each row execute function private.transactions_set_features();

-- Vorschlag und Sicherheit passend halten: Mit Kategorie kein Vorschlag;
-- Sicherheit nur bei gelernten Zuordnungen.
create or replace function private.transactions_sync_suggestion()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.category_id is not null then
    new.suggested_category_id := null;
    new.suggestion_confidence := null;
  end if;
  if new.categorization_source is distinct from 'learned' then
    new.categorization_confidence := null;
  end if;
  return new;
end;
$$;

create trigger transactions_sync_suggestion
  before update of category_id, categorization_source on public.transactions
  for each row execute function private.transactions_sync_suggestion();

-- ---------------------------------------------------------------------
-- Modell (temporär je Lauf)
-- ---------------------------------------------------------------------
-- Trainingsdaten: manuell oder eigene Regel; nie learned, nie Standard.
-- p_holdout: jede fünfte Buchung (fest über die ID) zurückhalten – für die
-- Genauigkeitsmessung an Daten, die nicht im Training waren.
create or replace function private.bayes_build(p_user_id uuid, p_holdout boolean)
returns integer
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_docs integer;
begin
  if to_regclass('pg_temp.bayes_train') is not null then drop table pg_temp.bayes_train; end if;
  if to_regclass('pg_temp.bayes_test') is not null then drop table pg_temp.bayes_test; end if;
  if to_regclass('pg_temp.bayes_ambiguous') is not null then drop table pg_temp.bayes_ambiguous; end if;
  if to_regclass('pg_temp.bayes_tok') is not null then drop table pg_temp.bayes_tok; end if;
  if to_regclass('pg_temp.bayes_cat') is not null then drop table pg_temp.bayes_cat; end if;
  if to_regclass('pg_temp.bayes_meta') is not null then drop table pg_temp.bayes_meta; end if;

  create temporary table bayes_train on commit drop as
  select t.id, t.category_id, t.counterparty_key as key, t.features as base, t.recurrence,
         t.counterparty_iban as iban, t.amount, null::text[] as features
    from public.transactions t
    left join public.categorization_rules r on r.id = t.categorization_rule_id
   where t.user_id = p_user_id
     and t.category_id is not null
     and t.features is not null
     and (t.categorization_source = 'manual'
          or (t.categorization_source = 'rule' and r.origin in ('manual', 'learned', 'own_account')));

  create temporary table bayes_test on commit drop as
  select * from pg_temp.bayes_train where p_holdout and abs(hashtext(id::text)) % 5 = 0;
  delete from pg_temp.bayes_train b where p_holdout and abs(hashtext(b.id::text)) % 5 = 0;

  -- Händler mit mehreren Kategorien: dort helfen IBAN und Betragsklasse.
  create temporary table bayes_ambiguous on commit drop as
  select b.key from pg_temp.bayes_train b where b.key is not null
   group by b.key having count(distinct b.category_id) >= 2;

  -- WHERE nötig: PostgREST lädt pg-safeupdate (UPDATE ohne WHERE verboten).
  update pg_temp.bayes_train b
     set features = private.bayes_features(b.base, b.recurrence, b.iban, b.amount,
                                           exists (select 1 from pg_temp.bayes_ambiguous a where a.key = b.key))
   where b.id is not null;

  create temporary table bayes_tok on commit drop as
  select b.category_id, f.token, count(*)::numeric as n
    from pg_temp.bayes_train b cross join lateral unnest(b.features) as f (token)
   group by b.category_id, f.token;
  create index on pg_temp.bayes_tok (token);

  create temporary table bayes_cat on commit drop as
  select b.category_id, count(*)::numeric as docs,
         coalesce((select sum(k.n) from pg_temp.bayes_tok k where k.category_id = b.category_id), 0) as tokens
    from pg_temp.bayes_train b
   group by b.category_id;

  create temporary table bayes_meta on commit drop as
  select (select count(*) from pg_temp.bayes_train)::numeric as docs,
         (select count(*) from pg_temp.bayes_cat)::numeric as cats,
         greatest(1, (select count(distinct k.token) from pg_temp.bayes_tok k))::numeric as vocab;

  select m.docs::integer into v_docs from pg_temp.bayes_meta m;
  return v_docs;
end;
$$;

-- Vorhersage für pg_temp.bayes_target (id, features) nach
-- pg_temp.bayes_result (id, category_id, confidence). Nur Merkmale aus dem
-- Wortschatz zählen; ohne bekanntes inhaltliches Merkmal (Wort, p:, i:, t:)
-- keine Vorhersage. Mindestens
-- 10 Trainingsbuchungen in 2 Kategorien.
create or replace function private.bayes_predict()
returns integer
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_count integer;
begin
  if to_regclass('pg_temp.bayes_result') is not null then drop table pg_temp.bayes_result; end if;
  create temporary table bayes_result (id uuid, category_id uuid, confidence numeric) on commit drop;

  if (select m.docs < 10 or m.cats < 2 from pg_temp.bayes_meta m) then
    return 0;
  end if;

  insert into pg_temp.bayes_result
  with f as (
    select g.id, x.token
      from pg_temp.bayes_target g
      cross join lateral unnest(g.features) as x (token)
     where exists (select 1 from pg_temp.bayes_tok k where k.token = x.token)
  ),
  -- Nur mit mindestens einem inhaltlichen Merkmal (nicht nur s:/b:/r:).
  ids as (select distinct f.id from f where f.token !~ '^(s|b|r):'),
  s as (
    select i.id, c.category_id,
           ln((c.docs + 1) / (m.docs + m.cats))
           + coalesce(sum(ln((coalesce(k.n, 0) + 1) / (c.tokens + m.vocab))), 0) as score
      from ids i
      cross join pg_temp.bayes_cat c
      cross join pg_temp.bayes_meta m
      left join f on f.id = i.id
      left join pg_temp.bayes_tok k on k.category_id = c.category_id and k.token = f.token
     group by i.id, c.category_id, c.docs, c.tokens, m.docs, m.cats, m.vocab
  ),
  -- Softmax; sehr kleine Werte auf ~0 begrenzen (kein Unterlauf).
  e as (
    select s.id, s.category_id,
           exp(greatest((s.score - max(s.score) over (partition by s.id))::double precision, -700)) as e
      from s
  )
  select distinct on (e.id) e.id, e.category_id,
         round((e.e / sum(e.e) over (partition by e.id))::numeric, 4)
    from e
   order by e.id, e.e desc, e.category_id;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- Klassifikator auf alle Buchungen ohne Kategorie anwenden. p_assign:
-- sichere Treffer (≥ Schwelle, Betrag unter der Prüfgrenze) zuordnen;
-- übrige als Vorschlag speichern. Liefert (assigned, suggested).
create or replace function private.bayes_run(p_user_id uuid, p_assign boolean)
returns table (assigned integer, suggested integer)
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_threshold numeric := 0.9;
  v_limit     numeric := 1000;
  v_assigned  integer := 0;
  v_suggested integer := 0;
begin
  select s.bayes_threshold, s.review_amount_limit into v_threshold, v_limit
    from public.categorization_settings s where s.user_id = p_user_id;
  v_threshold := coalesce(v_threshold, 0.9);
  v_limit := coalesce(v_limit, 1000);

  perform private.bayes_build(p_user_id, false);

  if to_regclass('pg_temp.bayes_target') is not null then drop table pg_temp.bayes_target; end if;
  create temporary table bayes_target on commit drop as
  select t.id, t.amount,
         private.bayes_features(t.features, t.recurrence, t.counterparty_iban, t.amount,
           exists (select 1 from pg_temp.bayes_ambiguous a where a.key = t.counterparty_key)) as features
    from public.transactions t
   where t.user_id = p_user_id and t.category_id is null and t.features is not null;

  perform private.bayes_predict();

  if p_assign then
    update public.transactions t
       set category_id = r.category_id,
           categorization_source = 'learned',
           categorization_rule_id = null,
           categorization_confidence = r.confidence,
           auto_category_id = coalesce(t.auto_category_id, r.category_id),
           auto_source = case when t.auto_category_id is null then 'learned'::public.categorization_source
                              else t.auto_source end,
           auto_rule_id = case when t.auto_category_id is null then null else t.auto_rule_id end,
           auto_confidence = case when t.auto_category_id is null then r.confidence else t.auto_confidence end
      from pg_temp.bayes_result r
     where r.id = t.id
       and t.user_id = p_user_id
       and t.category_id is null
       and r.confidence >= v_threshold
       and abs(t.amount) < v_limit;
    get diagnostics v_assigned = row_count;
  end if;

  update public.transactions t
     set suggested_category_id = r.category_id, suggestion_confidence = r.confidence
    from pg_temp.bayes_result r
   where r.id = t.id and t.user_id = p_user_id and t.category_id is null;
  get diagnostics v_suggested = row_count;

  -- Ohne Vorhersage kein (veralteter) Vorschlag.
  update public.transactions t
     set suggested_category_id = null, suggestion_confidence = null
   where t.user_id = p_user_id
     and t.category_id is null
     and t.suggested_category_id is not null
     and not exists (select 1 from pg_temp.bayes_result r where r.id = t.id);

  return query select v_assigned, v_suggested;
end;
$$;

comment on function private.bayes_run(uuid, boolean) is
  'Klassifikator (Naive Bayes, Laplace) auf Buchungen ohne Kategorie: sichere Treffer zuordnen (learned), '
  'übrige als Vorschlag speichern.';

-- ---------------------------------------------------------------------
-- Öffentliche Schnittstellen
-- ---------------------------------------------------------------------
-- Vorschläge neu berechnen (ohne zuzuordnen) – z. B. beim Öffnen der
-- Prüfliste.
create or replace function public.refresh_suggestions()
returns integer
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_row record;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  select * into v_row from private.bayes_run(v_uid, false);
  return v_row.suggested;
end;
$$;

-- Vorschläge übernehmen (gelten danach als manuell und trainieren das
-- Modell). Nur eigene Buchungen ohne Kategorie mit Vorschlag.
create or replace function public.confirm_suggestions(p_ids uuid[])
returns integer
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_uid   uuid := auth.uid();
  v_count integer;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if p_ids is null or cardinality(p_ids) > 1000 then
    raise exception 'invalid_ids' using errcode = '22023';
  end if;
  update public.transactions t
     set category_id = t.suggested_category_id,
         categorization_source = 'manual',
         categorization_rule_id = null
   where t.user_id = v_uid
     and t.id = any (p_ids)
     and t.category_id is null
     and t.suggested_category_id is not null;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- Einstellungen speichern.
create or replace function public.save_categorization_settings(p_threshold numeric, p_review_amount_limit numeric)
returns void
language plpgsql
volatile
security invoker
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if p_threshold is null or p_threshold < 0.5 or p_threshold > 0.999
     or p_review_amount_limit is null or p_review_amount_limit <= 0 or p_review_amount_limit >= 1000000000000 then
    raise exception 'invalid_settings' using errcode = '22023';
  end if;
  insert into public.categorization_settings (user_id, bayes_threshold, review_amount_limit, updated_at)
  values (auth.uid(), round(p_threshold, 3), round(p_review_amount_limit, 2), now())
  on conflict (user_id) do update
    set bayes_threshold = excluded.bayes_threshold,
        review_amount_limit = excluded.review_amount_limit,
        updated_at = now();
end;
$$;

-- Genauigkeit an zurückgehaltenen Daten: jede fünfte Trainingsbuchung
-- (fest über die ID) bleibt aus dem Training und wird vorhergesagt.
create or replace function public.bayes_evaluate()
returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_uid       uuid := auth.uid();
  v_threshold numeric;
  v_result    jsonb;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  select coalesce((select s.bayes_threshold from public.categorization_settings s where s.user_id = v_uid), 0.9)
    into v_threshold;

  perform private.bayes_build(v_uid, true);

  if to_regclass('pg_temp.bayes_target') is not null then drop table pg_temp.bayes_target; end if;
  create temporary table bayes_target on commit drop as
  select b.id, b.amount,
         private.bayes_features(b.base, b.recurrence, b.iban, b.amount,
           exists (select 1 from pg_temp.bayes_ambiguous a where a.key = b.key)) as features
    from pg_temp.bayes_test b;

  perform private.bayes_predict();

  select jsonb_build_object(
           'trained',   (select m.docs::integer from pg_temp.bayes_meta m),
           'tested',    count(*),
           'predicted', count(r.id),
           'correct',   count(*) filter (where r.category_id = b.category_id),
           'accuracy',  round(count(*) filter (where r.category_id = b.category_id)::numeric / nullif(count(*), 0), 4),
           'confident', count(*) filter (where r.confidence >= v_threshold),
           'confident_correct', count(*) filter (where r.confidence >= v_threshold and r.category_id = b.category_id),
           'confident_accuracy', round(count(*) filter (where r.confidence >= v_threshold and r.category_id = b.category_id)::numeric
                                       / nullif(count(*) filter (where r.confidence >= v_threshold), 0), 4))
    into v_result
    from pg_temp.bayes_test b
    left join pg_temp.bayes_result r on r.id = b.id;
  return v_result;
end;
$$;

comment on function public.bayes_evaluate() is
  'Genauigkeit des Klassifikators an Daten, die nicht im Training waren (jede fünfte Trainingsbuchung): '
  'tested, correct, accuracy; confident/confident_accuracy für Treffer über der Schwelle.';

-- ---------------------------------------------------------------------
-- Import und „Auf alle anwenden“: danach der Klassifikator
-- ---------------------------------------------------------------------
create or replace function public.import_transactions(
  p_account_id           uuid,
  p_rows                 jsonb,
  p_dry_run              boolean default false,
  p_new_account_name     text    default null,
  p_new_account_currency text    default null
)
returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_uid         uuid := auth.uid();
  v_account_id  uuid;
  v_currency    public.currency_code;
  v_provider    public.account_provider;
  v_total       integer;
  v_new         integer;
  v_duplicates  integer;
  v_categorized integer;
  v_enriched    integer;
  v_learned     integer := 0;
  v_suggested   integer := 0;
  v_balance     numeric;
  v_name        text := btrim(p_new_account_name);
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' then
    raise exception 'invalid_rows' using errcode = '22023';
  end if;
  v_total := jsonb_array_length(p_rows);
  if v_total = 0 then
    raise exception 'no_rows' using errcode = '22023';
  end if;
  if v_total > 5000 then
    raise exception 'too_many_rows' using errcode = '22023';
  end if;

  if p_account_id is not null then
    select a.id, a.currency, a.provider into v_account_id, v_currency, v_provider
      from public.accounts a
     where a.id = p_account_id and a.user_id = v_uid and a.archived_at is null;
    if not found then
      raise exception 'account_not_found' using errcode = 'P0002';
    end if;
    if v_provider not in ('manual', 'csv') then
      raise exception 'account_not_importable' using errcode = '22023';
    end if;
  else
    if v_name is null or char_length(v_name) not between 1 and 120 then
      raise exception 'invalid_account_name' using errcode = '22023';
    end if;
    begin
      v_currency := coalesce(p_new_account_currency, 'EUR')::public.currency_code;
    exception when others then
      raise exception 'invalid_currency' using errcode = '22023';
    end;
    if not p_dry_run then
      insert into public.accounts (user_id, name, type, provider, currency)
      values (v_uid, v_name, 'checking', 'csv', v_currency)
      returning id into v_account_id;
    end if;
  end if;

  -- Mehrfachaufruf in einer Transaktion (Vorschau + Import, Tests).
  if to_regclass('pg_temp.import_batch') is not null then
    drop table pg_temp.import_batch;
  end if;
  create temporary table import_batch (
    booking_date date, value_date date, amount numeric(14,2), currency public.currency_code,
    counterparty text, purpose text, transaction_type text, counterparty_iban text, description text,
    import_hash text, category_id uuid, rule_id uuid, source public.categorization_source, duplicate boolean,
    existing_id uuid, enrich boolean, existing_uncategorized boolean
  ) on commit drop;

  insert into pg_temp.import_batch
  select r.booking_date, r.value_date, r.amount, r.currency, r.counterparty, r.purpose,
         r.transaction_type, r.counterparty_iban, r.description,
         private.import_hash(r.booking_date, r.amount, r.purpose,
           row_number() over (
             partition by r.booking_date, r.amount, btrim(regexp_replace(lower(coalesce(r.purpose, '')), '\s+', ' ', 'g'))
             order by r.ord)),
         null, null, null, false, null, false, false
    from private.import_rows(p_rows, v_currency) r;

  update pg_temp.import_batch b
     set duplicate = true,
         existing_id = t.id,
         -- Anreichern: vorhandene Buchung (z. B. vor diesen Spalten importiert)
         -- erhält fehlende Felder; vorhandene Werte bleiben unverändert.
         enrich = (t.transaction_type is null and b.transaction_type is not null)
               or (t.counterparty_iban is null and b.counterparty_iban is not null)
               or (t.description is null and b.description is not null),
         existing_uncategorized = t.category_id is null
    from public.transactions t
   where v_account_id is not null
     and t.account_id = v_account_id
     and t.import_hash = b.import_hash;

  -- Schichten: eigene Regeln, Gegenpartei-Gedächtnis, eigene Konten,
  -- Standardregeln – für neue Zeilen und für angereicherte Buchungen ohne
  -- Kategorie (Schicht 1 bleibt).
  update pg_temp.import_batch b
     set category_id = c.category_id, rule_id = c.rule_id, source = c.source
    from pg_temp.import_batch s
    cross join lateral private.classify(v_uid, v_account_id, s.amount, s.counterparty, s.purpose,
                                        s.description, s.transaction_type, s.counterparty_iban,
                                        private.counterparty_key(s.counterparty_iban, s.counterparty, s.purpose)) c
   where s.ctid = b.ctid
     and (not b.duplicate or (b.enrich and b.existing_uncategorized));

  select count(*) filter (where not b.duplicate),
         count(*) filter (where b.duplicate),
         count(*) filter (where b.category_id is not null),
         count(*) filter (where b.enrich)
    into v_new, v_duplicates, v_categorized, v_enriched
    from pg_temp.import_batch b;

  if not p_dry_run then
    insert into public.transactions (
      user_id, account_id, booking_date, value_date, amount, currency,
      counterparty_name, purpose, transaction_type, counterparty_iban, description,
      import_hash, source, category_id, categorization_source, categorization_rule_id,
      auto_category_id, auto_source, auto_rule_id
    )
    select v_uid, v_account_id, b.booking_date, b.value_date, b.amount, b.currency,
           b.counterparty, b.purpose, b.transaction_type, b.counterparty_iban, b.description,
           b.import_hash, 'csv_import', b.category_id, b.source, b.rule_id,
           b.category_id, b.source, b.rule_id
      from pg_temp.import_batch b
     where not b.duplicate
    on conflict (account_id, import_hash) where import_hash is not null do nothing;
    get diagnostics v_new = row_count;

    update public.transactions t
       set transaction_type       = coalesce(t.transaction_type, b.transaction_type),
           counterparty_iban      = coalesce(t.counterparty_iban, b.counterparty_iban),
           description            = coalesce(t.description, b.description),
           category_id            = coalesce(t.category_id, b.category_id),
           categorization_source  = case when t.category_id is null and b.category_id is not null
                                         then b.source
                                         else t.categorization_source end,
           categorization_rule_id = case when t.category_id is null and b.category_id is not null
                                         then b.rule_id
                                         else t.categorization_rule_id end,
           auto_category_id       = case when t.category_id is null and t.auto_category_id is null
                                         then b.category_id else t.auto_category_id end,
           auto_source            = case when t.category_id is null and t.auto_category_id is null
                                         then b.source else t.auto_source end,
           auto_rule_id           = case when t.category_id is null and t.auto_category_id is null
                                         then b.rule_id else t.auto_rule_id end
      from pg_temp.import_batch b
     where b.enrich
       and t.id = b.existing_id
       and t.user_id = v_uid;
    get diagnostics v_enriched = row_count;

    perform private.refresh_recurrence(v_uid);
    -- Schicht 6: Klassifikator für alles, was noch offen ist.
    select b.assigned, b.suggested into v_learned, v_suggested from private.bayes_run(v_uid, true) b;
  end if;

  select a.balance into v_balance from public.accounts a where a.id = v_account_id;

  return jsonb_build_object(
    'account_id',  v_account_id,
    'currency',    v_currency,
    'total',       v_total,
    'new',         v_new,
    'duplicates',  v_duplicates,
    'categorized', v_categorized,
    'enriched',    v_enriched,
    'learned',     v_learned,
    'suggested',   v_suggested,
    'balance',     v_balance,
    'dry_run',     p_dry_run
  );
end;
$$;

create or replace function public.apply_categorization_rules(
  p_rule_id        uuid    default null,
  p_dry_run        boolean default false,
  p_overwrite_auto boolean default false
)
returns integer
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_uid   uuid := auth.uid();
  v_count integer;
  v_bayes record;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  v_count := private.apply_rules_for_user(v_uid, p_rule_id, p_dry_run, p_overwrite_auto);
  -- Alle Regeln anwenden: danach Klassifikator (sichere Treffer, Vorschläge).
  if p_rule_id is null and not p_dry_run then
    select * into v_bayes from private.bayes_run(v_uid, true);
    v_count := v_count + v_bayes.assigned;
  end if;
  return v_count;
end;
$$;

-- ---------------------------------------------------------------------
-- Kennzahlen: Gedächtnis und Klassifikator getrennt, Vorschläge
-- ---------------------------------------------------------------------
create or replace function public.categorization_stats()
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select jsonb_build_object(
    'total',         count(*),
    'manual',        count(*) filter (where t.category_id is not null
                                       and t.categorization_source is distinct from 'rule'
                                       and t.categorization_source is distinct from 'learned'),
    'rule',          count(*) filter (where t.categorization_source = 'rule'
                                       and coalesce(r.origin, 'manual') <> 'standard'),
    'standard',      count(*) filter (where t.categorization_source = 'rule' and r.origin = 'standard'),
    'learned',       count(*) filter (where t.categorization_source = 'learned' and t.categorization_confidence is null),
    'bayes',         count(*) filter (where t.categorization_source = 'learned' and t.categorization_confidence is not null),
    'suggested',     count(*) filter (where t.category_id is null and t.suggested_category_id is not null),
    'uncategorized', count(*) filter (where t.category_id is null)
  )
    from public.transactions t
    left join public.categorization_rules r on r.id = t.categorization_rule_id
   where t.user_id = (select auth.uid());
$$;

create or replace function public.rule_quality(p_min_hits integer default 5, p_max_error numeric default 0.3)
returns table (
  rule_id   uuid,
  pattern   text,
  origin    text,
  is_active boolean,
  hits      integer,
  corrected integer,
  flagged   boolean
)
language sql
stable
security invoker
set search_path = ''
as $$
  with q as (
    select t.auto_rule_id, t.auto_source, t.auto_confidence is not null as by_bayes,
           count(*)::integer as hits,
           count(*) filter (where t.category_id is distinct from t.auto_category_id)::integer as corrected
      from public.transactions t
     where t.user_id = (select auth.uid())
       and t.auto_category_id is not null
     group by t.auto_rule_id, t.auto_source, t.auto_confidence is not null
  )
  select q.auto_rule_id, r.pattern,
         case when q.auto_rule_id is not null then r.origin when q.by_bayes then 'bayes' else 'memory' end,
         coalesce(r.is_active, true), q.hits, q.corrected,
         q.hits >= p_min_hits and q.corrected::numeric / q.hits > p_max_error
    from q
    left join public.categorization_rules r on r.id = q.auto_rule_id
   where q.auto_rule_id is not null or q.auto_source = 'learned'
   order by q.corrected::numeric / q.hits desc, q.hits desc;
$$;

-- ---------------------------------------------------------------------
-- Bestand: Merkmale berechnen, Vorschläge (ohne Zuordnung) erzeugen
-- ---------------------------------------------------------------------
update public.transactions t
   set features = private.bayes_base_features(t.counterparty_name, t.purpose, t.description, t.transaction_type, t.amount);

do $$
declare
  v_user uuid;
begin
  for v_user in select distinct t.user_id from public.transactions t where t.category_id is null loop
    perform private.bayes_run(v_user, false);
  end loop;
end;
$$;

-- ---------------------------------------------------------------------
-- Rechte
-- ---------------------------------------------------------------------
grant execute on function private.bayes_words(text)                                     to authenticated;
grant execute on function private.bayes_base_features(text, text, text, text, numeric)  to authenticated;
grant execute on function private.bayes_features(text[], text, text, numeric, boolean)  to authenticated;
grant execute on function private.bayes_build(uuid, boolean)                            to authenticated;
grant execute on function private.bayes_predict()                                       to authenticated;
grant execute on function private.bayes_run(uuid, boolean)                              to authenticated;

revoke all on function public.refresh_suggestions()                                from public, anon;
revoke all on function public.confirm_suggestions(uuid[])                          from public, anon;
revoke all on function public.save_categorization_settings(numeric, numeric)       from public, anon;
revoke all on function public.bayes_evaluate()                                     from public, anon;
grant execute on function public.refresh_suggestions()                             to authenticated;
grant execute on function public.confirm_suggestions(uuid[])                       to authenticated;
grant execute on function public.save_categorization_settings(numeric, numeric)    to authenticated;
grant execute on function public.bayes_evaluate()                                  to authenticated;

commit;
