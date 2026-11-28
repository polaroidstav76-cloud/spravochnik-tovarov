CREATE OR REPLACE FUNCTION public.purchase_finish(p_id uuid, p_lines jsonb, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare x jsonb; req record; v_qty numeric; v_branch text; v_code text; v_name text; result jsonb:='[]'; msg text; body text; chunk text; ln text; tok text; recipient record; ids bigint[]:='{}'; existing record; requested_before jsonb;
begin
if not public.is_admin() then raise exception 'Только администратор'; end if;
perform pg_advisory_xact_lock(hashtextextended(p_id::text,0));
select * into existing from public.purchase_batches where id=p_id;
if found then return jsonb_build_object('id',p_id,'message',existing.message,'requests',existing.telegram_requests); end if;
if jsonb_typeof(p_lines)<>'array' or jsonb_array_length(p_lines)=0 or jsonb_array_length(p_lines)>500 then raise exception 'Добавьте заказанные товары'; end if;
if length(coalesce(p_notes,''))>3000 then raise exception 'Примечание слишком длинное'; end if;

 select coalesce(jsonb_agg(to_jsonb(r) order by r.id),'[]'::jsonb) into requested_before from public.stock_requests r where r.status<>'bought';
 for x in select value from jsonb_array_elements(p_lines) loop

v_qty:=(x->>'qty')::numeric;
if v_qty is null or v_qty<=0 or v_qty>999999 or v_qty<>round(v_qty,3) then raise exception 'Укажите количество больше нуля'; end if;
if x->>'request_id' is not null then
select * into req from public.stock_requests where id=(x->>'request_id')::bigint for update;
if not found or req.status='bought' then raise exception 'Заявка уже закрыта или не найдена. Обновите список'; end if;

v_code:=coalesce(req.supplier_code,(select purchase_code from public.stock_materials where id=req.material_id),'Без кода');v_name:=req.name;
select name into v_branch from public.sales_branches where id=req.branch_id;
update public.stock_requests set ordered_qty=ordered_qty+v_qty,status=case when qty is null or ordered_qty+v_qty>=qty then 'bought' else 'open' end,closed_at=case when qty is null or ordered_qty+v_qty>=qty then now() else null end where id=req.id;
else
v_code:=nullif(trim(x->>'code'),'');v_name:=nullif(trim(x->>'name'),'');
select name into v_branch from public.sales_branches where id=(x->>'branch_id')::bigint;
if v_name is null or v_branch is null or length(v_name)>250 or length(coalesce(v_code,''))>50 then raise exception 'Укажите название и филиал ручной позиции'; end if;
end if;
result:=result||jsonb_build_array(jsonb_build_object('code',coalesce(v_code,'Без кода'),'name',v_name,'branch',coalesce(v_branch,'Без филиала'),'qty',v_qty,'branch_id',case when x->>'request_id' is not null then req.branch_id else (x->>'branch_id')::bigint end,'request_id',x->>'request_id'));
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
insert into public.purchase_batches(id,created_by,lines,notes,message,telegram_requests) values(p_id,auth.uid(),result,p_notes,msg,ids); update public.purchase_batches set requested_snapshot=requested_before where id=p_id;
return jsonb_build_object('id',p_id,'message',msg,'requests',ids);
end $function$
;
CREATE OR REPLACE FUNCTION public.report_day_row(p_branch_id bigint, p_day date, OUT sheet_id bigint, OUT row_no integer, OUT m_from integer, OUT m_to integer)
 RETURNS record
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_sheet public.report_sheets; v_month jsonb; v_serial int:=p_day-date '1899-12-30';
begin
  select * into v_sheet from public.report_sheets s where s.branch_id=p_branch_id order by s.sort_order limit 1;
  if not found then raise exception 'Для этого филиала нет листа в общем отчете'; end if;
  select m into v_month from jsonb_array_elements(v_sheet.months) m where m->>'m'=to_char(p_day,'YYYY-MM') limit 1;
  if v_month is null then raise exception 'В общем отчете нет месяца %', to_char(p_day,'MM.YYYY'); end if;
  sheet_id:=v_sheet.id; m_from:=(v_month->>'from')::int; m_to:=(v_month->>'to')::int;
  select k::int into row_no from jsonb_each(v_sheet.data->'rows') as r(k,v)
   where k::int between m_from and m_to and v->'A'->>'v'=v_serial::text limit 1;
  if row_no is null then raise exception 'В общем отчете нет строки на %', to_char(p_day,'DD.MM.YYYY'); end if;
end $function$
;
CREATE OR REPLACE FUNCTION public.report_put_row(p_sheet_id bigint, p_row integer, p_vals jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_row jsonb; v_cell jsonb; k text; val jsonb;
begin
  select coalesce(data->'rows'->(p_row::text),'{}'::jsonb) into v_row from public.report_sheets where id=p_sheet_id for update;
  for k,val in select * from jsonb_each(p_vals) loop
    v_cell:=coalesce(v_row->k,'{}'::jsonb)-'v'-'f';
    if val is not null and jsonb_typeof(val)<>'null' then v_cell:=v_cell||jsonb_build_object('v',val); end if;
    if v_cell='{}'::jsonb then v_row:=v_row-k; else v_row:=v_row||jsonb_build_object(k,v_cell); end if;
  end loop;
  update public.report_sheets set data=jsonb_set(data,array['rows',p_row::text],v_row,true), updated_at=now() where id=p_sheet_id;
end $function$
;
