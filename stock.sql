-- Склад расходников (бумага, плёнка, рамки…). Применено в Supabase 2026-10-11.
-- Материал общий для многих позиций прайса: норма «сколько материала уходит на 1 шт. позиции».
-- Остаток считается по каждому филиалу как сумма движений stock_moves.
-- Продажа списывает материал автоматически; по умолчанию с филиала продажи, но выполняющий филиал
-- можно поменять для всего заказа или для отдельной позиции (заказ делят несколько филиалов).

create table if not exists public.stock_materials(
  id bigserial primary key,
  name text not null,
  unit text not null default 'шт',
  min_qty numeric not null default 0,
  comment text,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);
create unique index if not exists stock_materials_name_key on public.stock_materials(lower(name));

create table if not exists public.stock_norms(
  id bigserial primary key,
  catalog_id bigint not null references public.sales_catalog(id) on delete cascade,
  material_id bigint not null references public.stock_materials(id) on delete cascade,
  qty numeric not null check (qty>0),
  unique(catalog_id,material_id)
);

-- qty со знаком: + пришло на филиал, − ушло с филиала.
create table if not exists public.stock_moves(
  id bigserial primary key,
  material_id bigint not null references public.stock_materials(id) on delete cascade,
  branch_id bigint not null references public.sales_branches(id),
  qty numeric not null,
  kind text not null check (kind in ('receipt','transfer_out','transfer_in','sale','writeoff','inventory')),
  sale_id bigint references public.sales(id) on delete cascade,
  sale_item_id bigint references public.sale_items(id) on delete cascade,
  group_id uuid,
  other_branch_id bigint references public.sales_branches(id),
  counted numeric,
  price_total numeric,
  supplier text,
  comment text,
  person_id bigint,
  person_name text,
  shift_id bigint,
  created_at timestamptz not null default now()
);
create index if not exists stock_moves_mb on public.stock_moves(material_id,branch_id);
create index if not exists stock_moves_sale on public.stock_moves(sale_id);
create index if not exists stock_moves_item on public.stock_moves(sale_item_id);
create index if not exists stock_moves_at on public.stock_moves(created_at);
create index if not exists stock_norms_cat on public.stock_norms(catalog_id);

alter table public.stock_materials enable row level security;
alter table public.stock_norms enable row level security;
alter table public.stock_moves enable row level security;
drop policy if exists stock_materials_read on public.stock_materials;
create policy stock_materials_read on public.stock_materials for select to anon, authenticated using (true);
drop policy if exists stock_materials_admin on public.stock_materials;
create policy stock_materials_admin on public.stock_materials for all to authenticated using (true) with check (true);
drop policy if exists stock_norms_read on public.stock_norms;
create policy stock_norms_read on public.stock_norms for select to anon, authenticated using (true);
drop policy if exists stock_norms_admin on public.stock_norms;
create policy stock_norms_admin on public.stock_norms for all to authenticated using (true) with check (true);
-- Движения пишутся только через функции ниже.
drop policy if exists stock_moves_read on public.stock_moves;
create policy stock_moves_read on public.stock_moves for select to anon, authenticated using (true);

-- ============ Списание по продажам (триггеры) ============
-- Пересоздаёт списание одной позиции продажи. Филиал берётся из уже существующего списания этой позиции
-- (если его переносили), иначе — филиал продажи. Ошибка здесь никогда не мешает продаже.
create or replace function public.stock_redo_item(p_item_id bigint) returns void
language plpgsql security definer set search_path to 'public' as $fn$
declare it record; v_branch bigint; v_status text;
begin
  select branch_id into v_branch from public.stock_moves where sale_item_id=p_item_id and kind='sale' order by id limit 1;
  delete from public.stock_moves where sale_item_id=p_item_id and kind='sale';
  select i.*, s.branch_id sale_branch, s.status sale_status, s.created_at sale_at into it
    from public.sale_items i join public.sales s on s.id=i.sale_id where i.id=p_item_id;
  if not found or it.sale_status='deleted' or it.catalog_id is null then return; end if;
  insert into public.stock_moves(material_id,branch_id,qty,kind,sale_id,sale_item_id,created_at)
  select n.material_id, coalesce(v_branch,it.sale_branch), -(n.qty*it.quantity), 'sale', it.sale_id, it.id, coalesce(it.sale_at,now())
  from public.stock_norms n where n.catalog_id=it.catalog_id and coalesce(it.quantity,0)<>0;
