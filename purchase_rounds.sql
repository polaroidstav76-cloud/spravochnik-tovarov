begin;
create table if not exists public.purchase_catalog(id bigserial primary key,code text not null unique,name text not null,active boolean not null default true);
alter table public.purchase_catalog enable row level security;
grant select on public.purchase_catalog to authenticated;
create policy purchase_catalog_read on public.purchase_catalog for select to authenticated using(public.is_staff());
create policy purchase_catalog_admin on public.purchase_catalog for all to authenticated using(public.is_admin()) with check(public.is_admin());
grant insert,update on public.purchase_catalog to authenticated;
grant usage,select on sequence public.purchase_catalog_id_seq to authenticated;
create table public.purchase_batches(id uuid primary key,created_at timestamptz not null default now(),created_by uuid not null,lines jsonb not null,notes text,message text not null,telegram_requests bigint[] not null default '{}');
alter table public.purchase_batches enable row level security;
grant select on public.purchase_batches to authenticated;
create policy purchase_batches_admin on public.purchase_batches for select to authenticated using(public.is_admin());
alter table public.stock_requests add column if not exists supplier_item_id bigint references public.purchase_catalog(id);
alter table public.stock_requests add column if not exists ordered_qty numeric not null default 0;
alter table public.stock_requests add column if not exists supplier_code text;
create or replace function public.purchase_request_add(p_shift_id bigint,p_person_id bigint,p_branch_id bigint,p_item_id bigint,p_qty numeric,p_urgent boolean default false,p_comment text default null) returns bigint
language plpgsql security definer set search_path='' as $$
declare a record; item record; rid bigint; dest bigint:=p_branch_id;
begin
if not public.is_staff() then raise exception 'Требуется вход'; end if;
select * into a from public.stock_actor(p_shift_id,p_person_id);
if not a.is_admin and dest is distinct from a.branch_id and dest is distinct from public.stock_workshop_id() then raise exception 'Выберите свой филиал'; end if;
if dest is null or not exists(select 1 from public.sales_branches where id=dest) then raise exception 'Выберите филиал'; end if;
if p_qty is null or p_qty<=0 or p_qty>999999 or p_qty<>round(p_qty,3) then raise exception 'Укажите положительное количество'; end if;
select * into item from public.purchase_catalog where id=p_item_id and active;
if not found then raise exception 'Товар недоступен'; end if;
insert into public.stock_requests(branch_id,person_name,name,qty,urgent,comment,supplier_item_id,supplier_code) values(dest,a.person_name,item.name,p_qty,p_urgent,nullif(trim(p_comment),''),item.id,item.code) returning id into rid;
return rid;
end $$;
revoke all on function public.purchase_request_add(bigint,bigint,bigint,bigint,numeric,boolean,text) from public,anon;
grant execute on function public.purchase_request_add(bigint,bigint,bigint,bigint,numeric,boolean,text) to authenticated;
create or replace function public.purchase_finish(p_id uuid,p_lines jsonb,p_notes text default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare x jsonb; req record; v_qty numeric; v_branch text; v_code text; v_name text; result jsonb:='[]'; msg text; body text; chunk text; ln text; tok text; recipient record; ids bigint[]:='{}'; existing record;
begin
if not public.is_admin() then raise exception 'Только администратор'; end if;
perform pg_advisory_xact_lock(hashtextextended(p_id::text,0));
select * into existing from public.purchase_batches where id=p_id;
if found then return jsonb_build_object('id',p_id,'message',existing.message,'requests',existing.telegram_requests); end if;
if jsonb_typeof(p_lines)<>'array' or jsonb_array_length(p_lines)=0 or jsonb_array_length(p_lines)>500 then raise exception 'Добавьте заказанные товары'; end if;
if length(coalesce(p_notes,''))>3000 then raise exception 'Примечание слишком длинное'; end if;
for x in select value from jsonb_array_elements(p_lines) loop
v_qty:=(x->>'qty')::numeric;
if v_qty is null or v_qty<=0 or v_qty>999999 or v_qty<>round(v_qty,3) then raise exception 'Укажите количество больше нуля'; end if;
if x->>'request_id' is not null then
select * into req from public.stock_requests where id=(x->>'request_id')::bigint for update;
if not found or req.status='bought' then raise exception 'Заявка уже закрыта или не найдена. Обновите список'; end if;
if req.qty is not null and v_qty>greatest(req.qty-req.ordered_qty,0) then raise exception 'Заказано больше остатка заявки'; end if;
v_code:=coalesce(req.supplier_code,(select purchase_code from public.stock_materials where id=req.material_id),'Без кода');v_name:=req.name;
select name into v_branch from public.sales_branches where id=req.branch_id;
update public.stock_requests set ordered_qty=ordered_qty+v_qty,status=case when qty is null or ordered_qty+v_qty>=qty then 'bought' else 'open' end,closed_at=case when qty is null or ordered_qty+v_qty>=qty then now() else null end where id=req.id;
else
v_code:=nullif(trim(x->>'code'),'');v_name:=nullif(trim(x->>'name'),'');
select name into v_branch from public.sales_branches where id=(x->>'branch_id')::bigint;
if v_name is null or v_branch is null or length(v_name)>250 or length(coalesce(v_code,''))>50 then raise exception 'Укажите название и филиал ручной позиции'; end if;
end if;
result:=result||jsonb_build_array(jsonb_build_object('code',coalesce(v_code,'Без кода'),'name',v_name,'branch',coalesce(v_branch,'Без филиала'),'qty',v_qty));
end loop;
msg:='🛒 Закупка окончена · '||to_char(now() at time zone 'Europe/Moscow','DD.MM.YYYY HH24:MI')||E'\n';
for x in select value from jsonb_array_elements(result) loop
msg:=msg||E'\n'||(x->>'code')||' — '||(x->>'qty')||' шт — '||(x->>'branch')||E'\n'||(x->>'name')||E'\n';
end loop;
if nullif(trim(p_notes),'') is not null then msg:=msg||E'\nДополнительно: '||p_notes; end if;
select decrypted_secret into tok from vault.decrypted_secrets where name='telegram_bot_token';
if tok is null or not exists(select 1 from public.report_recipients where active) then raise exception 'Не настроена отправка Telegram'; end if;
for recipient in select chat_id from public.report_recipients where active loop
chunk:='';
foreach ln in array string_to_array(msg,E'\n') loop
if length(chunk)+length(ln)+1>3900 then
ids:=array_append(ids,net.http_post(url:='https://api.telegram.org/bot'||tok||'/sendMessage',headers:='{"Content-Type":"application/json"}'::jsonb,body:=jsonb_build_object('chat_id',recipient.chat_id,'text',chunk)));
chunk:='';end if;
chunk:=chunk||ln||E'\n';
end loop;
if chunk<>'' then ids:=array_append(ids,net.http_post(url:='https://api.telegram.org/bot'||tok||'/sendMessage',headers:='{"Content-Type":"application/json"}'::jsonb,body:=jsonb_build_object('chat_id',recipient.chat_id,'text',chunk)));end if;
end loop;
insert into public.purchase_batches(id,created_by,lines,notes,message,telegram_requests) values(p_id,auth.uid(),result,p_notes,msg,ids);
return jsonb_build_object('id',p_id,'message',msg,'requests',ids);
end $$;
revoke all on function public.purchase_finish(uuid,jsonb,text) from public,anon;
grant execute on function public.purchase_finish(uuid,jsonb,text) to authenticated;
insert into public.purchase_catalog(code,name) values ('7789','Глянец 10х15, 230 г/м перфео, 500 листов (плотная)'),('7790','Мат 10х15, 230 гр/м2,перфео, 100 листов (плотная)'),('8555','Сатин 10х15, 270 гр/м2, Перфео, 100 листов (плотная)'),('4670','Глянец 21х30, 230 гр/м2, Перфео, 100 листов (плотная)'),('4677','Мат 21х30, 230 гр/м2, Перфео, 100 листов (плотная)'),('6619','Глянец, 21х30, 115 гр/м2, Перфео, 100 листов (Тонкая)'),('4813','Глянец, 21х30 двусторонняя, 220 гр/м2, 50 листов (плотная)'),('4812','Глянец, 21х30, двусторонняя 130 гр/м2, 50 листов (Тонкая)'),('3087','Серебро, 21х30 (односторонняя и двусторонняя, 260 гр/м2, 50 листов (плотная)'),('6786','Пленка для ламинации, 21х30, 80 мкм, 100 листов'),('9019','Самоклейка 21х30, 128 гр, 100 листов (плотная)'),('4679','Чернила BK черный 0,5л'),('4680','Чернила С голубой 0,5л'),('4681','Чернила LC светло-голубой 0,5л'),('4682','Чернила LM светло- пурпурный 0,5л'),('4683','Чернила M пурпурный 0,5л'),('4684','Чернила Y желтый 0,5л'),('8483','Рамка 10х15 белая'),('8466','Рамка 10х15 черная'),('1224','Рамка 40х60 черная'),('4475','Рамка 40х60 белая'),('6308','Рамка 15х21 белая'),('6831','Рамка 15х21 черная'),('5483','Рамка 30х40 белая'),('1223','Рамка 30х40 черная'),('1314','Рамка 40х50 сосна'),('6201','Рамка 40х50 черная'),('6250','Рамка 21х30 белая с ножкой'),('6206','Рамка 21х30 черная с ножкой'),('1875','Рамка 50х70 сосна'),('5976','Фотобумага А3 глянец 230 гр (50 листов)') on conflict(code) do nothing;

create or replace function public.telegram_purchase_data(p_chat_id bigint) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
if not exists(select 1 from public.report_recipients where chat_id=p_chat_id and active) then return null; end if;
return (select coalesce(jsonb_agg(jsonb_build_object('id',r.id,'name',r.name,'qty',case when r.qty is null then null else greatest(r.qty-r.ordered_qty,0) end,'unit',coalesce(m.unit,'шт'),'code',coalesce(r.supplier_code,m.purchase_code),'branch',b.name,'urgent',r.urgent,'comment',r.comment) order by r.urgent desc,r.created_at,r.id),'[]'::jsonb) from public.stock_requests r left join public.stock_materials m on m.id=r.material_id left join public.sales_branches b on b.id=r.branch_id where r.status<>'bought');
end $$;
revoke all on function public.telegram_purchase_data(bigint) from public,anon,authenticated;
grant execute on function public.telegram_purchase_data(bigint) to service_role;
create or replace function public.purchase_delivery_status(p_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare ids bigint[]; good int; bad int;
begin
if not public.is_admin() then raise exception 'Только администратор'; end if;
select telegram_requests into ids from public.purchase_batches where id=p_id;
select count(*) filter(where status_code=200 and content::jsonb->>'ok'='true'),count(*) filter(where status_code<>200 or error_msg is not null or content::jsonb->>'ok'='false') into good,bad from net._http_response where id=any(ids);
return jsonb_build_object('sent',good,'failed',bad,'total',cardinality(ids));
end $$;
revoke all on function public.purchase_delivery_status(uuid) from public,anon;
grant execute on function public.purchase_delivery_status(uuid) to authenticated;
commit;
