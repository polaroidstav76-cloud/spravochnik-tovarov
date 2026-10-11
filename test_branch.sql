-- Тестовый филиал. Применено в Supabase 2026-10-11.
-- Филиал с is_test=true нужен, чтобы проверять товары и продажи. Его продажи, возвраты и смены не попадают
-- в сводку, сравнение филиалов, отчёты, зарплату; продажи на нём не списывают материал со склада и не идут в закупку.
-- На сайте фильтр — isTestBranch() / reportBranchList() в index.html.

alter table public.sales_branches add column if not exists is_test boolean not null default false;
update public.sales_branches set is_test=true where lower(trim(name))='тестовый';

create or replace function public.is_test_branch(p_id bigint) returns boolean
language sql stable security definer set search_path to 'public' as $fn$
  select coalesce((select is_test from public.sales_branches where id=p_id),false)
$fn$;

-- Сводка: продажи, возвраты, смены, контроль наличных, заказы «при получении» и долги без тестового филиала.
do $do$
declare d text:=pg_get_functiondef('public.admin_period_summary'::regproc);
begin
  d:=replace(d,'(p_branch_id is null or x.branch_id=p_branch_id)','(p_branch_id is null or x.branch_id=p_branch_id) and not public.is_test_branch(x.branch_id)');
  d:=replace(d,'(p_branch_id is null or r.branch_id=p_branch_id)','(p_branch_id is null or r.branch_id=p_branch_id) and not public.is_test_branch(r.branch_id)');
  d:=replace(d,'(p_branch_id is null or branch_id=p_branch_id))','(p_branch_id is null or branch_id=p_branch_id) and not public.is_test_branch(branch_id))');
  d:=replace(d,'where d.paid_at is null and x.status=''completed''','where d.paid_at is null and x.status=''completed'' and not public.is_test_branch(x.branch_id)');
  execute d;
end $do$;

-- Склад: продажа на тестовом филиале материал не списывает.
do $do$
declare d text:=pg_get_functiondef('public.stock_redo_item'::regproc);
begin
  d:=replace(d,'or it.catalog_id is null then return;','or it.catalog_id is null or public.is_test_branch(coalesce(v_branch,it.sale_branch)) then return;');
  execute d;
end $do$;

-- Закупка: тестовый филиал не считается.
do $do$
declare d text:=pg_get_functiondef('public.stock_purchase_calc'::regproc);
begin
  d:=replace(d,'where m.is_active and b.is_active is not false','where m.is_active and b.is_active is not false and not b.is_test');
  execute d;
end $do$;