end $fn$;
revoke execute on function public.stock_redo_item(bigint) from public, anon, authenticated;

create or replace function public.stock_trg_sale_item() returns trigger
language plpgsql security definer set search_path to 'public' as $fn$
begin
  begin
    if tg_op='DELETE' then delete from public.stock_moves where sale_item_id=old.id; return old; end if;
    perform public.stock_redo_item(new.id);
  exception when others then raise warning 'stock: %', sqlerrm; end;
  return new;
end $fn$;
drop trigger if exists stock_sale_item on public.sale_items;
create trigger stock_sale_item after insert or update of quantity, catalog_id or delete on public.sale_items
  for each row execute function public.stock_trg_sale_item();

-- Удалённая продажа возвращает материал; восстановленная — списывает снова.
-- Возврат (returned) материал не возвращает: бумага уже израсходована.
-- Время списания = время продажи (офлайн-продажи получают фактическое время позже).
create or replace function public.stock_trg_sale() returns trigger
language plpgsql security definer set search_path to 'public' as $fn$
declare r record;
begin
  begin
    if new.status='deleted' and old.status is distinct from 'deleted' then
      delete from public.stock_moves where sale_id=new.id and kind='sale';
    elsif old.status='deleted' and new.status<>'deleted' then
      for r in select id from public.sale_items where sale_id=new.id loop perform public.stock_redo_item(r.id); end loop;
    elsif new.created_at is distinct from old.created_at then
      update public.stock_moves set created_at=new.created_at where sale_id=new.id and kind='sale';
    end if;
  exception when others then raise warning 'stock: %', sqlerrm; end;
  return new;
end $fn$;
drop trigger if exists stock_sale on public.sales;
create trigger stock_sale after update of status, created_at on public.sales
  for each row execute function public.stock_trg_sale();

-- ============ Кто выполняет операцию ============
-- Администратор (вошёл на сайт) — любой филиал. Сотрудник — только из открытой смены, в которой он участвует.
create or replace function public.stock_actor(p_shift_id bigint, p_person_id bigint, out is_admin boolean, out branch_id bigint, out person_name text)
language plpgsql stable security definer set search_path to 'public' as $fn$
begin
  is_admin:=coalesce(auth.role(),'')='authenticated';
  select s.branch_id, coalesce(pp.name,e.name) into branch_id, person_name
    from public.sales_shift_employees se join public.sales_employees e on e.id=se.employee_id
    join public.sales_shifts s on s.id=se.shift_id left join public.sales_people pp on pp.id=e.person_id
    where se.shift_id=p_shift_id and e.person_id=p_person_id and s.status='open' limit 1;
  if branch_id is null and not is_admin then raise exception 'Откройте смену: складские операции делает сотрудник смены или администратор'; end if;
  if is_admin and person_name is null then person_name:='Администратор'; end if;
end $fn$;
revoke execute on function public.stock_actor(bigint,bigint) from public, anon, authenticated;

-- ============ Остатки ============
-- materials — все материалы с нормами; balances — остаток по филиалам; usage — расход (продажи и списания) за p_days дней.
create or replace function public.stock_state(p_days int default 30) returns jsonb
language sql stable security definer set search_path to 'public' as $fn$
  select jsonb_build_object(
    'materials',(select coalesce(jsonb_agg(jsonb_build_object('id',m.id,'name',m.name,'unit',m.unit,'min_qty',m.min_qty,'comment',m.comment,'is_active',m.is_active,
        'norms',(select coalesce(jsonb_agg(jsonb_build_object('catalog_id',n.catalog_id,'qty',n.qty,'name',c.name) order by c.name),'[]')
                 from public.stock_norms n join public.sales_catalog c on c.id=n.catalog_id where n.material_id=m.id)) order by m.name),'[]') from public.stock_materials m),
    'balances',(select coalesce(jsonb_agg(jsonb_build_object('m',material_id,'b',branch_id,'q',q)),'[]')
                from (select material_id,branch_id,sum(qty) q from public.stock_moves group by 1,2) x),
    'usage',(select coalesce(jsonb_agg(jsonb_build_object('m',material_id,'b',branch_id,'q',q)),'[]')
             from (select material_id,branch_id,-sum(qty) q from public.stock_moves where kind in ('sale','writeoff') and created_at>=now()-make_interval(days=>greatest(p_days,1)) group by 1,2) x)
  );
