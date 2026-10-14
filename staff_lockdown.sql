-- Вход сотрудников. Шаг 2 из 2: закрываем доступ без входа.
-- Применять ТОЛЬКО после того, как: сайт с входом выложен, у всех сотрудников есть логины,
-- и в config.js включён STAFF_LOGIN_REQUIRED = true. Иначе касса без входа перестанет работать.

set lock_timeout = '5s';

-- 1. Политики, открытые для anon/public: теперь только для вошедших активных сотрудников.
do $$
declare p record; q text;
begin
  for p in select * from pg_policies
    where schemaname = 'public' and ('anon' = any(roles) or 'public' = any(roles))
  loop
    q := format('alter policy %I on public.%I to authenticated', p.policyname, p.tablename);
    if p.qual is not null then q := q || format(' using ((%s) and public.is_staff())', p.qual); end if;
    if p.with_check is not null then q := q || format(' with check ((%s) and public.is_staff())', p.with_check); end if;
    if p.qual is null and p.with_check is null then
      if p.cmd = 'INSERT' then q := q || ' with check (public.is_staff())'; else q := q || ' using (public.is_staff())'; end if;
    end if;
    execute q;
  end loop;
end $$;

-- 2. Функции public: только для вошедших.
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.prokind = 'f'
  loop
    execute format('revoke execute on function %s from public, anon', f.sig);
    execute format('grant execute on function %s to authenticated', f.sig);
  end loop;
end $$;
alter default privileges in schema public revoke execute on functions from public, anon;

-- 3. Любой запрос к базе через API — только от активного сотрудника (или сервисных функций).
-- Закрывает и функции SECURITY DEFINER, и случай, когда кто-то сам зарегистрировался в Supabase Auth.
create or replace function public.staff_request_guard() returns void
language plpgsql stable security definer set search_path = '' as $$
declare r text := coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role', current_user);
begin
  if r in ('service_role', 'supabase_admin', 'postgres') then return; end if;
  if r = 'authenticated' and public.is_staff() then return; end if;
  raise sqlstate 'PT401' using message = 'Требуется вход сотрудника';
end $$;
grant execute on function public.staff_request_guard() to anon, authenticated;
alter role authenticator set pgrst.db_pre_request = 'public.staff_request_guard';
notify pgrst, 'reload config';
