-- Упрощённый склад (2026-10-12, по просьбе Рустама). Применено в Supabase.
-- 1) stock_materials.no_track — «Не учитывать расход»: материал не списывается с продаж (ни по нормам, ни «на каждую продажу»)
--    и не попадает в автоматический расчёт закупки. Его заказывают вручную заявкой. Включено для пакетов для фото и чековой ленты.
-- 2) stock_requests — заявки «Нужно купить» от сотрудников и администратора: позиция прайса, материал или свой текст.
-- 3) Закупка в реальном времени: stock_purchase_live() считает список при каждом открытии; еженедельная задача cron выключена.
--    «Нет в магазине» прячет строку расчёта (stock_purchase_hide) или заявку, вернуть можно из «Скрытых».
--    «Куплено» у строки расчёта записывает приход на филиалы (делает сайт через stock_operation), у заявки — закрывает её.

alter table public.stock_materials add column if not exists no_track boolean not null default false;
update public.stock_materials set no_track=true where name like 'Пакет для фото %' or name='Чековая лента';

create or replace function public.stock_set_no_track(p_id bigint, p_on boolean) returns void
language plpgsql security definer set search_path to 'public' as $fn$
begin
  if coalesce(auth.role(),'')<>'authenticated' then raise exception 'Материалы настраивает администратор'; end if;
  update public.stock_materials set no_track=coalesce(p_on,false) where id=p_id;
end $fn$;
revoke execute on function public.stock_set_no_track(bigint,boolean) from public, anon;
grant execute on function public.stock_set_no_track(bigint,boolean) to authenticated;

do $do$
declare d text;
begin
  d:=pg_get_functiondef('public.stock_redo_item'::regproc);
  d:=replace(d,'where n.catalog_id=it.catalog_id and n.active','where n.catalog_id=it.catalog_id and n.active and not m.no_track');
  execute d;
  d:=pg_get_functiondef('public.stock_sale_extra'::regproc);
  d:=replace(d,'where m.is_active and m.per_sale_qty>0','where m.is_active and not m.no_track and m.per_sale_qty>0');
  execute d;
  d:=pg_get_functiondef('public.stock_purchase_calc'::regproc);
  d:=replace(d,'where m.is_active and ((not m.in_workshop','where m.is_active and not m.no_track and ((not m.in_workshop');
  execute d;
  d:=pg_get_functiondef('public.stock_state'::regproc);
  d:=replace(d,'''is_active'',m.is_active,','''is_active'',m.is_active,''no_track'',m.no_track,');
  execute d;
end $do$;

create table if not exists public.stock_requests(
  id bigserial primary key,
  branch_id bigint references public.sales_branches(id),
  person_name text,
  catalog_id bigint,
  material_id bigint references public.stock_materials(id),
  name text not null,
  qty numeric,
  comment text,
  status text not null default 'open' check (status in ('open','bought','unavailable')),
  created_at timestamptz not null default now(),
  closed_at timestamptz
);
alter table public.stock_requests enable row level security;
create policy stock_requests_read on public.stock_requests for select to anon, authenticated using (true);

create table if not exists public.stock_purchase_hide(
  material_id bigint primary key references public.stock_materials(id),
  hidden boolean not null default true,
  at timestamptz not null default now()
);
alter table public.stock_purchase_hide enable row level security;
create policy stock_purchase_hide_read on public.stock_purchase_hide for select to anon, authenticated using (true);

-- Заявка «Нужно купить». Сотрудник — на свой филиал (или мастерскую), администратор — на любой.
create or replace function public.stock_request_add(p_shift_id bigint, p_person_id bigint, p_branch_id bigint, p_name text, p_qty numeric,
  p_catalog_id bigint default null, p_material_id bigint default null, p_comment text default null) returns bigint
language plpgsql security definer set search_path to 'public' as $fn$
declare a record; v_b bigint:=p_branch_id; v_id bigint;
begin
  select * into a from public.stock_actor(p_shift_id,p_person_id);
  if nullif(trim(coalesce(p_name,'')),'') is null then raise exception 'Напишите, что нужно купить'; end if;
  if not a.is_admin then
    if v_b is null or (v_b<>a.branch_id and v_b is distinct from public.stock_workshop_id()) then v_b:=a.branch_id; end if;
  end if;
  insert into public.stock_requests(branch_id,person_name,catalog_id,material_id,name,qty,comment)
  values(v_b,a.person_name,p_catalog_id,p_material_id,trim(p_name),nullif(p_qty,0),nullif(trim(coalesce(p_comment,'')),''))
  returning id into v_id;
  return v_id;
end $fn$;
grant execute on function public.stock_request_add(bigint,bigint,bigint,text,numeric,bigint,bigint,text) to anon, authenticated;

-- Куплено / нет в магазине / вернуть в список. Только администратор.
create or replace function public.stock_request_set(p_id bigint, p_status text) returns void
language plpgsql security definer set search_path to 'public' as $fn$
begin
  if coalesce(auth.role(),'')<>'authenticated' then raise exception 'Закупку отмечает администратор'; end if;
  if p_status not in ('open','bought','unavailable') then raise exception 'Неизвестный статус'; end if;
  update public.stock_requests set status=p_status, closed_at=case when p_status='open' then null else now() end where id=p_id;
end $fn$;
revoke execute on function public.stock_request_set(bigint,text) from public, anon;
grant execute on function public.stock_request_set(bigint,text) to authenticated;

create or replace function public.stock_purchase_hide_set(p_material_id bigint, p_hidden boolean) returns void
language plpgsql security definer set search_path to 'public' as $fn$
begin
  if coalesce(auth.role(),'')<>'authenticated' then raise exception 'Закупку отмечает администратор'; end if;
  insert into public.stock_purchase_hide(material_id,hidden,at) values(p_material_id,coalesce(p_hidden,true),now())
  on conflict (material_id) do update set hidden=excluded.hidden, at=excluded.at;
end $fn$;
revoke execute on function public.stock_purchase_hide_set(bigint,boolean) from public, anon;
grant execute on function public.stock_purchase_hide_set(bigint,boolean) to authenticated;

-- Список закупки сейчас: rows — расчёт по расходу (без спрятанных), hidden — спрятанные строки расчёта,
-- requests — открытые и «нет в магазине» заявки.
create or replace function public.stock_purchase_live() returns jsonb
language sql stable security definer set search_path to 'public' as $fn$
  with c as (select x from jsonb_array_elements(public.stock_purchase_calc()) x),
  h as (select material_id from public.stock_purchase_hide where hidden)
  select jsonb_build_object('at',now(),
    'rows',(select coalesce(jsonb_agg(x),'[]') from c where (x->>'material_id')::bigint not in (select material_id from h)),
    'hidden',(select coalesce(jsonb_agg(x),'[]') from c where (x->>'material_id')::bigint in (select material_id from h)),
    'requests',(select coalesce(jsonb_agg(jsonb_build_object('id',r.id,'branch_id',r.branch_id,'person_name',r.person_name,'catalog_id',r.catalog_id,
        'material_id',r.material_id,'name',r.name,'qty',r.qty,'comment',r.comment,'status',r.status,'created_at',r.created_at,
        'unit',m.unit,'code',m.purchase_code) order by r.created_at),'[]')
      from public.stock_requests r left join public.stock_materials m on m.id=r.material_id where r.status in ('open','unavailable')));
$fn$;
grant execute on function public.stock_purchase_live() to anon, authenticated;

-- Еженедельную таблицу временно выключаем (задача остаётся, её можно включить обратно: active:=true).
select cron.alter_job(jobid, active:=false) from cron.job where jobname='stock-purchase';