$fn$;
grant execute on function public.stock_state(int) to anon, authenticated;

-- ============ Операции ============
-- p_kind: receipt (приход/закупка), transfer (перемещение p_branch_id → p_to_branch_id), writeoff (брак, порча), inventory (пересчёт).
-- p_items: [{material_id, qty}] ; для inventory qty = сколько насчитали; для receipt можно price_total (сумма закупки).
create or replace function public.stock_operation(p_shift_id bigint, p_person_id bigint, p_kind text, p_branch_id bigint,
  p_items jsonb, p_to_branch_id bigint default null, p_supplier text default null, p_comment text default null) returns int
language plpgsql security definer set search_path to 'public' as $fn$
declare a record; it jsonb; v_m bigint; v_q numeric; v_bal numeric; v_g uuid:=gen_random_uuid(); v_n int:=0;
begin
  select * into a from public.stock_actor(p_shift_id,p_person_id);
  if p_kind not in ('receipt','transfer','writeoff','inventory') then raise exception 'Неизвестная операция'; end if;
  if p_branch_id is null or not exists(select 1 from public.sales_branches where id=p_branch_id) then raise exception 'Выберите филиал'; end if;
  if p_kind='transfer' then
    if p_to_branch_id is null or p_to_branch_id=p_branch_id or not exists(select 1 from public.sales_branches where id=p_to_branch_id) then raise exception 'Выберите, в какой филиал передаёте'; end if;
    if not a.is_admin and a.branch_id not in (p_branch_id,p_to_branch_id) then raise exception 'Перемещение должно быть с вашего филиала или на ваш филиал'; end if;
  elsif not a.is_admin and a.branch_id<>p_branch_id then raise exception 'Сотрудник смены работает только со складом своего филиала';
  end if;
  if p_kind='writeoff' and nullif(trim(coalesce(p_comment,'')),'') is null then raise exception 'Укажите причину списания'; end if;
  for it in select * from jsonb_array_elements(coalesce(p_items,'[]')) loop
    v_m:=(it->>'material_id')::bigint; v_q:=nullif(it->>'qty','')::numeric;
    if v_m is null or v_q is null then continue; end if;
    if not exists(select 1 from public.stock_materials where id=v_m) then raise exception 'Материал не найден'; end if;
    if p_kind='inventory' then
      if v_q<0 then raise exception 'Количество не может быть отрицательным'; end if;
      perform pg_advisory_xact_lock(hashtext('stock:'||v_m||':'||p_branch_id));
      select coalesce(sum(qty),0) into v_bal from public.stock_moves where material_id=v_m and branch_id=p_branch_id;
      insert into public.stock_moves(material_id,branch_id,qty,kind,group_id,counted,comment,person_id,person_name,shift_id)
        values(v_m,p_branch_id,v_q-v_bal,'inventory',v_g,v_q,p_comment,p_person_id,a.person_name,p_shift_id);
    else
      if v_q<=0 then raise exception 'Количество должно быть больше нуля'; end if;
      if p_kind='receipt' then
        insert into public.stock_moves(material_id,branch_id,qty,kind,group_id,price_total,supplier,comment,person_id,person_name,shift_id)
          values(v_m,p_branch_id,v_q,'receipt',v_g,nullif(it->>'price_total','')::numeric,nullif(trim(coalesce(p_supplier,'')),''),p_comment,p_person_id,a.person_name,p_shift_id);
      elsif p_kind='writeoff' then
        insert into public.stock_moves(material_id,branch_id,qty,kind,group_id,comment,person_id,person_name,shift_id)
          values(v_m,p_branch_id,-v_q,'writeoff',v_g,p_comment,p_person_id,a.person_name,p_shift_id);
      else
        insert into public.stock_moves(material_id,branch_id,qty,kind,group_id,other_branch_id,comment,person_id,person_name,shift_id)
          values(v_m,p_branch_id,-v_q,'transfer_out',v_g,p_to_branch_id,p_comment,p_person_id,a.person_name,p_shift_id),
                (v_m,p_to_branch_id,v_q,'transfer_in',v_g,p_branch_id,p_comment,p_person_id,a.person_name,p_shift_id);
      end if;
    end if;
    v_n:=v_n+1;
  end loop;
  if v_n=0 then raise exception 'Добавьте хотя бы один материал с количеством'; end if;
  return v_n;
