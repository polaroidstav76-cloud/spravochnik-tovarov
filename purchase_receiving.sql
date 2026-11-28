-- Completed admin purchases create immutable, idempotent stock receipts, separately from staff cash expenses.
alter table public.purchase_catalog add column material_id bigint references public.stock_materials(id) on delete set null;
create table purchase_private.received_lines(
 id uuid primary key default gen_random_uuid(),batch_id uuid not null references public.purchase_batches(id),position integer not null,
 material_id bigint not null references public.stock_materials(id),branch_id bigint not null references public.sales_branches(id),
 name text not null,unit text not null,qty numeric not null check(qty>0),factor numeric not null check(factor>0),
 unit_price numeric check(unit_price>=0 and unit_price<1000000000),version integer not null default 1,
 received_at timestamptz not null default now(),unique(batch_id,position)
);
create index purchase_catalog_material on public.purchase_catalog(material_id);
create index purchase_received_material on purchase_private.received_lines(material_id);
create index purchase_received_branch_day on purchase_private.received_lines(branch_id,received_at);
create table purchase_private.price_audit(id bigint generated always as identity primary key,line_id uuid not null references purchase_private.received_lines(id),actor uuid not null,changed_at timestamptz not null default now(),before_price numeric,after_price numeric);
create table purchase_private.report_errors(branch_id bigint not null,day date not null,error text not null,primary key(branch_id,day));
create index purchase_price_audit_line on purchase_private.price_audit(line_id);
alter table purchase_private.received_lines enable row level security;
alter table purchase_private.price_audit enable row level security;
alter table purchase_private.report_errors enable row level security;
create policy no_clients on purchase_private.received_lines to anon,authenticated using(false) with check(false);
create policy no_clients on purchase_private.price_audit to anon,authenticated using(false) with check(false);
create policy no_clients on purchase_private.report_errors to anon,authenticated using(false) with check(false);
revoke all on purchase_private.received_lines,purchase_private.price_audit,purchase_private.report_errors from public,anon,authenticated;
alter table public.stock_moves add column purchase_line_id uuid unique references purchase_private.received_lines(id);

-- Admin purchasing costs never enter staff expense totals.
do $$declare def text;begin
 def:=pg_get_functiondef('workflow_private.receipt_rows(bigint,date,timestamptz)'::regprocedure);
 if position('where m.kind=' in def)=0 then raise exception 'Unexpected receipt accounting implementation';end if;
 def:=replace(def,'where m.kind=','where m.purchase_line_id is null and m.kind=');execute def;
 def:=pg_get_functiondef('workflow_private.expense_history(date,date)'::regprocedure);
 def:=replace(def,'where m.kind=','where m.purchase_line_id is null and m.kind=');execute def;
end $$;
create function purchase_private.move_guard() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if coalesce(current_setting('purchase.receiving_write',true),'')='1' then if tg_op='DELETE' then return old;else return new;end if;end if;
 if (tg_op<>'INSERT' and old.purchase_line_id is not null) or(tg_op<>'DELETE' and new.purchase_line_id is not null) then raise exception 'Приход из завершённой закупки защищён от ручного изменения. Цену меняйте в истории закупок.';end if;
 if tg_op='DELETE' then return old;else return new;end if;
end $$;
create trigger purchase_receipt_guard before insert or update or delete on public.stock_moves for each row execute function purchase_private.move_guard();

