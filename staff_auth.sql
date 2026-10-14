-- Вход сотрудников по логину и паролю. Шаг 1 из 2: роли (применено до выкладки сайта).
-- Ничего не ломает: сотрудники пока работают как раньше, админ входит как раньше.
-- Шаг 2 (staff_lockdown.sql) закрывает доступ без входа после того, как у сотрудников появятся логины.

set lock_timeout = '5s';

create table if not exists public.staff_accounts (
  user_id uuid primary key references auth.users(id) on delete cascade,
  login text not null unique check (login ~ '^[a-z0-9._-]{3,40}$' or login like '%@%'),
  name text not null,
  role text not null default 'staff' check (role in ('admin','staff')),
  person_id bigint references public.sales_people(id) on delete set null,
  active boolean not null default true,
  created_at timestamptz not null default now()
);
alter table public.staff_accounts enable row level security;

create or replace function public.is_staff() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists(select 1 from public.staff_accounts s where s.user_id = auth.uid() and s.active);
$$;
create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists(select 1 from public.staff_accounts s where s.user_id = auth.uid() and s.active and s.role = 'admin');
$$;
revoke execute on function public.is_staff(), public.is_admin() from public, anon;
grant execute on function public.is_staff(), public.is_admin() to authenticated;

drop policy if exists staff_accounts_read on public.staff_accounts;
create policy staff_accounts_read on public.staff_accounts for select to authenticated
  using (user_id = auth.uid() or public.is_admin());
-- Изменения учёток только через функцию staff-admin (service role).

-- Текущий единственный пользователь Supabase Auth — администратор.
insert into public.staff_accounts(user_id, login, name, role)
select id, lower(email), 'Администратор', 'admin' from auth.users
where email = 'polaroid.stav76@gmail.com'
on conflict (user_id) do nothing;

-- Политики «только для вошедших» раньше пускали любого вошедшего, теперь только администратора.
do $$
declare p record; q text;
begin
  for p in select * from pg_policies
    where schemaname = 'public' and roles = '{authenticated}' and tablename <> 'staff_accounts'
  loop
    q := format('alter policy %I on public.%I', p.policyname, p.tablename);
    if p.qual is not null then q := q || format(' using ((%s) and public.is_admin())', p.qual); end if;
    if p.with_check is not null then q := q || format(' with check ((%s) and public.is_admin())', p.with_check); end if;
    if p.qual is null and p.with_check is null then
      if p.cmd = 'INSERT' then q := q || ' with check (public.is_admin())'; else q := q || ' using (public.is_admin())'; end if;
    end if;
    execute q;
  end loop;
end $$;

-- Сотрудник, вошедший по логину, должен видеть опубликованный график, как раньше без входа.
alter policy schedule_cells_read_published on public.schedule_cells to anon, authenticated;

-- Картинки товаров меняет только администратор.
do $$
declare p record; q text;
begin
  for p in select * from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname like 'images_admin_%' loop
    q := format('alter policy %I on storage.objects', p.policyname);
    if p.qual is not null then q := q || format(' using ((%s) and public.is_admin())', p.qual); end if;
    if p.with_check is not null then q := q || format(' with check ((%s) and public.is_admin())', p.with_check); end if;
    if p.qual is null and p.with_check is null then q := q || ' with check (public.is_admin())'; end if;
    execute q;
  end loop;
exception when insufficient_privilege then
  raise notice 'Политики storage не изменены: нет прав (%)', sqlerrm;
end $$;

-- Функции, где «администратор» определялся как «любой вошедший».
do $$
declare f record; d text;
begin
  for f in select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.prosrc ~ 'auth\.(uid|role)\(\)' and p.proname not in ('is_staff','is_admin')
  loop
    d := pg_get_functiondef(f.oid);
    d := replace(d, $r$coalesce(auth.role(),'')<>'authenticated'$r$, 'not public.is_admin()');
    d := replace(d, $r$coalesce(auth.role(),'')='authenticated'$r$, 'public.is_admin()');
    d := replace(d, $r$auth.role() <> 'authenticated'$r$, 'not public.is_admin()');
    d := replace(d, 'auth.uid() is null', 'not public.is_admin()');
    if d ~ 'auth\.(uid|role)\(\)' then raise exception 'Не переписана функция: %', f.oid::regprocedure; end if;
    execute d;
  end loop;
end $$;

-- Поиск клиента только по 4+ цифрам (раньше пустой запрос отдавал всех клиентов).
do $$
declare d text;
begin
  d := pg_get_functiondef('public.loyalty_find_customers(text)'::regprocedure);
  d := replace(d, $r$where c.phone like$r$,
    $r$where length(regexp_replace(coalesce(p_query,''),'[^0-9]','','g')) >= 4 and c.phone like$r$);
  if d !~ '>= 4 and c.phone like' then raise exception 'loyalty_find_customers: шаблон не найден'; end if;
  execute d;
end $$;
