-- =====================================================================
--  supabase/migrations/20260928000000_profiles_password_set_at.sql
--  Phase 2 · Onboarding: Hat der Nutzer selbst ein Passwort festgelegt?
--
--  Per auth.admin.inviteUserByEmail() angelegte Konten müssen nach der
--  Annahme der Einladung ein Passwort festlegen (app/set-password). Bereits
--  registrierte Konten überspringen diesen Schritt.
--
--  auth.users.encrypted_password taugt dafür NICHT: GoTrue legt auch für
--  eingeladene Konten einen zufälligen bcrypt-Hash an. user.identities ebenso
--  wenig (auch eingeladene Konten haben eine "email"-Identity).
--
--  profiles.password_set_at wird ausschließlich per Trigger gepflegt:
--    - beim Anlegen des Profils: gesetzt (Registrierung mit Passwort)
--    - wenn GoTrue das Konto als eingeladen markiert: NULL
--    - bei jeder Änderung von auth.users.encrypted_password (updateUser,
--      Passwort-Reset): auf now()
--  authenticated erhält keinen Spalten-Grant – der Wert ist nicht fälschbar.
-- =====================================================================

begin;

alter table public.profiles
  add column password_set_at timestamptz;

comment on column public.profiles.password_set_at is
  'Zeitpunkt, zu dem der Nutzer sein Passwort festgelegt hat. NULL bei per Einladung angelegten Konten bis /set-password. Nur per Trigger gepflegt.';

-- 1. Beim Anlegen des Profils: Passwort vorhanden ------------------------
--    Selbst registrierte Konten haben ab dem INSERT ein Passwort. Der Wert
--    kommt nie vom Client, sondern immer von diesem Trigger.
create or replace function private.profiles_init_password_set_at()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  select case when u.invited_at is null then now() end
    into new.password_set_at
  from auth.users u
  where u.id = new.user_id;

  return new;
end;
$$;

create trigger init_password_set_at before insert on public.profiles
  for each row execute function private.profiles_init_password_set_at();

-- 2. Spätere Änderungen in auth.users --------------------------------------
--    GoTrue legt eingeladene Konten erst per INSERT an und setzt invited_at
--    danach per UPDATE – deshalb wird die Einladung hier erkannt:
--    - invited_at erstmals gesetzt → noch kein eigenes Passwort (NULL)
--    - encrypted_password geändert, E-Mail bereits bestätigt → Passwort
--      festgelegt (now()): updateUser({ password }), Passwort-Reset
--    Beim Einlösen des Einladungslinks tauscht GoTrue den (zufälligen) Hash
--    ebenfalls aus – aber noch VOR email_confirmed_at. Diese Änderung zählt
--    daher nicht. Eine Einladung an bestätigte Konten lehnt GoTrue ab
--    (email_exists); invited_at ändert sich also nie bei Konten mit eigenem
--    Passwort.
create or replace function private.handle_auth_user_password_state()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if old.invited_at is null and new.invited_at is not null then
    update public.profiles set password_set_at = null where user_id = new.id;
  elsif old.encrypted_password is distinct from new.encrypted_password
        and old.email_confirmed_at is not null then
    update public.profiles set password_set_at = now() where user_id = new.id;
  end if;

  return new;
end;
$$;

create trigger on_auth_user_password_state
  after update of invited_at, encrypted_password on auth.users
  for each row
  execute function private.handle_auth_user_password_state();

revoke all on function private.profiles_init_password_set_at()   from public, anon, authenticated;
revoke all on function private.handle_auth_user_password_state() from public, anon, authenticated;

-- 3. Bestehende Konten: selbst registrierte haben ein Passwort -----------
update public.profiles p
   set password_set_at = u.created_at
  from auth.users u
 where u.id = p.user_id
   and u.invited_at is null;

commit;
