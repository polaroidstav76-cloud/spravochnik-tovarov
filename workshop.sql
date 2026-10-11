-- Мастерская: отдельное место хранения (не филиал). Применено в Supabase 2026-10-11.
-- В базе это строка sales_branches с is_workshop=true и is_active=false, поэтому в кассе, сменах и отчётах её нет.
-- Материал с in_workshop=true (кружки, сувениры) при продаже на любом филиале списывается с мастерской,
-- и перенос «кто выполнил заказ» его не трогает. В закупке такой материал считается только по мастерской.
-- Операции по мастерской может делать администратор и любой сотрудник открытой смены.

alter table public.sales_branches add column if not exists is_workshop boolean not null default false;
insert into public.sales_branches(name,is_active,is_workshop)
  select 'Мастерская',false,true where not exists(select 1 from public.sales_branches where is_workshop);
alter table public.stock_materials add column if not exists in_workshop boolean not null default false;

create or replace function public.stock_workshop_id() returns bigint
language sql stable security definer set search_path to 'public' as $fn$
  select id from public.sales_branches where is_workshop order by id limit 1
$fn$;

create or replace function public.stock_set_in_workshop(p_id bigint, p_on boolean) returns void
language plpgsql security definer set search_path to 'public' as $fn$
begin
  if coalesce(auth.role(),'')<>'authenticated' then raise exception 'Материалы настраивает администратор'; end if;
  update public.stock_materials set in_workshop=coalesce(p_on,false) where id=p_id;
end $fn$;
grant execute on function public.stock_set_in_workshop(bigint,boolean) to authenticated;

-- Списание по продаже: материал мастерской — с мастерской, остальное — с филиала (как раньше).
do $do$
declare d text:=pg_get_functiondef('public.stock_redo_item'::regproc);
begin
  d:=replace(d,'kind=''sale'' and cancelled_at is null order by id limit 1','kind=''sale'' and cancelled_at is null and branch_id<>coalesce(public.stock_workshop_id(),0) order by id limit 1');
  d:=replace(d,'public.is_test_branch(coalesce(v_branch,it.sale_branch))','public.is_test_branch(coalesce(v_branch,it.sale_branch)) or public.is_test_branch(it.sale_branch)');
  d:=replace(d,'select n.material_id, coalesce(v_branch,it.sale_branch),','select n.material_id, case when m.in_workshop then public.stock_workshop_id() else coalesce(v_branch,it.sale_branch) end,');
  d:=replace(d,'from public.stock_norms n where','from public.stock_norms n join public.stock_materials m on m.id=n.material_id where');
  execute d;
end $do$;

-- «Кто выполнил заказ» не переносит списание с мастерской.
do $do$
declare d text:=pg_get_functiondef('public.stock_set_producer'::regproc);
begin
  d:=replace(d,'where kind=''sale'' and cancelled_at is null and ((p_sale_item_id','where kind=''sale'' and cancelled_at is null and branch_id<>coalesce(public.stock_workshop_id(),0) and ((p_sale_item_id');
  execute d;
end $do$;

-- Сотрудник смены может работать и со своим филиалом, и с мастерской.
do $do$
declare d text:=pg_get_functiondef('public.stock_operation'::regproc);
begin
  d:=replace(d,'if not a.is_admin and a.branch_id not in (p_branch_id,p_to_branch_id) then','if not a.is_admin and a.branch_id not in (p_branch_id,p_to_branch_id) and coalesce(public.stock_workshop_id(),0) not in (p_branch_id,p_to_branch_id) then');
  d:=replace(d,'elsif not a.is_admin and a.branch_id<>p_branch_id then','elsif not a.is_admin and a.branch_id<>p_branch_id and p_branch_id<>coalesce(public.stock_workshop_id(),0) then');
  execute d;
end $do$;

-- Закупка: материал мастерской считается только по мастерской, остальные — по рабочим филиалам.
do $do$
declare d text:=pg_get_functiondef('public.stock_purchase_calc'::regproc);
begin
  d:=replace(d,'where m.is_active and b.is_active is not false and not b.is_test',
    'where m.is_active and ((not m.in_workshop and b.is_active is not false and not b.is_test and not b.is_workshop) or (m.in_workshop and b.is_workshop))');
  execute d;
end $do$;

-- Остатки: у материала in_workshop, плюс сама мастерская.
do $do$
declare d text:=pg_get_functiondef('public.stock_state'::regproc);
begin
  d:=replace(d,'''purchase_code'',m.purchase_code,','''purchase_code'',m.purchase_code,''in_workshop'',m.in_workshop,');
  d:=replace(d,'select jsonb_build_object(','select jsonb_build_object(''workshop'',(select jsonb_build_object(''id'',id,''name'',name) from public.sales_branches where is_workshop order by id limit 1),');
  execute d;
end $do$;
