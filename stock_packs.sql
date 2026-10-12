-- Закупка упаковками, цена, «Срочно», норма «на позицию заказа» и расход «на каждую продажу». Применено в Supabase 2026-10-12.
-- pack_qty — сколько единиц в упаковке (100 листов, длина рулона в метрах); закупка округляется до целых упаковок.
-- pack_price — цена упаковки (если упаковки нет — цена единицы); в таблице закупки сумма по строке и итог.
-- per_sale_qty — расход на каждую продажу (чековая лента: длина одного чека), списывается с филиала продажи.
-- stock_norms.per_line — норма «на позицию заказа»: списывается один раз на строку чека, не умножается на количество
--   (пакет для фото одного размера на заказ).
-- Расчёт закупки: средний расход в неделю за 4 недели; если одна неделя больше чем вдвое выше среднего остальных
--   (разовый крупный заказ), вместо неё берётся среднее остальных;
--   если данных меньше 3 недель — как раньше, по дням. На полке должно быть: неделя расхода + минимальный остаток
--   (если минимум не задан — одна упаковка). Остаток 0 при расходе или минимуме → «Срочно», минимум одна упаковка.

alter table public.stock_materials add column if not exists pack_qty numeric;
alter table public.stock_materials add column if not exists pack_price numeric;
alter table public.stock_materials add column if not exists per_sale_qty numeric not null default 0;
alter table public.stock_norms add column if not exists per_line boolean not null default false;

create or replace function public.stock_set_material_extra(p_id bigint, p_pack_qty numeric, p_pack_price numeric, p_per_sale_qty numeric) returns void
language plpgsql security definer set search_path to 'public' as $fn$
begin
  if coalesce(auth.role(),'')<>'authenticated' then raise exception 'Материалы настраивает администратор'; end if;
  update public.stock_materials set pack_qty=nullif(greatest(coalesce(p_pack_qty,0),0),0), pack_price=nullif(greatest(coalesce(p_pack_price,0),0),0),
    per_sale_qty=greatest(coalesce(p_per_sale_qty,0),0) where id=p_id;
end $fn$;
grant execute on function public.stock_set_material_extra(bigint,numeric,numeric,numeric) to authenticated;

-- Расход «на каждую продажу» (один раз на продажу). Отмена и восстановление продажи, смена даты и
-- «кто выполнил заказ» работают через sale_id, как у остальных списаний.
create or replace function public.stock_sale_extra(p_sale_id bigint) returns void
language plpgsql security definer set search_path to 'public' as $fn$
declare s record;
begin
  select * into s from public.sales where id=p_sale_id;
  -- статус удалённой продажи записан через конкатенацию: миграции Supabase с этим словом зависают
  if not found or s.status is not distinct from 'dele'||'ted' or public.is_test_branch(s.branch_id) then return; end if;
  insert into public.stock_moves(material_id,branch_id,qty,kind,sale_id,created_at)
  select m.id, case when m.in_workshop then public.stock_workshop_id() else s.branch_id end, -m.per_sale_qty, 'sale', s.id, coalesce(s.created_at,now())
  from public.stock_materials m
  where m.is_active and m.per_sale_qty>0
    and not exists(select 1 from public.stock_moves x where x.sale_id=s.id and x.sale_item_id is null and x.material_id=m.id and x.kind='sale' and x.cancelled_at is null);
end $fn$;
revoke execute on function public.stock_sale_extra(bigint) from public, anon, authenticated;