create function purchase_private.report_sync(p_branch bigint,p_day date) returns void language plpgsql security invoker set search_path='' as $$
declare ctx record;s public.report_sheets;rows jsonb;locks jsonb;header integer;rr record;rd date;cell jsonb;total numeric;missing bigint;known bigint;month_total numeric;month_missing bigint;month_known bigint;guard text;
begin
 if exists(select 1 from public.sales_branches where id=p_branch and (is_test or is_workshop)) then return;end if;
 begin select * into ctx from public.report_day_row(p_branch,p_day);exception when others then insert into purchase_private.report_errors values(p_branch,p_day,'В общем отчёте нет строки на дату закупки') on conflict(branch_id,day) do update set error=excluded.error;return;end;
 select * into s from public.report_sheets where id=ctx.sheet_id for update;
 rows:=s.data->'rows';locks:=coalesce(s.data->'purchase_readonly_rows','{}');
 select k::int into header from jsonb_each(rows)r(k,v) where k::int between ctx.m_from and ctx.row_no and v->'O'->>'v'='Расходы' and v->'P'->>'v'='Комментарий' order by k::int limit 1;
 if header is null or exists(select 1 from jsonb_each(rows)r(k,v) where k::int between ctx.m_from and ctx.m_to and not locks ? k and (v->'T' ? 'f' or (v->'T'->>'v' is not null and v->'T'->>'v'<>''))) then
 insert into purchase_private.report_errors values(p_branch,p_day,'Столбец T занят или структура отчёта отличается: нужна проверка администратора') on conflict(branch_id,day) do update set error=excluded.error;return;end if;
 for rr in select k,v from jsonb_each(rows)r(k,v) where k::int between ctx.m_from and ctx.m_to loop
  if rr.k::int=header then cell:=coalesce(rr.v->'T','{}')||jsonb_build_object('v','Закупка','purchase_locked',true);
  elsif rr.v->'A'->>'v' ~ '^[0-9]+$' and (rr.v->'A'->>'v')::int between 30000 and 80000 then
   rd:=date '1899-12-30'+(rr.v->'A'->>'v')::int;
   select sum(qty*unit_price),count(*) filter(where unit_price is null),count(unit_price) into total,missing,known from purchase_private.received_lines where branch_id=p_branch and (received_at at time zone 'Europe/Moscow')::date=rd;
   cell:=(coalesce(rr.v->'T','{}')-'v'-'f')||jsonb_build_object('v',case when missing>0 and known=0 then null else coalesce(total,0) end,'purchase_locked',true,'purchase_missing_count',missing);
  elsif rr.k::int=ctx.m_to then
   select sum(qty*unit_price),count(*) filter(where unit_price is null),count(unit_price) into total,missing,known from purchase_private.received_lines where branch_id=p_branch and date_trunc('month',received_at at time zone 'Europe/Moscow')=date_trunc('month',p_day::timestamp);
   cell:=(coalesce(rr.v->'T','{}')-'v'-'f')||jsonb_build_object('v',case when missing>0 and known=0 then null else coalesce(total,0) end,'purchase_locked',true,'purchase_missing_count',missing);
  else continue;end if;
  rows:=jsonb_set(rows,array[rr.k],rr.v||jsonb_build_object('T',cell));locks:=locks||jsonb_build_object(rr.k,true);
 end loop;
 guard:=current_setting('purchase.receiving_write',true);perform set_config('purchase.receiving_write','1',true);
 update public.report_sheets set data=jsonb_set(jsonb_set(jsonb_set(data,'{rows}',rows),'{purchase_readonly_rows}',locks,true),'{ncols}',to_jsonb(greatest(20,coalesce((data->>'ncols')::int,20)))) ,updated_at=now() where id=s.id;
 perform set_config('purchase.receiving_write',coalesce(guard,''),true);
 delete from purchase_private.report_errors where branch_id=p_branch and day=p_day;
end $$;
create function purchase_private.report_guard() returns trigger language plpgsql security definer set search_path='' as $$
declare k text;
begin
 if coalesce(current_setting('purchase.receiving_write',true),'')='1' then return new;end if;
 for k in select jsonb_object_keys(coalesce(old.data->'purchase_readonly_rows','{}')) loop
  if old.data->'rows'->k->'T' is distinct from new.data->'rows'->k->'T' then raise exception 'Столбец «Закупка» заполняется автоматически и недоступен для редактирования';end if;
 end loop;
 if old.data->'purchase_readonly_rows' is distinct from new.data->'purchase_readonly_rows' then raise exception 'Защита столбца «Закупка» не может быть изменена вручную';end if;
 return new;
end $$;
create trigger purchase_report_guard before update of data on public.report_sheets for each row execute function purchase_private.report_guard();
create function purchase_private.month_added() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.branch_id is not null and (tg_op='INSERT' or new.months is distinct from old.months) then perform purchase_private.report_sync(new.branch_id,(now() at time zone 'Europe/Moscow')::date);end if;return new;
end $$;
create trigger purchase_month_added after insert or update of months on public.report_sheets for each row execute function purchase_private.month_added();