end $fn$;
grant execute on function public.stock_operation(bigint,bigint,text,bigint,jsonb,bigint,text,text) to anon, authenticated;

-- Отмена ручной операции целиком (все строки с тем же group_id). Только администратор.
create or replace function public.stock_cancel_operation(p_move_id bigint) returns int
language plpgsql security definer set search_path to 'public' as $fn$
declare v_g uuid; v_n int;
begin
  if coalesce(auth.role(),'')<>'authenticated' then raise exception 'Отменить операцию может только администратор'; end if;
  select group_id into v_g from public.stock_moves where id=p_move_id and kind<>'sale';
  if v_g is null then raise exception 'Операция не найдена (списание по продаже меняется через выполняющий филиал)'; end if;
  delete from public.stock_moves where group_id=v_g; get diagnostics v_n=row_count; return v_n;
end $fn$;
grant execute on function public.stock_cancel_operation(bigint) to authenticated;

-- ============ Журнал ============
create or replace function public.stock_journal(p_branch_id bigint default null, p_material_id bigint default null,
  p_from timestamptz default null, p_to timestamptz default null, p_kind text default null, p_limit int default 300) returns jsonb
language sql stable security definer set search_path to 'public' as $fn$
  select coalesce(jsonb_agg(x order by x.created_at desc, x.id desc),'[]') from (
    select m.id, m.created_at, m.kind, m.qty, m.counted, m.price_total, m.supplier, m.comment, m.person_name, m.branch_id, m.other_branch_id,
      m.material_id, mt.name material, mt.unit, m.sale_id, s.order_number, s.branch_id sale_branch_id, i.item_name
    from public.stock_moves m join public.stock_materials mt on mt.id=m.material_id
    left join public.sales s on s.id=m.sale_id left join public.sale_items i on i.id=m.sale_item_id
    where (p_branch_id is null or m.branch_id=p_branch_id) and (p_material_id is null or m.material_id=p_material_id)
      and (p_from is null or m.created_at>=p_from) and (p_to is null or m.created_at<p_to)
      and (p_kind is null or m.kind=p_kind or (p_kind='transfer' and m.kind in ('transfer_in','transfer_out')))
    order by m.created_at desc, m.id desc limit least(greatest(coalesce(p_limit,300),1),2000)
  ) x;
$fn$;
grant execute on function public.stock_journal(bigint,bigint,timestamptz,timestamptz,text,int) to anon, authenticated;

-- ============ Какой филиал выполнил заказ ============
-- Продажи за период (или по номеру) с позициями и тем, откуда списан материал.
create or replace function public.stock_orders(p_branch_id bigint default null, p_from timestamptz default null, p_to timestamptz default null,
  p_order_number bigint default null) returns jsonb
language sql stable security definer set search_path to 'public' as $fn$
  select coalesce(jsonb_agg(o order by o.created_at desc),'[]') from (
    select s.id, s.order_number, s.created_at, s.branch_id, s.total, s.comment,
      (select coalesce(jsonb_agg(jsonb_build_object('id',i.id,'name',i.item_name,'quantity',i.quantity,
          'moves',(select coalesce(jsonb_agg(jsonb_build_object('b',m.branch_id,'material',mt.name,'unit',mt.unit,'qty',-m.qty)),'[]')
                   from public.stock_moves m join public.stock_materials mt on mt.id=m.material_id where m.sale_item_id=i.id and m.kind='sale')) order by i.id),'[]')
       from public.sale_items i where i.sale_id=s.id) items
    from public.sales s
    where s.status<>'deleted' and (p_branch_id is null or s.branch_id=p_branch_id)
      and (p_order_number is null or s.order_number=p_order_number)
      and (p_order_number is not null or ((p_from is null or s.created_at>=p_from) and (p_to is null or s.created_at<p_to)))
    order by s.created_at desc limit 300
  ) o;
