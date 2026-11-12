CREATE OR REPLACE FUNCTION public.sales_update_pickup(p_pickup_id bigint, p_shift_id bigint, p_employee_id bigint, p_items jsonb, p_discount_percent numeric DEFAULT 0, p_comment text DEFAULT NULL::text, p_customer_id uuid DEFAULT NULL::uuid, p_client_name text DEFAULT NULL::text, p_client_phone text DEFAULT NULL::text, p_client_order_ref text DEFAULT NULL::text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_shift public.sales_shifts%rowtype; v_item jsonb; v_cat public.sales_catalog%rowtype;
  v_qty numeric(12,3); v_price numeric(12,2); v_line numeric(12,2); v_gross numeric(12,2):=0; v_total numeric(12,2);
  v_o public.pickup_orders%rowtype; v_items jsonb:='[]'::jsonb; v_min bigint; v_order bigint;
begin
  if not public.is_staff() then raise exception 'Требуется вход сотрудника'; end if;
  select * into v_shift from public.sales_shifts where id=p_shift_id and status='open' for update;
  if not found then raise exception 'Смена не найдена или уже закрыта'; end if;
  if not exists(select 1 from public.sales_shift_employees where shift_id=p_shift_id and employee_id=p_employee_id) then raise exception 'Сотрудник не подключён к этой смене'; end if;
  if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then raise exception 'Добавьте хотя бы одну позицию'; end if;
  if coalesce(p_discount_percent,0)<0 or coalesce(p_discount_percent,0)>100 then raise exception 'Скидка должна быть от 0 до 100%%'; end if;
  for v_item in select * from jsonb_array_elements(p_items) loop
    select * into v_cat from public.sales_catalog where id=(v_item->>'catalog_id')::bigint and is_active=true;
    if not found then raise exception 'Товар или услуга не найдены'; end if;
    v_qty:=coalesce((v_item->>'quantity')::numeric,0); v_price:=coalesce((v_item->>'unit_price')::numeric,v_cat.price);
    if v_qty<=0 or v_price<0 then raise exception 'Некорректное количество или цена'; end if;
    v_line:=round(v_qty*v_price,2); v_gross:=v_gross+v_line;
    v_items:=v_items||jsonb_build_array(jsonb_build_object('catalog_id',v_cat.id,'name',v_cat.name,'item_type',v_cat.item_type,'quantity',v_qty,'unit_price',v_price,'line_total',v_line,'variant_material_id',v_item->'variant_material_id'));
  end loop;
  v_total:=round(v_gross-round(v_gross*coalesce(p_discount_percent,0)/100,2),2);
  select * into v_o from public.pickup_orders where id=p_pickup_id for update;
  if not found or v_o.status<>'pending' then raise exception 'Заказ уже оплачен или отменён'; end if;
  update public.pickup_orders set items=v_items,gross_total=v_gross,discount_percent=coalesce(p_discount_percent,0),total=v_total,
    comment=nullif(trim(coalesce(p_comment,'')),''),
    customer_id=coalesce(p_customer_id,v_o.customer_id),
    client_name=coalesce(nullif(trim(p_client_name),''),v_o.client_name),
    client_phone=coalesce(nullif(trim(p_client_phone),''),v_o.client_phone),
    client_order_ref=nullif(trim(coalesce(p_client_order_ref,'')),'')
  where id=p_pickup_id;
  return v_o.order_number;
end $function$;

CREATE OR REPLACE FUNCTION public.stock_operation(p_shift_id bigint, p_person_id bigint, p_kind text, p_branch_id bigint, p_items jsonb, p_to_branch_id bigint DEFAULT NULL::bigint, p_supplier text DEFAULT NULL::text, p_comment text DEFAULT NULL::text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare a record; it jsonb; v_m bigint; v_q numeric; v_bal numeric; v_g uuid:=gen_random_uuid(); v_n int:=0; v_name text;
begin
  if not public.is_staff() then raise exception 'Требуется вход сотрудника'; end if;
  select * into a from public.stock_actor(p_shift_id,p_person_id);
  if p_kind not in ('receipt','transfer','writeoff','inventory') then raise exception 'Неизвестная операция'; end if;
  if p_branch_id is null or not exists(select 1 from public.sales_branches where id=p_branch_id) then raise exception 'Выберите филиал'; end if;
  if p_kind='transfer' then
    if p_to_branch_id is null or p_to_branch_id=p_branch_id or not exists(select 1 from public.sales_branches where id=p_to_branch_id) then raise exception 'Выберите, в какой филиал передаёте'; end if;
    if not a.is_admin and a.branch_id not in (p_branch_id,p_to_branch_id) and coalesce(public.stock_workshop_id(),0) not in (p_branch_id,p_to_branch_id) then raise exception 'Перемещение должно быть с вашего филиала или на ваш филиал'; end if;
  elsif not a.is_admin and a.branch_id<>p_branch_id and p_branch_id<>coalesce(public.stock_workshop_id(),0) then raise exception 'Сотрудник смены работает только со складом своего филиала';
  end if;
  if p_kind='writeoff' and nullif(trim(coalesce(p_comment,'')),'') is null then raise exception 'Укажите причину списания'; end if;
  for it in select * from jsonb_array_elements(coalesce(p_items,'[]')) loop
    v_m:=(it->>'material_id')::bigint; v_q:=nullif(it->>'qty','')::numeric;
    if v_m is null and p_kind='receipt' then
      v_name:=nullif(btrim(it->>'name'),'');
      if v_name is null or length(v_name)>250 then raise exception 'Укажите название товара (до 250 символов)'; end if;
      if v_q is null or v_q<=0 then raise exception 'Количество должно быть больше нуля'; end if;
      perform pg_advisory_xact_lock(hashtext('stock-material:'||lower(v_name)));
      select id into v_m from public.stock_materials where lower(btrim(name))=lower(v_name) order by id limit 1;
      if v_m is null then
        insert into public.stock_materials(name,unit,min_qty,is_active) values(v_name,'шт',0,true) returning id into v_m;
      end if;
    end if;
    if v_m is null or v_q is null then raise exception 'Укажите материал и количество для каждой строки'; end if;
    if not exists(select 1 from public.stock_materials where id=v_m) then raise exception 'Материал не найден'; end if;
    if p_kind='inventory' then
      if v_q<0 then raise exception 'Количество не может быть отрицательным'; end if;
      perform pg_advisory_xact_lock(hashtext('stock:'||v_m||':'||p_branch_id));
      select coalesce(sum(qty),0) into v_bal from public.stock_moves where material_id=v_m and branch_id=p_branch_id and cancelled_at is null;
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
end $function$
;
revoke all on function public.sales_update_pickup(bigint,bigint,bigint,jsonb,numeric,text,uuid,text,text,text) from public,anon;
grant execute on function public.sales_update_pickup(bigint,bigint,bigint,jsonb,numeric,text,uuid,text,text,text) to authenticated;
notify pgrst, 'reload schema';