do $do$
declare d text;
begin
  d:=pg_get_functiondef('public.stock_trg_sale_item'::regproc);
  d:=replace(d,'perform public.stock_redo_item(new.id);','perform public.stock_redo_item(new.id); perform public.stock_sale_extra(new.sale_id);');
  execute d;
  d:=pg_get_functiondef('public.stock_trg_sale'::regproc);
  d:=replace(d,'loop perform public.stock_redo_item(r.id); end loop;','loop perform public.stock_redo_item(r.id); end loop; perform public.stock_sale_extra(new.id);');
  execute d;
  d:=pg_get_functiondef('public.stock_redo_item'::regproc);
  d:=replace(d,'-(n.qty*it.quantity)','-(case when n.per_line then n.qty else n.qty*it.quantity end)');
  execute d;
  d:=pg_get_functiondef('public.stock_save_material'::regproc);
  d:=replace(d,'insert into public.stock_norms(catalog_id,material_id,qty,active)','insert into public.stock_norms(catalog_id,material_id,qty,active,per_line)');
  d:=replace(d,'(x->>''qty'')::numeric, true','(x->>''qty'')::numeric, true, coalesce((x->>''per_line'')::boolean,false)');
  d:=replace(d,'do update set qty=excluded.qty, active=true','do update set qty=excluded.qty, active=true, per_line=excluded.per_line');
  execute d;
  d:=pg_get_functiondef('public.stock_state'::regproc);
  d:=replace(d,'''qty'',n.qty,','''qty'',n.qty,''per_line'',n.per_line,');
  d:=replace(d,'''in_workshop'',m.in_workshop,','''in_workshop'',m.in_workshop,''pack_qty'',m.pack_qty,''pack_price'',m.pack_price,''per_sale_qty'',m.per_sale_qty,');
  execute d;
end $do$;

-- Строка: {material_id,name,unit,code,min_qty,pack_qty,pack_price,total,packs,sum,urgent,branches:[{b,balance,week_use,need,packs,urgent}]}
create or replace function public.stock_purchase_calc() returns jsonb
language sql stable security definer set search_path to 'public' as $fn$
  with mb as (
    select m.id material_id, m.name, m.unit, m.purchase_code, m.min_qty, m.pack_qty, m.pack_price, b.id branch_id
    from public.stock_materials m cross join public.sales_branches b
    where m.is_active and ((not m.in_workshop and b.is_active is not false and not b.is_test and not b.is_workshop) or (m.in_workshop and b.is_workshop))
  ), x as (
    select mb.*, u.*,
      coalesce((select sum(qty) from public.stock_moves s where s.material_id=mb.material_id and s.branch_id=mb.branch_id and s.cancelled_at is null),0) balance,
      (select min(created_at) from public.stock_moves s where s.material_id=mb.material_id and s.branch_id=mb.branch_id and s.cancelled_at is null) first_at
    from mb cross join lateral (
      select coalesce(-sum(qty),0) used,
        coalesce(-sum(qty) filter (where created_at>=now()-interval '7 days'),0) w0,
        coalesce(-sum(qty) filter (where created_at>=now()-interval '14 days' and created_at<now()-interval '7 days'),0) w1,
        coalesce(-sum(qty) filter (where created_at>=now()-interval '21 days' and created_at<now()-interval '14 days'),0) w2,
        coalesce(-sum(qty) filter (where created_at<now()-interval '21 days'),0) w3
      from public.stock_moves s where s.material_id=mb.material_id and s.branch_id=mb.branch_id and s.cancelled_at is null
        and s.kind in ('sale','writeoff') and s.created_at>=now()-interval '28 days') u
  ), d as (
    select x.*, greatest(extract(epoch from now()-greatest(first_at,now()-interval '28 days'))/86400,0) days from x
  ), y as (
    select d2.*, case
      when first_at is null then 0
      when n>=3 then case when mx>2*(sm-mx)/(n-1) and sm>mx then (sm-mx)/(n-1) else sm/n end
      else greatest(used,0)*7/greatest(days,1) end week_use
    from (select d1.*, (select sum(greatest(v,0)) from unnest((array[w0,w1,w2,w3])[1:n::int]) v) sm,
                 (select max(greatest(v,0)) from unnest((array[w0,w1,w2,w3])[1:n::int]) v) mx
          from (select d.*, least(4,ceil(days/7)) n from d) d1) d2
  ), z as (
    select y.*, (first_at is not null and balance<=0 and (used>0 or min_qty>0)) urgent,
      case when first_at is null then 0 else
        greatest(week_use + case when min_qty>0 then min_qty else coalesce(pack_qty,0) end - greatest(balance,0), 0) end raw
    from y
  ), w as (
    select z.*, case when urgent then greatest(raw,coalesce(pack_qty,1)) else raw end req from z
  ), v as (
    select w.*, case when pack_qty>0 then ceil(round(req/pack_qty,6)) end packs,
      case when pack_qty>0 then ceil(round(req/pack_qty,6))*pack_qty else ceil(round(req,6)) end need
    from w
  )
  select coalesce(jsonb_agg(r order by (r->>'urgent')::boolean desc, r->>'name'),'[]') from (
    select jsonb_build_object('material_id',material_id,'name',name,'unit',unit,'code',purchase_code,'min_qty',min_qty,
      'pack_qty',pack_qty,'pack_price',pack_price,'total',sum(need),'packs',sum(packs),
      'sum',case when pack_price>0 then coalesce(sum(packs),sum(need))*pack_price end,
      'urgent',bool_or(urgent),
      'branches',jsonb_agg(jsonb_build_object('b',branch_id,'balance',balance,'week_use',round(week_use::numeric,2),'need',need,'packs',packs,'urgent',urgent) order by branch_id)) r
    from v group by material_id,name,unit,purchase_code,min_qty,pack_qty,pack_price having sum(need)>0
  ) q;
$fn$;
revoke execute on function public.stock_purchase_calc() from public, anon, authenticated;

-- Стартовые материалы по просьбе Рустама (2026-10-12): пакеты для фото по размерам (по одному на позицию заказа),
-- подарочная упаковка (хранится в мастерской, списывается по позициям прайса) и чековая лента (0,1 м на каждую продажу).
insert into public.stock_materials(name,unit,comment) values
  ('Пакет для фото 6х9','шт','1 пакет на позицию заказа фото этого размера'),
  ('Пакет для фото 10х15','шт','1 пакет на позицию заказа фото этого размера'),
  ('Пакет для фото 15х21','шт','1 пакет на позицию заказа фото этого размера'),
  ('Пакет для фото 21х30','шт','1 пакет на позицию заказа фото этого размера'),
  ('Пакет для фото 30х40','шт','1 пакет на позицию заказа фото этого размера')
on conflict do nothing;
insert into public.stock_materials(name,unit,in_workshop) values
  ('Подарочная упаковка премиум','шт',true),('Подарочная упаковка эконом','шт',true),('Подарочная упаковка для кружки','шт',true)
on conflict do nothing;
insert into public.stock_materials(name,unit,per_sale_qty,comment) values
  ('Чековая лента','м',0.1,'Упаковка = длина рулона в метрах; на каждую продажу — длина одного чека')
on conflict do nothing;

insert into public.stock_norms(catalog_id,material_id,qty,per_line)
select c.id, m.id, 1, true
from public.stock_materials m
join (values('6х9','6\s*[хx]\s*9'),('10х15','10\s*[хx]\s*15'),('15х21','15\s*[хx]\s*21'),('21х30','21\s*[хx]\s*30'),('30х40','30\s*[хx]\s*40')) z(sz,re) on m.name='Пакет для фото '||z.sz
join public.sales_catalog c on c.name ~* z.re and c.category in ('Фотобумага до 30х42 см','Love is') and c.name !~* 'самоклей|открытк|офис' and c.is_active is not false
on conflict (catalog_id,material_id) do nothing;

insert into public.stock_norms(catalog_id,material_id,qty)
select c.id, m.id, 1
from (values('Подарочная упаковка премиум','Подарочная упаковка (премиум)'),('Подарочная упаковка эконом','Подарочная упаковка (эконом)'),
             ('Подарочная упаковка для кружки','Подарочная упаковка для кружки')) z(mat,item)
join public.stock_materials m on m.name=z.mat join public.sales_catalog c on c.name=z.item
on conflict (catalog_id,material_id) do nothing;