$fn$;
grant execute on function public.stock_orders(bigint,timestamptz,timestamptz,bigint) to anon, authenticated;

-- Перенос списания на другой филиал: одной позиции (p_sale_item_id) или всего заказа (p_sale_id).
create or replace function public.stock_set_producer(p_shift_id bigint, p_person_id bigint, p_branch_id bigint,
  p_sale_id bigint default null, p_sale_item_id bigint default null) returns int
language plpgsql security definer set search_path to 'public' as $fn$
declare a record; v_n int;
begin
  select * into a from public.stock_actor(p_shift_id,p_person_id);
  if not exists(select 1 from public.sales_branches where id=p_branch_id) then raise exception 'Выберите филиал'; end if;
  if p_sale_item_id is null and p_sale_id is null then raise exception 'Не указан заказ'; end if;
  update public.stock_moves set branch_id=p_branch_id, person_id=p_person_id, person_name=a.person_name
   where kind='sale' and ((p_sale_item_id is not null and sale_item_id=p_sale_item_id) or (p_sale_item_id is null and sale_id=p_sale_id));
  get diagnostics v_n=row_count; return v_n;
end $fn$;
grant execute on function public.stock_set_producer(bigint,bigint,bigint,bigint,bigint) to anon, authenticated;

-- То же по номеру заказа (используется сразу после оформления продажи, когда известен только номер).
create or replace function public.stock_set_producer_by_number(p_shift_id bigint, p_person_id bigint, p_sale_branch_id bigint,
  p_order_number bigint, p_branch_id bigint) returns int
language plpgsql security definer set search_path to 'public' as $fn$
declare v_sale bigint;
begin
  select id into v_sale from public.sales where branch_id=p_sale_branch_id and order_number=p_order_number and status<>'deleted' order by id desc limit 1;
  if v_sale is null then return -1; end if;
  return public.stock_set_producer(p_shift_id,p_person_id,p_branch_id,v_sale,null);
end $fn$;
grant execute on function public.stock_set_producer_by_number(bigint,bigint,bigint,bigint,bigint) to anon, authenticated;

-- Нормы материала целиком: p_norms = [{catalog_id, qty}]. Только администратор.
create or replace function public.stock_save_material(p_id bigint, p_name text, p_unit text, p_min_qty numeric, p_comment text,
  p_is_active boolean, p_norms jsonb) returns bigint
language plpgsql security definer set search_path to 'public' as $fn$
declare v_id bigint;
begin
  if coalesce(auth.role(),'')<>'authenticated' then raise exception 'Материалы настраивает администратор'; end if;
  if nullif(trim(coalesce(p_name,'')),'') is null then raise exception 'Укажите название материала'; end if;
  if p_id is null then
    insert into public.stock_materials(name,unit,min_qty,comment,is_active)
      values(trim(p_name),coalesce(nullif(trim(p_unit),''),'шт'),coalesce(p_min_qty,0),nullif(trim(coalesce(p_comment,'')),''),coalesce(p_is_active,true)) returning id into v_id;
  else
    update public.stock_materials set name=trim(p_name),unit=coalesce(nullif(trim(p_unit),''),'шт'),min_qty=coalesce(p_min_qty,0),
      comment=nullif(trim(coalesce(p_comment,'')),''),is_active=coalesce(p_is_active,true) where id=p_id returning id into v_id;
    if v_id is null then raise exception 'Материал не найден'; end if;
  end if;
  if p_norms is not null then
    delete from public.stock_norms where material_id=v_id;
    insert into public.stock_norms(catalog_id,material_id,qty)
      select distinct on ((x->>'catalog_id')::bigint) (x->>'catalog_id')::bigint, v_id, (x->>'qty')::numeric
      from jsonb_array_elements(p_norms) x where nullif(x->>'qty','')::numeric>0;
  end if;
  return v_id;
end $fn$;
grant execute on function public.stock_save_material(bigint,text,text,numeric,text,boolean,jsonb) to authenticated;
