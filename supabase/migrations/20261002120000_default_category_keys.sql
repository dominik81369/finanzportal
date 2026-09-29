-- =====================================================================
--  supabase/migrations/20261002120000_default_category_keys.sql
--  Standardkategorien übersetzbar machen
--
--  Die Standardkategorien werden je Nutzer mit deutschen Namen angelegt
--  (private.seed_default_categories). Damit sie auf /en englisch erscheinen,
--  erhalten sie einen stabilen Schlüssel default_key (z. B. 'groceries').
--  Die App zeigt für Kategorien mit Schlüssel die Übersetzung aus
--  messages/*.json (DefaultCategories.<key>), sonst den gespeicherten Namen.
--
--  - Funktioniert für bestehende Konten (Nachtrag unten) und bei späterem
--    Sprachwechsel – anders als ein Anlegen in der Sprache der Registrierung.
--  - Eigene Kategorien haben keinen Schlüssel.
--  - name bleibt der deutsche Name (Suche, Eindeutigkeit, Fallback).
--
--  Zeitstempel bewusst nach 20261002000000 (siehe PR #10).
-- =====================================================================

begin;

alter table public.categories
  add column default_key text
    check (default_key ~ '^[a-z][a-z_]{1,39}$');

comment on column public.categories.default_key is
  'Schlüssel einer Standardkategorie (Übersetzung in der App); NULL bei eigenen Kategorien. '
  'Beim Umbenennen durch den Nutzer auf NULL setzen, damit der neue Name angezeigt wird.';

create unique index categories_user_default_key_key
  on public.categories (user_id, default_key)
  where default_key is not null;

-- Standardkategorien mit Schlüssel anlegen. Signatur und Aufrufer
-- (private.handle_new_user) bleiben unverändert.
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
    (p_user_id, 'Sonstige Ausgaben',    'expense',  '#94a3b8', 'ellipsis',         true, 200, 'other_expenses'),
    (p_user_id, 'Sparen & Investieren', 'transfer', '#0f766e', 'piggy-bank',       true, 300, 'savings_investments'),
    (p_user_id, 'Kredittilgung',        'transfer', '#475569', 'receipt',          true, 310, 'loan_repayment'),
    (p_user_id, 'Umbuchung',            'transfer', '#9ca3af', 'arrow-left-right', true, 320, 'transfer')
  on conflict on constraint categories_name_key do nothing;
end;
$$;

-- Nachtrag für bestehende Konten: nur unveränderte Standardkategorien
-- (is_default, Oberkategorie, Name wie beim Anlegen) erhalten den Schlüssel.
update public.categories c
   set default_key = m.default_key
  from (values
    ('Gehalt & Lohn',        'salary'),
    ('Kapitalerträge',       'investment_income'),
    ('Mieteinnahmen',        'rental_income'),
    ('Sonstige Einnahmen',   'other_income'),
    ('Wohnen',               'housing'),
    ('Lebensmittel',         'groceries'),
    ('Mobilität',            'mobility'),
    ('Versicherungen',       'insurance'),
    ('Gesundheit',           'health'),
    ('Freizeit & Reisen',    'leisure_travel'),
    ('Abos & Medien',        'subscriptions_media'),
    ('Shopping',             'shopping'),
    ('Bildung',              'education'),
    ('Steuern & Abgaben',    'taxes'),
    ('Sonstige Ausgaben',    'other_expenses'),
    ('Sparen & Investieren', 'savings_investments'),
    ('Kredittilgung',        'loan_repayment'),
    ('Umbuchung',            'transfer')
  ) as m (name, default_key)
 where c.is_default
   and c.parent_category_id is null
   and c.name = m.name
   and c.default_key is null;

commit;