-- Keep the existing transactional Telegram queue and duplicate-request protection.
do $$declare def text;begin def:=pg_get_functiondef('public.purchase_finish(uuid,jsonb,text)'::regprocedure);def:=replace(def,'FUNCTION public.purchase_finish(','FUNCTION purchase_private.finish_before_receiving(');
 def:=replace(def,'''qty'',v_qty,','''qty'',v_qty,''unit'',x->>''unit'',');
 def:=replace(def,''' шт — ''',''' ''||coalesce(x->>''unit'',''шт'')||'' — ''');execute def;end $$;
create function purchase_private.finish(p_id uuid,p_lines jsonb,p_notes text default null) returns jsonb language plpgsql security definer set search_path='' as $$
declare x jsonb;req public.stock_requests;m public.stock_materials;lines jsonb:='[]';enriched jsonb:='[]';line jsonb;result jsonb;mid bigint;bid bigint;nm text;price numeric;factor numeric;lid uuid;pos integer:=0;guard text;
begin
 if not public.is_admin() then raise sqlstate 'PT403' using message='Закупку завершает только администратор';end if;
 if p_id is null then raise exception 'Нет номера закупки';end if;
 perform pg_advisory_xact_lock(hashtextextended('purchase-receiving:'||p_id::text,0));
 if exists(select 1 from public.purchase_batches where id=p_id) then return jsonb_build_object('id',p_id,'received',exists(select 1 from purchase_private.received_lines where batch_id=p_id));end if;
 if jsonb_typeof(p_lines)<>'array' or jsonb_array_length(p_lines) not between 1 and 500 then raise exception 'Добавьте товары закупки';end if;
 if exists(select 1 from jsonb_array_elements(p_lines) j where coalesce(j->>'purchase_receiving','')<>'1') then raise exception 'Обновите страницу (Ctrl + F5), чтобы оформить закупку с автоматическим приходом';end if;
 for x in select value from jsonb_array_elements(p_lines) loop
  req:=null;
  if x->>'request_id' is not null then select * into req from public.stock_requests where id=(x->>'request_id')::bigint for update;if not found or req.status='bought' then raise exception 'Заявка уже оформлена или удалена';end if;bid:=req.branch_id;nm:=req.name;
  else bid:=(x->>'branch_id')::bigint;nm:=btrim(x->>'name');end if;
  if not exists(select 1 from public.sales_branches where id=bid and is_active) or nullif(nm,'') is null then raise exception 'Укажите материал и филиал';end if;
  mid:=coalesce(nullif(x->>'material_id','')::bigint,req.material_id,(select material_id from public.purchase_catalog where id=req.supplier_item_id));
  if mid is null then
   perform pg_advisory_xact_lock(hashtextextended('purchase-material:'||lower(nm),0));
   select id into mid from public.stock_materials where lower(btrim(name))=lower(btrim(nm)) and not archived;
   if mid is null then insert into public.stock_materials(name,unit,is_active) values(nm,'шт',true) returning id into mid;end if;
  end if;
  select * into m from public.stock_materials where id=mid and not archived;
  if not found then raise exception 'Материал удалён. Выберите материал из списка';end if;
  factor:=case when m.pack_qty>0 then m.pack_qty else 1 end;
  price:=case when x ? 'unit_price' then nullif(x->>'unit_price','')::numeric else m.pack_price end;
  if price is not null and not(price>=0 and price<1000000000 and price=round(price,2)) then raise exception 'Цена должна быть неотрицательной с точностью до копеек';end if;
  if (x->>'qty')::numeric is null or not((x->>'qty')::numeric>0 and(x->>'qty')::numeric<=999999 and(x->>'qty')::numeric=round((x->>'qty')::numeric,3)) then raise exception 'Укажите купленное количество больше нуля';end if;
  lines:=lines||jsonb_build_array(x||jsonb_build_object('material_id',mid,'branch_id',bid,'name',nm,'unit_price',price,'factor',factor,'unit',case when m.pack_qty>0 then 'уп. по '||m.pack_qty||' '||m.unit else m.unit end));
 end loop;
 result:=purchase_private.finish_before_receiving(p_id,lines,p_notes);
 guard:=current_setting('purchase.receiving_write',true);perform set_config('purchase.receiving_write','1',true);
 for x in select value from jsonb_array_elements(lines) loop
  pos:=pos+1;price:=(x->>'unit_price')::numeric;
  insert into purchase_private.received_lines(batch_id,position,material_id,branch_id,name,unit,qty,factor,unit_price) values(p_id,pos,(x->>'material_id')::bigint,(x->>'branch_id')::bigint,x->>'name',x->>'unit',(x->>'qty')::numeric,(x->>'factor')::numeric,price) returning id into lid;
  insert into public.stock_moves(material_id,branch_id,qty,kind,group_id,price_total,comment,person_name,purchase_line_id) values((x->>'material_id')::bigint,(x->>'branch_id')::bigint,(x->>'qty')::numeric*(x->>'factor')::numeric,'receipt',p_id,(x->>'qty')::numeric*price,'Закупка администратора',coalesce((select name from public.staff_accounts where user_id=auth.uid()),'Администратор'),lid);
  if price is not null then update public.stock_materials set pack_price=price where id=(x->>'material_id')::bigint;end if;
  if x->>'request_id' is not null then
   update public.stock_requests set status='bought',closed_at=now(),material_id=(x->>'material_id')::bigint where id=(x->>'request_id')::bigint;
   update public.purchase_catalog set material_id=(x->>'material_id')::bigint where id=(select supplier_item_id from public.stock_requests where id=(x->>'request_id')::bigint);
  end if;
  select (public.purchase_batches.lines->(pos-1))||jsonb_build_object('material_id',x->'material_id','unit',x->'unit','factor',x->'factor','unit_price',price,'total',(x->>'qty')::numeric*price,'received',true) into line from public.purchase_batches where id=p_id;
  enriched:=enriched||jsonb_build_array(line);
 end loop;
 update public.purchase_batches set lines=enriched where id=p_id;
 perform set_config('purchase.receiving_write',coalesce(guard,''),true);
 for bid in select distinct (j->>'branch_id')::bigint from jsonb_array_elements(lines)j loop perform purchase_private.report_sync(bid,(now() at time zone 'Europe/Moscow')::date);end loop;
 return result||jsonb_build_object('received',true,'missing_prices',(select count(*) from purchase_private.received_lines where batch_id=p_id and unit_price is null));
end $$;
create or replace function public.purchase_finish(p_id uuid,p_lines jsonb,p_notes text default null) returns jsonb language sql security invoker set search_path='' as $$select purchase_private.finish(p_id,p_lines,p_notes)$$;

create function purchase_private.prices(p_line uuid,p_price numeric,p_version integer) returns boolean language plpgsql security definer set search_path='' as $$
declare r purchase_private.received_lines;guard text;line jsonb;updated_lines jsonb;
begin
 if not public.is_admin() then raise sqlstate 'PT403' using message='Цены закупки меняет только администратор';end if;
 if p_price is not null and not(p_price>=0 and p_price<1000000000 and p_price=round(p_price,2)) then raise exception 'Укажите корректную цену за единицу';end if;
 select * into r from purchase_private.received_lines where id=p_line for update;
 if not found or r.version is distinct from p_version then raise exception 'Цена уже изменена. Обновите историю закупок';end if;
 update purchase_private.received_lines set unit_price=p_price,version=version+1 where id=r.id;
 insert into purchase_private.price_audit(line_id,actor,before_price,after_price) values(r.id,auth.uid(),r.unit_price,p_price);
 guard:=current_setting('purchase.receiving_write',true);perform set_config('purchase.receiving_write','1',true);
 update public.stock_moves set price_total=r.qty*p_price where purchase_line_id=r.id;
 perform set_config('purchase.receiving_write',coalesce(guard,''),true);
 select jsonb_agg(case when ord=r.position then j||jsonb_build_object('unit_price',p_price,'total',r.qty*p_price) else j end order by ord) into updated_lines from public.purchase_batches b cross join lateral jsonb_array_elements(b.lines)with ordinality a(j,ord) where b.id=r.batch_id;
 update public.purchase_batches set lines=updated_lines where id=r.batch_id;
 if p_price is not null then update public.stock_materials set pack_price=p_price where id=r.material_id;end if;
 perform purchase_private.report_sync(r.branch_id,(r.received_at at time zone 'Europe/Moscow')::date);return true;
end $$;
create function public.purchase_set_price(p_line uuid,p_unit_price numeric,p_version integer) returns boolean language sql security invoker set search_path='' as $$select purchase_private.prices(p_line,p_unit_price,p_version)$$;
create function purchase_private.history() returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if not public.is_admin() then raise sqlstate 'PT403' using message='История закупок доступна администратору';end if;
 return coalesce((select jsonb_agg(to_jsonb(b)||jsonb_build_object('received_lines',coalesce((select jsonb_agg(to_jsonb(r)||jsonb_build_object('total',qty*unit_price) order by position) from purchase_private.received_lines r where batch_id=b.id),'[]'),'report_errors',coalesce((select jsonb_agg(to_jsonb(e)) from purchase_private.report_errors e where e.branch_id in(select branch_id from purchase_private.received_lines where batch_id=b.id) and e.day=(b.created_at at time zone 'Europe/Moscow')::date),'[]')) order by b.created_at desc) from(select id,created_at,message from public.purchase_batches order by created_at desc limit 50)b),'[]');
end $$;
create function public.purchase_receiving_history() returns jsonb language sql security invoker set search_path='' as $$select purchase_private.history()$$;
revoke all on all functions in schema purchase_private from public,anon;
revoke all on function purchase_private.finish_before_receiving(uuid,jsonb,text),purchase_private.report_sync(bigint,date),purchase_private.move_guard(),purchase_private.report_guard(),purchase_private.month_added() from authenticated;
grant execute on function purchase_private.finish(uuid,jsonb,text),purchase_private.prices(uuid,numeric,integer),purchase_private.history() to authenticated;
revoke all on function public.purchase_set_price(uuid,numeric,integer),public.purchase_receiving_history() from public,anon;
grant execute on function public.purchase_set_price(uuid,numeric,integer),public.purchase_receiving_history() to authenticated;
-- Initialise the current month only; old completed purchases never create retroactive receipts.
do $$declare b bigint;begin for b in select distinct branch_id from public.report_sheets where branch_id is not null loop perform purchase_private.report_sync(b,(now() at time zone 'Europe/Moscow')::date);end loop;end $$;
notify pgrst,'reload schema';
