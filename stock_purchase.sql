-- Еженедельная таблица закупки расходников. Применено в Supabase 2026-10-11.
-- Средний расход в неделю = продажи и списания материала на филиале за последние 4 недели, делённые на число недель.
-- Если склад на филиале ведётся меньше 4 недель, берутся дни с первого движения (минимум 1 день).
-- К заказу = расход на 2 недели (до следующей закупки + неделя запаса) минус остаток, округлено вверх.
-- Если остаток не выше минимума, заказываем минимум хотя бы до «минимум + неделя расхода».
-- Филиал, где по материалу ещё не было ни одного движения (не делали инвентаризацию), в расчёт не попадает.
-- Таблица собирается каждый понедельник в 06:00 по Москве и хранится в stock_purchase_lists (история по неделям).

alter table public.stock_materials add column if not exists purchase_code text;

create table if not exists public.stock_purchase_lists(
  week_start date primary key,
  created_at timestamptz not null default now(),
  rows jsonb not null default '[]'
);
alter table public.stock_purchase_lists enable row level security;
create policy stock_purchase_lists_read on public.stock_purchase_lists for select to anon, authenticated using (true);

-- Код позиции в магазине, где заказываем. Только администратор.
create or replace function public.stock_set_purchase_code(p_id bigint, p_code text) returns void
language plpgsql security definer set search_path to 'public' as $fn$
begin
  if coalesce(auth.role(),'')<>'authenticated' then raise exception 'Материалы настраивает администратор'; end if;
  update public.stock_materials set purchase_code=nullif(trim(coalesce(p_code,'')),'') where id=p_id;
end $fn$;
grant execute on function public.stock_set_purchase_code(bigint,text) to authenticated;

-- Расчёт «что заказать» на текущий момент.
-- Строка: {material_id, name, unit, code, min_qty, total, branches:[{b, balance, week_use, need}]}
create or replace function public.stock_purchase_calc() returns jsonb
language sql stable security definer set search_path to 'public' as $fn$
  with mb as (
    select m.id material_id, m.name, m.unit, m.purchase_code, m.min_qty, b.id branch_id
    from public.stock_materials m cross join public.sales_branches b
    where m.is_active and b.is_active is not false
  ), x as (
    select mb.*,
      coalesce((select sum(qty) from public.stock_moves s where s.material_id=mb.material_id and s.branch_id=mb.branch_id and s.cancelled_at is null),0) balance,
      coalesce((select -sum(qty) from public.stock_moves s where s.material_id=mb.material_id and s.branch_id=mb.branch_id and s.cancelled_at is null
                and s.kind in ('sale','writeoff') and s.created_at>=now()-interval '28 days'),0) used,
      (select min(created_at) from public.stock_moves s where s.material_id=mb.material_id and s.branch_id=mb.branch_id and s.cancelled_at is null) first_at
    from mb
  ), y as (
    select x.*,
      case when first_at is null then 0
           else greatest(used,0)*7/greatest(extract(epoch from now()-greatest(first_at,now()-interval '28 days'))/86400,1) end week_use
    from x
  ), z as (
    select y.*, case when first_at is null then 0 else ceil(greatest(
        week_use*2-greatest(balance,0),
        case when min_qty>0 and balance<=min_qty then min_qty+week_use-greatest(balance,0) else 0 end,
        0)) end need
    from y
  )
  select coalesce(jsonb_agg(r order by r->>'name'),'[]') from (
    select jsonb_build_object('material_id',material_id,'name',name,'unit',unit,'code',purchase_code,'min_qty',min_qty,
      'total',sum(need),
      'branches',jsonb_agg(jsonb_build_object('b',branch_id,'balance',balance,'week_use',round(week_use::numeric,2),'need',need) order by branch_id)) r
    from z group by material_id,name,unit,purchase_code,min_qty having sum(need)>0
  ) q;
$fn$;
revoke execute on function public.stock_purchase_calc() from public, anon, authenticated;

-- Понедельник текущей недели по Москве.
create or replace function public.stock_purchase_week() returns date
language sql stable as $fn$ select date_trunc('week',(now() at time zone 'Europe/Moscow'))::date $fn$;

create or replace function public.stock_purchase_build() returns date
language plpgsql security definer set search_path to 'public' as $fn$
declare v_w date:=public.stock_purchase_week();
begin
  insert into public.stock_purchase_lists(week_start,created_at,rows) values(v_w,now(),public.stock_purchase_calc())
  on conflict (week_start) do update set created_at=excluded.created_at, rows=excluded.rows;
  return v_w;
end $fn$;
revoke execute on function public.stock_purchase_build() from public, anon, authenticated;

-- Таблица за неделю (по умолчанию — текущую). Если на этой неделе её ещё нет, собирается сразу.
-- p_rebuild — пересчитать по сегодняшним остаткам (только администратор).
create or replace function public.stock_purchase_get(p_week date default null, p_rebuild boolean default false) returns jsonb
language plpgsql security definer set search_path to 'public' as $fn$
declare v_w date:=coalesce(p_week,public.stock_purchase_week()); r record;
begin
  if p_rebuild then
    if coalesce(auth.role(),'')<>'authenticated' then raise exception 'Пересчитать может только администратор'; end if;
    v_w:=public.stock_purchase_build();
  elsif v_w=public.stock_purchase_week() and not exists(select 1 from public.stock_purchase_lists where week_start=v_w) then
    perform public.stock_purchase_build();
  end if;
  select * into r from public.stock_purchase_lists where week_start=v_w;
  return jsonb_build_object('week',v_w,'created_at',r.created_at,'rows',coalesce(r.rows,'[]'::jsonb),
    'weeks',(select coalesce(jsonb_agg(week_start order by week_start desc),'[]') from (select week_start from public.stock_purchase_lists order by week_start desc limit 30) w));
end $fn$;
grant execute on function public.stock_purchase_get(date,boolean) to anon, authenticated;

-- Каждый понедельник в 03:00 UTC = 06:00 по Москве.
select cron.unschedule('stock-purchase') where exists(select 1 from cron.job where jobname='stock-purchase');
select cron.schedule('stock-purchase','0 3 * * 1','select public.stock_purchase_build()');

-- В stock_state у материала появляется purchase_code.
create or replace function public.stock_state(p_days int default 30) returns jsonb
language sql stable security definer set search_path to 'public' as $fn$
  select jsonb_build_object(
    'materials',(select coalesce(jsonb_agg(jsonb_build_object('id',m.id,'name',m.name,'unit',m.unit,'min_qty',m.min_qty,'comment',m.comment,'purchase_code',m.purchase_code,'is_active',m.is_active,
        'norms',(select coalesce(jsonb_agg(jsonb_build_object('catalog_id',n.catalog_id,'qty',n.qty,'name',c.name) order by c.name),'[]')
                 from public.stock_norms n join public.sales_catalog c on c.id=n.catalog_id where n.material_id=m.id and n.active)) order by m.name),'[]') from public.stock_materials m),
    'balances',(select coalesce(jsonb_agg(jsonb_build_object('m',material_id,'b',branch_id,'q',q)),'[]')
                from (select material_id,branch_id,sum(qty) q from public.stock_moves where cancelled_at is null group by 1,2) x),
    'usage',(select coalesce(jsonb_agg(jsonb_build_object('m',material_id,'b',branch_id,'q',q)),'[]')
             from (select material_id,branch_id,-sum(qty) q from public.stock_moves where cancelled_at is null and kind in ('sale','writeoff') and created_at>=now()-make_interval(days=>greatest(p_days,1)) group by 1,2) x)
  );
$fn$;
