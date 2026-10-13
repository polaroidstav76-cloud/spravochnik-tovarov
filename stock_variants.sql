-- Размеры и цвета у материала (2026-10-13, по просьбе Рустама). Применено в Supabase.
-- У материала-«родителя» два списка: var_sizes и var_colors. Для каждого сочетания есть дочерний материал
-- (parent_id, var_size, var_color, название «Родитель цвет размер»), остаток ведётся по нему.
-- Родитель сам остатка не имеет: его нормы — это позиции прайса, где кассир выбирает размер и цвет,
-- и списывается выбранный дочерний материал (норма × количество). Цена от выбора не зависит.
-- Дочерние материалы наследуют единицу, упаковку, цену, код, минимум, мастерскую и «не учитывать расход».
-- Убранное из списков сочетание не удаляется, а скрывается (is_active=false), история остаётся.

alter table public.stock_materials add column if not exists parent_id bigint references public.stock_materials(id);
alter table public.stock_materials add column if not exists var_size text;
alter table public.stock_materials add column if not exists var_color text;
alter table public.stock_materials add column if not exists var_sizes text[] not null default '{}';
alter table public.stock_materials add column if not exists var_colors text[] not null default '{}';

create or replace function public.stock_set_variants(p_id bigint, p_sizes text[], p_colors text[]) returns void
language plpgsql security definer set search_path to 'public' as $fn$
declare p record; v_s text[]; v_c text[]; s text; c text; v_name text; v_child bigint; v_keep bigint[]:='{}';
begin
  if coalesce(auth.role(),'')<>'authenticated' then raise exception 'Материалы настраивает администратор'; end if;
  select coalesce(array_agg(x order by o),'{}') into v_s from (select distinct on (trim(x)) trim(x) x, o from unnest(coalesce(p_sizes,'{}')) with ordinality u(x,o) where trim(x)<>'' order by trim(x),o) q;
  select coalesce(array_agg(x order by o),'{}') into v_c from (select distinct on (trim(x)) trim(x) x, o from unnest(coalesce(p_colors,'{}')) with ordinality u(x,o) where trim(x)<>'' order by trim(x),o) q;
  update public.stock_materials set var_sizes=v_s, var_colors=v_c, variant_catalog_id=case when cardinality(v_s)+cardinality(v_c)>0 then null else variant_catalog_id end where id=p_id;
  select * into p from public.stock_materials where id=p_id;
  if cardinality(v_s)+cardinality(v_c)>0 then
    foreach c in array (case when cardinality(v_c)>0 then v_c else array[null::text] end) loop
      foreach s in array (case when cardinality(v_s)>0 then v_s else array[null::text] end) loop
        v_name:=trim(p.name||coalesce(' '||c,'')||coalesce(' '||s,''));
        select id into v_child from public.stock_materials where parent_id=p_id and var_size is not distinct from s and var_color is not distinct from c order by id limit 1;
        if v_child is null then
          select id into v_child from public.stock_materials where name=v_name and id<>p_id and (parent_id is null or parent_id=p_id) order by id limit 1;
        end if;
        if v_child is null then
          insert into public.stock_materials(name,unit,min_qty,is_active) values(v_name,p.unit,p.min_qty,true) returning id into v_child;
        end if;
        update public.stock_materials set parent_id=p_id, var_size=s, var_color=c, name=v_name, unit=p.unit, min_qty=p.min_qty, is_active=p.is_active,
          in_workshop=p.in_workshop, no_track=p.no_track, pack_qty=p.pack_qty, pack_price=p.pack_price, purchase_code=p.purchase_code,
          variant_catalog_id=null, var_sizes='{}', var_colors='{}'
        where id=v_child;
        v_keep:=v_keep||v_child;
      end loop;
    end loop;
  end if;
  update public.stock_materials set is_active=false where parent_id=p_id and not (id=any(v_keep));
end $fn$;
revoke execute on function public.stock_set_variants(bigint,text[],text[]) from public, anon;
grant execute on function public.stock_set_variants(bigint,text[],text[]) to authenticated;

do $do$
declare d text; o text;
begin
  -- Родитель с размерами/цветами сам не списывается; выбранный вариант списывается по норме родителя × количество.
  d:=pg_get_functiondef('public.stock_redo_item'::regproc); o:=d;
  d:=replace(d,'where n.catalog_id=it.catalog_id and n.active and not m.no_track','where n.catalog_id=it.catalog_id and n.active and not m.no_track and cardinality(m.var_sizes)+cardinality(m.var_colors)=0');
  d:=replace(d,'-it.quantity, ''sale''','-it.quantity*coalesce((select n.qty from public.stock_norms n where n.material_id=m.parent_id and n.catalog_id=it.catalog_id and n.active limit 1),1), ''sale''');
  if d=o then raise exception 'stock_redo_item: шаблон не найден'; end if;
  execute d;
  -- Касса принимает вариант, если он дочерний у материала с нормой на эту позицию.
  d:=pg_get_functiondef('public.sales_create_sale'::regproc); o:=d;
  d:=replace(d,'and m.variant_catalog_id=v_catalog.id)','and (m.variant_catalog_id=v_catalog.id or exists(select 1 from public.stock_norms n where n.material_id=m.parent_id and n.catalog_id=v_catalog.id and n.active)))');
  if d=o then raise exception 'sales_create_sale: шаблон не найден'; end if;
  execute d;
  -- Закупка считает дочерние варианты, а не родителя.
  d:=pg_get_functiondef('public.stock_purchase_calc'::regproc); o:=d;
  d:=replace(d,'where m.is_active and not m.no_track and','where m.is_active and not m.no_track and cardinality(m.var_sizes)+cardinality(m.var_colors)=0 and');
  if d=o then raise exception 'stock_purchase_calc: шаблон не найден'; end if;
  execute d;
  d:=pg_get_functiondef('public.stock_state'::regproc); o:=d;
  d:=replace(d,'''no_track'',m.no_track,','''no_track'',m.no_track,''parent_id'',m.parent_id,''var_size'',m.var_size,''var_color'',m.var_color,''var_sizes'',m.var_sizes,''var_colors'',m.var_colors,');
  if d=o then raise exception 'stock_state: шаблон не найден'; end if;
  execute d;
end $do$;

-- Наши футболки: 10 материалов «Футболка наша белая S … чёрная XXL» становятся вариантами «Футболки нашей»
-- с нормой 1 шт на «Футболку с принтом» (id 41). Остатки и история остаются на тех же материалах.
insert into public.stock_materials(name,unit,min_qty,is_active,in_workshop)
select 'Футболка наша','шт',0,true,true where not exists(select 1 from public.stock_materials where name='Футболка наша');
update public.stock_materials set var_sizes=array['S','M','L','XL','XXL'], var_colors=array['белая','чёрная'] where name='Футболка наша';
update public.stock_materials c set parent_id=p.id, var_color=split_part(c.name,' ',3), var_size=split_part(c.name,' ',4), variant_catalog_id=null
from public.stock_materials p where p.name='Футболка наша' and c.name like 'Футболка наша % %' and c.id<>p.id;
insert into public.stock_norms(catalog_id,material_id,qty,active)
select 41, id, 1, true from public.stock_materials where name='Футболка наша'
on conflict (catalog_id,material_id) do update set active=true, qty=1;
