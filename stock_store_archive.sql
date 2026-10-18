-- Склад: «Хранится на Тухачевского 26/4» и удаление (архив) материала.
-- Материал с store_branch_id при продаже на любом филиале списывается с этого филиала (как мастерская).
-- Удаление мягкое: archived=true, материал выключается, нормы гаснут, имя освобождается. История движений остаётся.

alter table public.stock_materials add column if not exists store_branch_id bigint references public.sales_branches(id);
alter table public.stock_materials add column if not exists archived boolean not null default false;

create or replace function public.stock_set_store_branch(p_id bigint, p_branch_id bigint) returns void
language plpgsql security definer set search_path=public as $$
begin
  if not public.is_admin() then raise exception 'Материалы настраивает администратор'; end if;
  update public.stock_materials set store_branch_id=p_branch_id, in_workshop=case when p_branch_id is not null then false else in_workshop end
   where id=p_id or parent_id=p_id;
end $$;
grant execute on function public.stock_set_store_branch(bigint,bigint) to authenticated;

create or replace function public.stock_archive_material(p_id bigint) returns void
language plpgsql security definer set search_path=public as $$
begin
  if not public.is_admin() then raise exception 'Материалы настраивает администратор'; end if;
  update public.stock_norms set active=false where material_id in (select id from public.stock_materials where id=p_id or parent_id=p_id);
  update public.stock_materials set archived=true, is_active=false, name=name||' (удалён №'||id||')'
   where (id=p_id or parent_id=p_id) and not archived;
end $$;
grant execute on function public.stock_archive_material(bigint) to authenticated;

-- Списание по продаже: место хранения материала важнее филиала продажи.
do $do$
declare d text:=pg_get_functiondef('public.stock_redo_item'::regproc);
begin
  d:=replace(d,'branch_id<>coalesce(public.stock_workshop_id(),0) order by id limit 1',
    'branch_id<>coalesce(public.stock_workshop_id(),0) and material_id not in (select id from public.stock_materials where store_branch_id is not null) order by id limit 1');
  d:=replace(d,'case when m.in_workshop then public.stock_workshop_id() else coalesce(v_branch,it.sale_branch) end',
    'case when m.in_workshop then public.stock_workshop_id() when m.store_branch_id is not null then m.store_branch_id else coalesce(v_branch,it.sale_branch) end');
  execute d;
end $do$;

do $do$
declare d text:=pg_get_functiondef('public.stock_sale_extra'::regproc);
begin
  d:=replace(d,'case when m.in_workshop then public.stock_workshop_id() else s.branch_id end',
    'case when m.in_workshop then public.stock_workshop_id() when m.store_branch_id is not null then m.store_branch_id else s.branch_id end');
  execute d;
end $do$;

-- Закупка: такой материал считается только по своему филиалу.
do $do$
declare d text:=pg_get_functiondef('public.stock_purchase_calc'::regproc);
begin
  d:=replace(d,'((not m.in_workshop and b.is_active is not false and not b.is_test and not b.is_workshop)',
    '((not m.in_workshop and b.is_active is not false and not b.is_test and not b.is_workshop and (m.store_branch_id is null or m.store_branch_id=b.id))');
  execute d;
end $do$;

do $do$
declare d text:=pg_get_functiondef('public.stock_state'::regproc);
begin
  d:=replace(d,'''in_workshop'',m.in_workshop,','''in_workshop'',m.in_workshop,''store_branch_id'',m.store_branch_id,''archived'',m.archived,');
  execute d;
end $do$;

-- Варианты (размеры/цвета) наследуют место хранения.
do $do$
declare d text:=pg_get_functiondef('public.stock_set_variants'::regproc);
begin
  d:=replace(d,'in_workshop=p.in_workshop,','in_workshop=p.in_workshop, store_branch_id=p.store_branch_id,');
  execute d;
end $do$;
