-- Размер нашей футболки при продаже. Применено в Supabase 2026-10-12.
-- Материал склада можно привязать к позиции кассы как «вариант» (stock_materials.variant_catalog_id).
-- Если у позиции есть варианты, в кассе сотрудник выбирает один из них (размер и цвет),
-- выбор пишется в sale_items.variant_material_id, и при продаже списывается 1 шт. выбранного материала
-- на каждую единицу позиции (материал мастерской — с мастерской). Удаление продажи возвращает остаток, как и раньше.
-- Новый размер/цвет администратор добавляет сам: материал + «Вариант для позиции кассы» в «Материалы и нормы».

alter table public.stock_materials add column if not exists variant_catalog_id bigint references public.sales_catalog(id);
alter table public.sale_items add column if not exists variant_material_id bigint references public.stock_materials(id);

create or replace function public.stock_set_variant(p_id bigint, p_catalog_id bigint) returns void
language plpgsql security definer set search_path to 'public' as $fn$
begin
  if coalesce(auth.role(),'')<>'authenticated' then raise exception 'Материалы настраивает администратор'; end if;
  update public.stock_materials set variant_catalog_id=p_catalog_id where id=p_id;
end $fn$;
grant execute on function public.stock_set_variant(bigint,bigint) to authenticated;

-- Списание выбранного варианта: по 1 шт. на единицу позиции.
do $do$
declare d text:=pg_get_functiondef('public.stock_redo_item'::regproc); o text;
begin
  o:=d;
  d:=replace(d,'where n.catalog_id=it.catalog_id and n.active and coalesce(it.quantity,0)<>0;',
    'where n.catalog_id=it.catalog_id and n.active and coalesce(it.quantity,0)<>0;
  insert into public.stock_moves(material_id,branch_id,qty,kind,sale_id,sale_item_id,created_at)
  select m.id, case when m.in_workshop then public.stock_workshop_id() else coalesce(v_branch,it.sale_branch) end, -it.quantity, ''sale'', it.sale_id, it.id, coalesce(it.sale_at,now())
  from public.stock_materials m where m.id=it.variant_material_id and coalesce(it.quantity,0)<>0;');
  if d=o then raise exception 'stock_redo_item: шаблон не найден'; end if;
  execute d;
end $do$;

create or replace trigger stock_sale_item after insert or update of quantity, catalog_id, variant_material_id on public.sale_items
  for each row execute function public.stock_trg_sale_item();

-- Продажа сохраняет выбранный вариант.
do $do$
declare d text:=pg_get_functiondef('public.sales_create_sale'::regproc); o text;
begin
  o:=d;
  d:=replace(d,'insert into public.sale_items(sale_id,catalog_id,item_type,item_name,quantity,unit_price,line_total,cost_price,cost_total)
    values(v_sale_id,v_catalog.id,v_catalog.item_type,v_catalog.name,v_qty,v_price,v_line,v_catalog.cost_price,round(coalesce(v_catalog.cost_price,0)*v_qty,2));',
    'insert into public.sale_items(sale_id,catalog_id,item_type,item_name,quantity,unit_price,line_total,cost_price,cost_total,variant_material_id)
    values(v_sale_id,v_catalog.id,v_catalog.item_type,v_catalog.name,v_qty,v_price,v_line,v_catalog.cost_price,round(coalesce(v_catalog.cost_price,0)*v_qty,2),
      (select m.id from public.stock_materials m where m.id=nullif(v_item->>''variant_material_id'','''')::bigint and m.variant_catalog_id=v_catalog.id));');
  if d=o then raise exception 'sales_create_sale: шаблон не найден'; end if;
  execute d;
end $do$;

-- Отложенный заказ (самовывоз) тоже помнит вариант.
do $do$
declare d text:=pg_get_functiondef('public.sales_hold_pickup'::regproc); o text;
begin
  o:=d;
  d:=replace(d,'''unit_price'',v_price,''line_total'',v_line)',
    '''unit_price'',v_price,''line_total'',v_line,''variant_material_id'',v_item->''variant_material_id'')');
  if d=o then raise exception 'sales_hold_pickup: шаблон не найден'; end if;
  execute d;
end $do$;

-- Склад отдаёт привязку варианта.
do $do$
declare d text:=pg_get_functiondef('public.stock_state'::regproc); o text;
begin
  o:=d;
  d:=replace(d,'''is_active'',m.is_active,','''is_active'',m.is_active,''variant_catalog_id'',m.variant_catalog_id,');
  if d=o then raise exception 'stock_state: шаблон не найден'; end if;
  execute d;
end $do$;

-- Наши футболки: белые и чёрные S–XXL, хранятся в мастерской, вариант позиции «Футболка с принтом».
insert into public.stock_materials(name,unit,min_qty,is_active,in_workshop,variant_catalog_id)
select 'Футболка наша '||c||' '||s,'шт',0,true,true,
  (select id from public.sales_catalog where name like 'Футболка  с принтом%' order by id limit 1)
from unnest(array['белая','чёрная']) with ordinality cc(c,ci), unnest(array['S','M','L','XL','XXL']) with ordinality ss(s,si)
where not exists(select 1 from public.stock_materials x where x.name='Футболка наша '||c||' '||s)
order by ci,si;
