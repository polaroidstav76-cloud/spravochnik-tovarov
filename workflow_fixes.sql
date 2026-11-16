-- Club-card integrity and receipt-to-report accounting. Existing histories remain intact.
set lock_timeout='5s';
create schema if not exists workflow_private;
revoke all on schema workflow_private from public,anon;
grant usage on schema workflow_private to authenticated;

create or replace function public.loyalty_normalize_phone(p_phone text) returns text language sql immutable strict set search_path='' as $$
 select case when d~'^[78]+9[0-9]{9}$' or d~'^9[0-9]{9}$' then '7'||right(d,10) else d end from(select regexp_replace(p_phone,'[^0-9]','','g') d) q;
$$;
alter table public.loyalty_customers add column if not exists created_by_name text;
alter table public.loyalty_customers add column if not exists created_by_source text;
alter table public.loyalty_customers add column if not exists created_by_account_id uuid;
create index if not exists loyalty_phone_canonical_lookup on public.loyalty_customers(public.loyalty_normalize_phone(phone));
create index if not exists loyalty_phone_suffix_lookup on public.loyalty_customers(right(regexp_replace(phone,'[^0-9]','','g'),4));
create index if not exists loyalty_creation_lookup on public.loyalty_customers(created_at);

create or replace function workflow_private.card_guard() returns trigger language plpgsql security definer set search_path='' as $$
declare normalized text; account_person bigint; account_name text; account_role text; context_person bigint;
begin
 if TG_OP='INSERT' or new.phone is distinct from old.phone then
  normalized:=public.loyalty_normalize_phone(new.phone);
  perform pg_advisory_xact_lock(hashtext('loyalty-phone:'||normalized));
  if TG_OP='INSERT' and exists(select 1 from public.loyalty_customers c where c.phone=new.phone) then
   null; -- Exact-key UPSERT cannot create a second row. Registration APIs preserve existing details.
  else
   if normalized!~'^79[0-9]{9}$' then raise exception 'Введите полный мобильный номер: +7 и 10 цифр, начиная с 9';end if;
   if exists(select 1 from public.loyalty_customers c where public.loyalty_normalize_phone(c.phone)=normalized and (TG_OP='INSERT' or c.id<>new.id)) then raise exception 'Карта с таким номером уже существует. Найдите и выберите клиента.';end if;
   new.phone:=normalized;
  end if;
 end if;
 if TG_OP='UPDATE' and (old.created_by_employee_id is not null or old.created_by_name is not null) then
  new.created_by_employee_id:=old.created_by_employee_id;
  new.created_by_name:=coalesce(old.created_by_name,(select p.name from public.sales_people p where p.id=old.created_by_employee_id));
  new.created_by_source:=coalesce(old.created_by_source,'recorded');
  new.created_by_account_id:=old.created_by_account_id;
 else
  if TG_OP='UPDATE' and new.created_by_employee_id is null and new.created_by_name is null then return new;end if;
  select a.person_id,a.name,a.role into account_person,account_name,account_role from public.staff_accounts a where a.user_id=auth.uid() and a.active;
  context_person:=nullif(current_setting('workflow.creator_person',true),'')::bigint;
  if account_role='staff' and account_person is not null then new.created_by_employee_id:=account_person;
  elsif new.created_by_employee_id is null then new.created_by_employee_id:=coalesce(context_person,account_person);end if;
  new.created_by_name:=coalesce((select p.name from public.sales_people p where p.id=new.created_by_employee_id),new.created_by_name,account_name);
  new.created_by_account_id:=coalesce(new.created_by_account_id,auth.uid());
  new.created_by_source:=coalesce(new.created_by_source,case when new.created_by_name is not null then 'recorded' end);
 end if;
 return new;
end $$;
revoke all on function workflow_private.card_guard() from public,anon,authenticated;
create trigger workflow_card_guard before insert or update on public.loyalty_customers for each row execute function workflow_private.card_guard();

-- Restore only cases supported by an unambiguous sale at the exact creation timestamp.
with evidence as(
 select c.id,min(e.person_id) as person_id
 from public.loyalty_customers c join public.sales s on s.loyalty_customer_id=c.id and s.created_at=c.created_at
 join public.sales_employees e on e.id=s.employee_id
 where c.created_by_employee_id is null and e.person_id is not null
 group by c.id having count(distinct e.person_id)=1
)
update public.loyalty_customers c set created_by_employee_id=e.person_id,created_by_name=p.name,created_by_source='first_sale'
 from evidence e join public.sales_people p on p.id=e.person_id where c.id=e.id;
update public.loyalty_customers c set created_by_name=p.name,created_by_source='recorded' from public.sales_people p where c.created_by_employee_id=p.id and c.created_by_name is null;

create function workflow_private.creator(p_customer_id uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if auth.uid() is null or not public.is_staff() then raise sqlstate 'PT403' using message='Требуется вход сотрудника';end if;
 return (select jsonb_build_object('customer_name',c.name,'customer_phone',c.phone,'name',coalesce(c.created_by_name,p.name,'Автор не указан'),'created_at',c.created_at,'source',c.created_by_source) from public.loyalty_customers c left join public.sales_people p on p.id=c.created_by_employee_id where c.id=p_customer_id);
end $$;
create function public.workflow_card_creator(p_customer_id uuid) returns jsonb language sql security invoker set search_path='' as $$ select workflow_private.creator(p_customer_id); $$;
create function workflow_private.card_stats(p_from date,p_to date) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb; previous_from date:=p_from-(p_to-p_from+1);
begin
 if auth.uid() is null or not public.is_admin() then raise sqlstate 'PT403' using message='Только администратор';end if;
 if p_to<p_from or p_to-p_from>730 then raise exception 'Выберите период не более двух лет';end if;
 with counts as(
 select coalesce(c.created_by_employee_id::text,'name:'||c.created_by_name,'unknown') as key,
 max(coalesce(p.name,c.created_by_name,'Автор не указан')) as name,
 count(*) filter(where (c.created_at at time zone 'Europe/Moscow')::date between p_from and p_to) as current_count,
 count(*) filter(where (c.created_at at time zone 'Europe/Moscow')::date between previous_from and p_from-1) as previous_count
 from public.loyalty_customers c left join public.sales_people p on p.id=c.created_by_employee_id
 where c.created_at>=(previous_from::timestamp at time zone 'Europe/Moscow') and c.created_at<((p_to+1)::timestamp at time zone 'Europe/Moscow') group by coalesce(c.created_by_employee_id::text,'name:'||c.created_by_name,'unknown')
 ), authors as(select key,name from counts union select p.id::text,p.name from public.sales_people p where p.is_active), rows as(
 select a.key,a.name,coalesce(c.current_count,0) as current_count,coalesce(c.previous_count,0) as previous_count from authors a left join counts c using(key,name))
 select jsonb_build_object('from',p_from,'to',p_to,'previous_from',previous_from,'previous_to',p_from-1,'total',coalesce(sum(current_count),0),'previous_total',coalesce(sum(previous_count),0),'unknown',coalesce(sum(current_count) filter(where key='unknown'),0),'rows',coalesce(jsonb_agg(to_jsonb(rows) order by current_count desc,name),'[]'::jsonb)) into result from rows;
 return result;
end $$;
create function public.workflow_card_stats(p_from date,p_to date) returns jsonb language sql security invoker set search_path='' as $$ select workflow_private.card_stats(p_from,p_to); $$;
revoke all on function workflow_private.creator(uuid),workflow_private.card_stats(date,date),public.workflow_card_creator(uuid),public.workflow_card_stats(date,date) from public,anon,authenticated;
grant execute on function workflow_private.creator(uuid),workflow_private.card_stats(date,date),public.workflow_card_creator(uuid),public.workflow_card_stats(date,date) to authenticated;

create or replace function public.sales_cancel_pickup(p_pickup_id bigint,p_reason text default null) returns boolean language plpgsql security definer set search_path='' as $$
declare target_branch bigint;
begin
 if auth.uid() is null or not public.is_staff() then raise sqlstate 'PT403' using message='Требуется вход сотрудника';end if;
 select branch_id into target_branch from public.pickup_orders where id=p_pickup_id and status='pending' for update;
 if not found then raise exception 'Заказ не найден или уже закрыт';end if;
 if not public.is_admin() and not exists(select 1 from public.staff_accounts a join public.sales_employees e on e.person_id=a.person_id join public.sales_shift_employees se on se.employee_id=e.id join public.sales_shifts s on s.id=se.shift_id where a.user_id=auth.uid() and a.active and s.status='open' and s.branch_id=target_branch) then raise sqlstate 'PT403' using message='Удалить заказ может сотрудник смены этого филиала или администратор';end if;
 if nullif(btrim(p_reason),'') is null then raise exception 'Укажите причину удаления';end if;
 update public.pickup_orders set status='cancelled',cancelled_at=now(),cancel_reason=btrim(p_reason) where id=p_pickup_id;
 return true;
end $$;
revoke all on function public.sales_cancel_pickup(bigint,text) from public,anon;
grant execute on function public.sales_cancel_pickup(bigint,text) to authenticated;

do $$ begin if md5(rtrim(replace(pg_get_functiondef('public.loyalty_register_customer(text,text,text,bigint)'::regprocedure),chr(13),''),E'\n'))<>'6dfff892b7086f93abde5609414b6f7d' then raise exception 'Function changed during review: public.loyalty_register_customer(text,text,text,bigint)';end if;end $$;

CREATE OR REPLACE FUNCTION public.loyalty_register_customer(p_name text, p_phone text, p_comment text DEFAULT NULL::text, p_created_by_employee_id bigint DEFAULT NULL::bigint)
 RETURNS TABLE(customer_id uuid, customer_name text, customer_phone text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_customer public.loyalty_customers%rowtype;
begin
  if not public.is_staff() then raise exception 'Требуется вход сотрудника'; end if;
  IF nullif(trim(p_name),'') IS NULL THEN
    RAISE EXCEPTION 'Введите имя клиента';
  END IF;

  IF nullif(trim(p_phone),'') IS NULL THEN
    RAISE EXCEPTION 'Введите номер клиента';
  END IF;

  IF length(public.loyalty_phone_for_write(p_phone,false)) < 4 THEN
    RAISE EXCEPTION 'Номер клиента должен содержать минимум 4 цифры';
  END IF;

  INSERT INTO public.loyalty_customers(
    name,
    phone,
    comment,
    created_by_employee_id
  )
  VALUES(
    trim(p_name),
    public.loyalty_phone_for_write(p_phone,false),
    nullif(trim(coalesce(p_comment,'')),''),
    p_created_by_employee_id
  )
  on conflict(phone) do update set updated_at=public.loyalty_customers.updated_at
  RETURNING * INTO v_customer;

  RETURN QUERY
  SELECT
    v_customer.id,
    v_customer.name,
    v_customer.phone;
END;
$function$

;

do $$ begin if md5(rtrim(replace(pg_get_functiondef('public.loyalty_register_customer(text,text,text)'::regprocedure),chr(13),''),E'\n'))<>'3a792b658e00daeb1451162d84fd9236' then raise exception 'Function changed during review: public.loyalty_register_customer(text,text,text)';end if;end $$;

CREATE OR REPLACE FUNCTION public.loyalty_register_customer(p_name text, p_phone text, p_comment text DEFAULT NULL::text)
 RETURNS TABLE(customer_id uuid, customer_name text, customer_phone text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_customer public.loyalty_customers%rowtype;
begin
  if not public.is_staff() then raise exception 'Требуется вход сотрудника'; end if;
  if nullif(trim(p_name),'') is null then raise exception 'Введите имя клиента'; end if;
  if nullif(trim(p_phone),'') is null then raise exception 'Введите номер клиента'; end if;
  if length(public.loyalty_phone_for_write(p_phone,false)) < 4 then raise exception 'Номер клиента должен содержать минимум 4 цифры'; end if;
  insert into public.loyalty_customers(name,phone,comment)
  values(trim(p_name),public.loyalty_phone_for_write(p_phone,false),nullif(trim(coalesce(p_comment,'')),''))
  on conflict(phone) do update set updated_at=public.loyalty_customers.updated_at
  returning * into v_customer;
  return query select v_customer.id,v_customer.name,v_customer.phone;
end;
$function$

;

do $$ begin if md5(rtrim(replace(pg_get_functiondef('public.loyalty_add_purchase(text,text,numeric,text)'::regprocedure),chr(13),''),E'\n'))<>'855d7eb3378fc2534534bd804dd2de73' then raise exception 'Function changed during review: public.loyalty_add_purchase(text,text,numeric,text)';end if;end $$;

CREATE OR REPLACE FUNCTION public.loyalty_add_purchase(p_name text, p_phone text, p_amount numeric, p_comment text DEFAULT NULL::text)
 RETURNS TABLE(customer_id uuid, customer_name text, customer_phone text, points_added numeric, available_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_customer public.loyalty_customers%rowtype;
  v_points numeric(12,2);
  v_available timestamptz;
  v_order_count bigint;
  v_rule public.loyalty_gift_rules%rowtype;
begin
  if not public.is_staff() then raise exception 'Требуется вход сотрудника'; end if;
if nullif(trim(p_name),'') is null then
    raise exception 'Введите имя клиента';
  end if;

  if nullif(trim(p_phone),'') is null then
    raise exception 'Введите номер клиента';
  end if;

  if p_amount is null or p_amount <= 0 then
    raise exception 'Сумма покупки должна быть больше 0';
  end if;

  v_points := round(p_amount * 0.05, 2);
  v_available := now() + interval '24 hours';

  if length(public.loyalty_phone_for_write(p_phone,true)) < 4 then
    raise exception 'Номер клиента должен содержать минимум 4 цифры';
  end if;

  insert into public.loyalty_customers(name, phone, comment)
  values(
    trim(p_name),
    public.loyalty_phone_for_write(p_phone,true),
    nullif(trim(coalesce(p_comment,'')),'')
  )
  on conflict(phone) do update
    set name = public.loyalty_customers.name,
        comment = case
          when excluded.comment is not null
          then excluded.comment
          else public.loyalty_customers.comment
        end,
        updated_at = now()
  returning * into v_customer;

  -- Начисление 5%, доступно через 24 часа
  insert into public.loyalty_transactions(
    customer_id,
    transaction_type,
    order_amount,
    points,
    comment,
    available_at
  )
  values(
    v_customer.id,
    'purchase',
    p_amount,
    v_points,
    nullif(trim(coalesce(p_comment,'')),''),
    v_available
  );

  -- Считаем количество заказов клиента
  select count(*)
  into v_order_count
  from public.loyalty_transactions t
  where t.customer_id = v_customer.id
    and t.transaction_type = 'purchase';

  -- Проверяем подарок за это количество заказов
  for v_rule in
    select *
    from public.loyalty_gift_rules
    where order_count = v_order_count
  loop

    if not exists (
      select 1
      from public.loyalty_transactions t
      where t.customer_id = v_customer.id
        and t.transaction_type = 'gift'
        and t.gift_rule_id = v_rule.id
    ) then

      insert into public.loyalty_transactions(
        customer_id,
        transaction_type,
        order_amount,
        points,
        comment,
        available_at,
        gift_rule_id
      )
      values(
        v_customer.id,
        'gift',
        0,
        0,
        'Подарок за ' ||
        v_rule.order_count ||
        ' заказов: ' ||
        v_rule.gift_name,
        now(),
        v_rule.id
      );

    end if;
  end loop;

  return query
  select
    v_customer.id,
    v_customer.name,
    v_customer.phone,
    v_points,
    v_available;
end;
$function$

;

do $$ begin if md5(rtrim(replace(pg_get_functiondef('public.sales_create_sale(bigint,bigint,text,text,jsonb,uuid,numeric,text,text,text,bigint,numeric,jsonb)'::regprocedure),chr(13),''),E'\n'))<>'209b8ae9be8941c2f0afc61096b1ea41' then raise exception 'Function changed during review: public.sales_create_sale(bigint,bigint,text,text,jsonb,uuid,numeric,text,text,text,bigint,numeric,jsonb)';end if;end $$;

CREATE OR REPLACE FUNCTION public.sales_create_sale(p_shift_id bigint, p_employee_id bigint, p_payment_method text, p_comment text, p_items jsonb, p_loyalty_customer_id uuid DEFAULT NULL::uuid, p_loyalty_points numeric DEFAULT 0, p_loyalty_name text DEFAULT NULL::text, p_loyalty_phone text DEFAULT NULL::text, p_loyalty_comment text DEFAULT NULL::text, p_order_number bigint DEFAULT NULL::bigint, p_discount_percent numeric DEFAULT 0, p_payments jsonb DEFAULT '[]'::jsonb)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_shift public.sales_shifts%rowtype;
  v_sale_id bigint;
  v_order bigint;
  v_gross numeric(12,2):=0;
  v_discount numeric(12,2):=0;
  v_after_discount numeric(12,2):=0;
  v_total numeric(12,2):=0;
  v_points numeric(12,2):=round(coalesce(p_loyalty_points,0),2);
  v_item jsonb; v_pay jsonb; v_catalog public.sales_catalog%rowtype;
  v_qty numeric(12,3); v_price numeric(12,2); v_line numeric(12,2);
  v_pay_sum numeric(12,2):=0; v_customer_id uuid:=p_loyalty_customer_id;
  v_min bigint;
  v_forced bigint:=nullif(current_setting('polaroid.pickup_order',true),'')::bigint;
begin
  select * into v_shift from public.sales_shifts where id=p_shift_id and (status='open' or current_setting('polaroid.offline_sync',true)='1') for update;
  if not found then raise exception 'Смена не найдена или уже закрыта'; end if;
  if not exists(select 1 from public.sales_shift_employees where shift_id=p_shift_id and employee_id=p_employee_id) then raise exception 'Сотрудник не подключён к этой смене'; end if;
  if p_payment_method not in ('cash','card','qr','link','bank_account','transfer','split') then raise exception 'Выберите способ оплаты'; end if;
  if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then raise exception 'Добавьте хотя бы одну позицию'; end if;
  if coalesce(p_discount_percent,0)<0 or coalesce(p_discount_percent,0)>100 then raise exception 'Скидка должна быть от 0 до 100%%'; end if;

  for v_item in select * from jsonb_array_elements(p_items) loop
    select * into v_catalog from public.sales_catalog where id=(v_item->>'catalog_id')::bigint and is_active=true;
    if not found then raise exception 'Товар или услуга не найдены'; end if;
    v_qty:=coalesce((v_item->>'quantity')::numeric,0); v_price:=coalesce((v_item->>'unit_price')::numeric,v_catalog.price);
    if v_qty<=0 or v_price<0 then raise exception 'Некорректное количество или цена'; end if;
    v_line:=round(v_qty*v_price,2); v_gross:=v_gross+v_line;
  end loop;
  v_discount:=round(v_gross*coalesce(p_discount_percent,0)/100,2);
  v_after_discount:=round(v_gross-v_discount,2);
  if v_points<0 or v_points>round(v_after_discount*0.30,2) then raise exception 'Баллами можно оплатить не более 30%% после скидки'; end if;
  if v_points>0 then
    if v_customer_id is null then raise exception 'Выберите клиента клубной карты'; end if;
    perform public.loyalty_redeem(v_customer_id,v_after_discount,v_points,'Списание баллов при продаже');
  end if;
  v_total:=round(v_after_discount-v_points,2);

  if p_payment_method='split' then
    if jsonb_typeof(p_payments)<>'array' or jsonb_array_length(p_payments)<2 then raise exception 'Для раздельной оплаты добавьте минимум два способа оплаты'; end if;
    for v_pay in select * from jsonb_array_elements(p_payments) loop
      if (v_pay->>'method') not in ('cash','card','qr','link','bank_account','transfer') then raise exception 'Некорректный способ в раздельной оплате'; end if;
      if coalesce((v_pay->>'amount')::numeric,0)<=0 then raise exception 'Сумма каждого способа оплаты должна быть больше 0'; end if;
      v_pay_sum:=v_pay_sum+round((v_pay->>'amount')::numeric,2);
    end loop;
  else
    v_pay_sum:=v_total;
  end if;
  if round(v_pay_sum,2)<>round(v_total,2) then raise exception 'Сумма способов оплаты должна быть ровно %',v_total; end if;

  insert into public.sales_branch_order_counters(branch_id,next_number) values(v_shift.branch_id,1000) on conflict(branch_id) do nothing;
  select next_number into v_min from public.sales_branch_order_counters where branch_id=v_shift.branch_id for update;
  if v_forced is not null and v_forced=p_order_number
     and not exists(select 1 from public.sales s where s.branch_id=v_shift.branch_id and s.order_number=v_forced) then
    v_order:=v_forced;
  else
    select greatest(v_min, coalesce(max(s.order_number)+1,v_min)) into v_min
    from public.sales s where s.branch_id=v_shift.branch_id;
    v_order:=case when p_order_number is null or p_order_number<v_min then v_min else p_order_number end;
    while exists(select 1 from public.sales s where s.branch_id=v_shift.branch_id and s.order_number=v_order)
       or exists(select 1 from public.pickup_orders o where o.branch_id=v_shift.branch_id and o.order_number=v_order and o.status='pending') loop
      v_order:=v_order+1;
    end loop;
  end if;

  perform set_config('workflow.creator_person',coalesce((select person_id::text from public.sales_employees where id=p_employee_id),''),true);
  if v_customer_id is null and nullif(trim(coalesce(p_loyalty_phone,'')),'') is not null then
    select x.customer_id into v_customer_id from public.loyalty_add_purchase(trim(p_loyalty_name),trim(p_loyalty_phone),v_gross,nullif(trim(coalesce(p_loyalty_comment,'')),'')) x limit 1;
  elsif v_customer_id is not null then
    select x.customer_id into v_customer_id from public.loyalty_customers c cross join lateral public.loyalty_add_purchase(c.name,c.phone,v_gross,nullif(trim(coalesce(p_loyalty_comment,'')),'')) x where c.id=v_customer_id;
  end if;

  insert into public.sales(order_number,shift_id,branch_id,employee_id,payment_method,total,gross_total,discount_percent,discount_amount,loyalty_points_used,loyalty_customer_id,comment,receipt_issued,payment_status,paid_at)
  values(v_order,v_shift.id,v_shift.branch_id,p_employee_id,p_payment_method,v_total,v_gross,coalesce(p_discount_percent,0),v_discount,v_points,v_customer_id,nullif(trim(coalesce(p_comment,'')),''),case when p_payment_method='link' then null else true end,case when p_payment_method='link' then 'pending' else 'paid' end,case when p_payment_method='link' then null else now() end)
  returning id into v_sale_id;

  for v_item in select * from jsonb_array_elements(p_items) loop
    select * into v_catalog from public.sales_catalog where id=(v_item->>'catalog_id')::bigint;
    v_qty:=(v_item->>'quantity')::numeric; v_price:=(v_item->>'unit_price')::numeric; v_line:=round(v_qty*v_price,2);
    insert into public.sale_items(sale_id,catalog_id,item_type,item_name,quantity,unit_price,line_total,cost_price,cost_total,variant_material_id)
    values(v_sale_id,v_catalog.id,v_catalog.item_type,v_catalog.name,v_qty,v_price,v_line,v_catalog.cost_price,round(coalesce(v_catalog.cost_price,0)*v_qty,2),
      (select m.id from public.stock_materials m where m.id=nullif(v_item->>'variant_material_id','')::bigint and (m.variant_catalog_id=v_catalog.id or exists(select 1 from public.stock_norms n where n.material_id=m.parent_id and n.catalog_id=v_catalog.id and n.active))));
  end loop;
  if p_payment_method='split' then
    for v_pay in select * from jsonb_array_elements(p_payments) loop
      insert into public.sale_payments(sale_id,payment_method,amount) values(v_sale_id,(v_pay->>'method'),round((v_pay->>'amount')::numeric,2));
    end loop;
  else
    insert into public.sale_payments(sale_id,payment_method,amount) values(v_sale_id,p_payment_method,v_total);
  end if;
  update public.sales_branch_order_counters set next_number=greatest(next_number,v_order+1),updated_at=now() where branch_id=v_shift.branch_id;
  return v_order;
end; $function$

;

create table workflow_private.expense_config(singleton boolean primary key default true check(singleton),cutover timestamptz not null default now());
insert into workflow_private.expense_config(singleton) values(true);
create table workflow_private.expense_sync(branch_id bigint not null references public.sales_branches(id),day date not null,sheet_id bigint,row_no integer,tracked_since timestamptz not null,manual_amount numeric not null default 0,manual_comment text not null default '',receipt_total numeric not null default 0,receipt_comment text not null default '',last_total numeric,original_amount jsonb,original_comment jsonb,last_error text,updated_at timestamptz not null default now(),primary key(branch_id,day));
create table workflow_private.expense_audit(id uuid primary key default gen_random_uuid(),branch_id bigint not null,day date not null,choice text not null,before_total numeric,after_total numeric,by_user uuid,created_at timestamptz not null default now());
alter table workflow_private.expense_config enable row level security;
alter table workflow_private.expense_sync enable row level security;
alter table workflow_private.expense_audit enable row level security;
create policy deny_direct on workflow_private.expense_config for all to authenticated using(false) with check(false);
create policy deny_direct on workflow_private.expense_sync for all to authenticated using(false) with check(false);
create policy deny_direct on workflow_private.expense_audit for all to authenticated using(false) with check(false);
revoke all on all tables in schema workflow_private from public,anon,authenticated;
create index if not exists stock_receipt_finance_lookup on public.stock_moves(shift_id,branch_id,created_at) where kind='receipt';

create function workflow_private.comment_base(p_text text) returns text language sql immutable set search_path='' as $$
 select btrim(regexp_replace(coalesce(p_text,''),'(?s)\n?\[Приходы из склада\].*?\[/Приходы из склада\]','','g'));
$$;
create function workflow_private.receipt_rows(p_branch bigint,p_day date,p_since timestamptz default '-infinity') returns table(id bigint,amount numeric,name text,detail text,created_at timestamptz,person_name text,stock_branch text,qty numeric,shift_id bigint) language sql stable security definer set search_path='' as $$
 select m.id,m.price_total,mat.name,
 mat.name||' — '||case when m.price_total is null then 'сумма не указана' else m.price_total::text||' ₽' end||case when nullif(btrim(m.comment),'') is not null then ' ('||m.comment||')' else '' end,
 m.created_at,m.person_name,b.name,m.qty,m.shift_id
 from public.stock_moves m join public.stock_materials mat on mat.id=m.material_id join public.sales_branches b on b.id=m.branch_id left join public.sales_shifts sh on sh.id=m.shift_id
 where m.kind='receipt' and m.cancelled_at is null and coalesce(sh.branch_id,m.branch_id)=p_branch and coalesce((sh.started_at at time zone 'Europe/Moscow')::date,(m.created_at at time zone 'Europe/Moscow')::date)=p_day and m.created_at>=p_since order by m.created_at,m.id;
$$;
create function workflow_private.sync_expenses(p_branch bigint,p_day date) returns void language plpgsql security definer set search_path='' as $$
declare st workflow_private.expense_sync; d record; current_o jsonb;current_p jsonb;current_amount numeric:=0;cutover timestamptz; tracked timestamptz;total numeric;details text;before_guard text;
begin
 if exists(select 1 from public.sales_branches where id=p_branch and (is_test or is_workshop)) then return;end if;
 perform pg_advisory_xact_lock(hashtextextended('receipt-report:'||p_branch::text||':'||p_day::text,0));
 select * into st from workflow_private.expense_sync where branch_id=p_branch and day=p_day;
 if not found and not exists(select 1 from workflow_private.receipt_rows(p_branch,p_day)) then return;end if;
 begin select * into d from public.report_day_row(p_branch,p_day);
 exception when others then
  insert into workflow_private.expense_sync(branch_id,day,tracked_since,last_error) values(p_branch,p_day,now(),'В отчёте нет листа, месяца или строки на эту дату') on conflict(branch_id,day) do update set last_error=excluded.last_error,updated_at=now();return;
 end;
 select data->'rows'->d.row_no::text->'O',data->'rows'->d.row_no::text->'P' into current_o,current_p from public.report_sheets where id=d.sheet_id for update;
 select * into st from workflow_private.expense_sync where branch_id=p_branch and day=p_day for update;
 if current_o ? 'f' then
  insert into workflow_private.expense_sync(branch_id,day,tracked_since,last_error) values(p_branch,p_day,now(),'В расходах стоит формула: нужна сверка администратора') on conflict(branch_id,day) do update set last_error=excluded.last_error;return;
 end if;
 begin current_amount:=coalesce(nullif(replace(current_o->>'v',',','.'),''),'0')::numeric;
 exception when others then
  insert into workflow_private.expense_sync(branch_id,day,tracked_since,last_error) values(p_branch,p_day,now(),'В столбце расходов нечисловое значение: нужна сверка') on conflict(branch_id,day) do update set last_error=excluded.last_error;return;end;
 if st.branch_id is null or st.sheet_id is null then
  select c.cutover into cutover from workflow_private.expense_config c;
  tracked:=case when current_amount<>0 and exists(select 1 from workflow_private.receipt_rows(p_branch,p_day) r where r.created_at<cutover) then cutover else '-infinity'::timestamptz end;
  insert into workflow_private.expense_sync(branch_id,day,sheet_id,row_no,tracked_since,manual_amount,manual_comment,original_amount,original_comment)
  values(p_branch,p_day,d.sheet_id,d.row_no,tracked,current_amount,workflow_private.comment_base(current_p->>'v'),current_o,current_p)
  on conflict(branch_id,day) do update set sheet_id=excluded.sheet_id,row_no=excluded.row_no,tracked_since=excluded.tracked_since,manual_amount=excluded.manual_amount,manual_comment=excluded.manual_comment,original_amount=coalesce(workflow_private.expense_sync.original_amount,excluded.original_amount),original_comment=coalesce(workflow_private.expense_sync.original_comment,excluded.original_comment)
  returning * into st;
 end if;
 select coalesce(sum(r.amount),0),string_agg(r.detail,E'\n' order by r.created_at,r.id) into total,details from workflow_private.receipt_rows(p_branch,p_day,st.tracked_since) r;
 details:=case when details is null then '' else E'[Приходы из склада]\n'||details||E'\n[/Приходы из склада]' end;
 before_guard:=current_setting('workflow.expense_syncing',true);perform set_config('workflow.expense_syncing','1',true);
 perform public.report_put_row(d.sheet_id,d.row_no,jsonb_build_object('O',st.manual_amount+total,'P',concat_ws(E'\n',nullif(st.manual_comment,''),nullif(details,''))));
 perform public.report_recalc_total(d.sheet_id,d.m_to);
 perform set_config('workflow.expense_syncing',coalesce(before_guard,''),true);
 update workflow_private.expense_sync set receipt_total=total,receipt_comment=details,last_total=st.manual_amount+total,last_error=null,updated_at=now() where branch_id=p_branch and day=p_day;
end $$;
create function workflow_private.receipt_changed() returns trigger language plpgsql security definer set search_path='' as $$
declare branch bigint;day date;
begin
 if TG_OP<>'INSERT' and old.kind='receipt' then
  select coalesce(sh.branch_id,old.branch_id),coalesce((sh.started_at at time zone 'Europe/Moscow')::date,(old.created_at at time zone 'Europe/Moscow')::date) into branch,day from (select 1) x left join public.sales_shifts sh on sh.id=old.shift_id;
  perform workflow_private.sync_expenses(branch,day);
 end if;
 if TG_OP<>'DELETE' and new.kind='receipt' then
  select coalesce(sh.branch_id,new.branch_id),coalesce((sh.started_at at time zone 'Europe/Moscow')::date,(new.created_at at time zone 'Europe/Moscow')::date) into branch,day from (select 1) x left join public.sales_shifts sh on sh.id=new.shift_id;
  perform workflow_private.sync_expenses(branch,day);
 end if;
 return coalesce(new,old);
end $$;
revoke all on function workflow_private.receipt_changed() from public,anon,authenticated;
create trigger workflow_receipt_finance after insert or update or delete on public.stock_moves for each row execute function workflow_private.receipt_changed();

-- A manual expense is kept separately; changing the total never erases receipt amounts.
create function workflow_private.report_manual_changed() returns trigger language plpgsql security definer set search_path='' as $$
declare st workflow_private.expense_sync; old_o jsonb;new_o jsonb;new_p jsonb;manual numeric;comment text;
begin
 if current_setting('workflow.expense_syncing',true)='1' then return new;end if;
 for st in select * from workflow_private.expense_sync where sheet_id=new.id and last_error is null loop
  old_o:=old.data->'rows'->st.row_no::text->'O';new_o:=new.data->'rows'->st.row_no::text->'O';new_p:=new.data->'rows'->st.row_no::text->'P';
  if new_o is distinct from old_o then
   if new_o ? 'f' then raise exception 'Расходы из приходов учитываются автоматически. Введите итоговую сумму числом.';end if;
   begin manual:=coalesce(nullif(replace(new_o->>'v',',','.'),''),'0')::numeric-st.receipt_total;exception when others then raise exception 'Расходы должны быть числом';end;
   if manual<0 then raise exception 'Расходы не могут быть меньше суммы приходов (% ₽). Исправьте или отмените ошибочный приход.',st.receipt_total;end if;
   update workflow_private.expense_sync set manual_amount=manual,last_total=manual+receipt_total,updated_at=now() where branch_id=st.branch_id and day=st.day;
  end if;
  if new_p is distinct from old.data->'rows'->st.row_no::text->'P' then
   comment:=workflow_private.comment_base(new_p->>'v');
   update workflow_private.expense_sync set manual_comment=comment,updated_at=now() where branch_id=st.branch_id and day=st.day;
   new.data:=jsonb_set(new.data,array['rows',st.row_no::text,'P'],coalesce(new_p,'{}')||jsonb_build_object('v',concat_ws(E'\n',nullif(comment,''),nullif(st.receipt_comment,''))),true);
  end if;
 end loop;
 return new;
end $$;
revoke all on function workflow_private.report_manual_changed() from public,anon,authenticated;
create trigger workflow_report_expenses before update of data on public.report_sheets for each row execute function workflow_private.report_manual_changed();

create function workflow_private.expense_preview(p_branch bigint,p_day date) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare d record;cell jsonb;comment jsonb;amount numeric;st workflow_private.expense_sync;total numeric;missing bigint;items jsonb;available boolean:=true;
begin
 select coalesce(sum(r.amount),0),count(*) filter(where r.amount is null),coalesce(jsonb_agg(to_jsonb(r) order by r.created_at,r.id),'[]'::jsonb) into total,missing,items from workflow_private.receipt_rows(p_branch,p_day) r;
 begin
  select * into d from public.report_day_row(p_branch,p_day);
  select data->'rows'->d.row_no::text->'O',data->'rows'->d.row_no::text->'P' into cell,comment from public.report_sheets where id=d.sheet_id;
  amount:=coalesce(nullif(replace(cell->>'v',',','.'),''),'0')::numeric;
 exception when others then available:=false;amount:=null;
 end;
 select * into st from workflow_private.expense_sync where branch_id=p_branch and day=p_day;
 if exists(select 1 from public.sales_branches where id=p_branch and (is_workshop or is_test)) then available:=false;end if;
 return jsonb_build_object('branch_id',p_branch,'branch',(select name from public.sales_branches where id=p_branch),'day',p_day,'receipt_total',total,'missing_amount',missing,'items',items,'report_available',available,'report_total',amount,'report_comment',comment->>'v','synced_total',coalesce(st.receipt_total,0),'complete_sync',st.tracked_since='-infinity'::timestamptz and st.last_error is null,'error',st.last_error,'formula',cell ? 'f');
end $$;
create function workflow_private.expense_history(p_from date,p_to date) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb;
begin
 if auth.uid() is null or not public.is_admin() then raise sqlstate 'PT403' using message='Только администратор';end if;
 if p_to<p_from or p_to-p_from>730 then raise exception 'Выберите период до двух лет';end if;
 select coalesce(jsonb_agg(workflow_private.expense_preview(branch,receipt_day) order by receipt_day desc,branch),'[]'::jsonb) into result from(
 select distinct coalesce(sh.branch_id,m.branch_id) branch,coalesce((sh.started_at at time zone 'Europe/Moscow')::date,(m.created_at at time zone 'Europe/Moscow')::date) as receipt_day
 from public.stock_moves m left join public.sales_shifts sh on sh.id=m.shift_id where m.kind='receipt' and m.cancelled_at is null
 ) q where receipt_day between p_from and p_to;
 return result;
end $$;
create function public.workflow_expense_history(p_from date,p_to date) returns jsonb language sql security invoker set search_path='' as $$ select workflow_private.expense_history(p_from,p_to); $$;
create function workflow_private.reconcile_expenses(p_branch bigint,p_day date,p_choice text,p_expected_total numeric,p_expected_receipts numeric) returns jsonb language plpgsql security definer set search_path='' as $$
declare preview jsonb;d record;st workflow_private.expense_sync;base numeric;before_guard text;original_o jsonb;original_p jsonb;
begin
 if auth.uid() is null or not public.is_admin() then raise sqlstate 'PT403' using message='Только администратор';end if;
 if p_choice not in ('already_included','add_receipts') then raise exception 'Выберите способ сверки';end if;
 perform pg_advisory_xact_lock(hashtextextended('receipt-report:'||p_branch::text||':'||p_day::text,0));
 preview:=workflow_private.expense_preview(p_branch,p_day);
 if not (preview->>'report_available')::boolean then raise exception 'Для этой даты и филиала нет строки отчёта. Приходы сохранены в истории.';end if;
 select * into d from public.report_day_row(p_branch,p_day);
 perform 1 from public.report_sheets where id=d.sheet_id for update;
 preview:=workflow_private.expense_preview(p_branch,p_day);
 if (preview->>'report_total')::numeric is distinct from p_expected_total or (preview->>'receipt_total')::numeric is distinct from p_expected_receipts then raise exception 'Данные изменились. Обновите историю и проверьте суммы заново.';end if;
 select * into st from workflow_private.expense_sync where branch_id=p_branch and day=p_day for update;
 base:=case when p_choice='already_included' then p_expected_total-p_expected_receipts else p_expected_total-coalesce(st.receipt_total,0) end;
 if base<0 then raise exception 'Текущая сумма меньше суммы приходов. Они не могут уже полностью входить в неё.';end if;
 select data->'rows'->d.row_no::text->'O',data->'rows'->d.row_no::text->'P' into original_o,original_p from public.report_sheets where id=d.sheet_id;
 insert into workflow_private.expense_sync(branch_id,day,sheet_id,row_no,tracked_since,manual_amount,manual_comment,original_amount,original_comment)
 values(p_branch,p_day,d.sheet_id,d.row_no,'-infinity',base,workflow_private.comment_base(preview->>'report_comment'),original_o,original_p)
 on conflict(branch_id,day) do update set tracked_since='-infinity',manual_amount=excluded.manual_amount,manual_comment=excluded.manual_comment,sheet_id=excluded.sheet_id,row_no=excluded.row_no,last_error=null;
 -- Explicitly reviewed formulas may be replaced by their displayed numeric amount.
 before_guard:=current_setting('workflow.expense_syncing',true);perform set_config('workflow.expense_syncing','1',true);
 perform public.report_put_row(d.sheet_id,d.row_no,jsonb_build_object('O',p_expected_total));
 perform set_config('workflow.expense_syncing',coalesce(before_guard,''),true);
 perform workflow_private.sync_expenses(p_branch,p_day);
 insert into workflow_private.expense_audit(branch_id,day,choice,before_total,after_total,by_user) values(p_branch,p_day,p_choice,p_expected_total,base+p_expected_receipts,auth.uid());
 return workflow_private.expense_preview(p_branch,p_day);
end $$;
create function public.workflow_reconcile_expenses(p_branch bigint,p_day date,p_choice text,p_expected_total numeric,p_expected_receipts numeric) returns jsonb language sql security invoker set search_path='' as $$ select workflow_private.reconcile_expenses(p_branch,p_day,p_choice,p_expected_total,p_expected_receipts); $$;
create function workflow_private.shift_expense_status(p_shift_id bigint) returns jsonb language plpgsql security definer set search_path='' as $$
declare ctx record;
begin
 if auth.uid() is null or not public.is_staff() then raise sqlstate 'PT403' using message='Требуется вход';end if;
 if not public.is_admin() and not exists(select 1 from public.staff_accounts a join public.sales_employees e on e.person_id=a.person_id join public.sales_shift_employees se on se.employee_id=e.id where a.user_id=auth.uid() and a.active and se.shift_id=p_shift_id) then raise sqlstate 'PT403' using message='Смена другого сотрудника';end if;
 select * into ctx from public.report_shift_ctx(p_shift_id);
 perform workflow_private.sync_expenses(ctx.branch_id,ctx.day);
 return workflow_private.expense_preview(ctx.branch_id,ctx.day);
end $$;
create function public.workflow_shift_expenses(p_shift_id bigint) returns jsonb language sql security invoker set search_path='' as $$ select workflow_private.shift_expense_status(p_shift_id); $$;

revoke all on all functions in schema workflow_private from public,anon,authenticated;
grant execute on function workflow_private.creator(uuid),workflow_private.card_stats(date,date),workflow_private.expense_history(date,date),workflow_private.reconcile_expenses(bigint,date,text,numeric,numeric),workflow_private.shift_expense_status(bigint) to authenticated;
revoke all on function public.workflow_expense_history(date,date),public.workflow_reconcile_expenses(bigint,date,text,numeric,numeric),public.workflow_shift_expenses(bigint) from public,anon;
grant execute on function public.workflow_expense_history(date,date),public.workflow_reconcile_expenses(bigint,date,text,numeric,numeric),public.workflow_shift_expenses(bigint) to authenticated;
notify pgrst,'reload schema';

do $$ begin if md5(rtrim(replace(pg_get_functiondef('public.report_fill_shift(bigint,text)'::regprocedure),chr(13),''),E'\n'))<>'06497f44d560216e2b51053ecaa31c94' then raise exception 'Report function changed during review';end if;end $$;
CREATE OR REPLACE FUNCTION public.report_fill_shift(p_shift_id bigint, p_mode text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare c record; d record; v_shifts bigint[]; v_names text; v_vals jsonb; v_skip text[];
begin
  if p_mode not in ('auto','manual') then raise exception 'Неизвестный способ заполнения'; end if;
  select * into c from public.report_shift_ctx(p_shift_id);
  if public.is_test_branch(c.branch_id) then raise exception 'Тестовый филиал в общий отчет не попадает'; end if;
  select * into d from public.report_day_row(c.branch_id, c.day);
  insert into public.report_fills(shift_id,branch_id,day,mode,sheet_id,row_no)
    values (p_shift_id,c.branch_id,c.day,p_mode,d.sheet_id,d.row_no)
    on conflict (shift_id) do update set mode=excluded.mode, sheet_id=excluded.sheet_id, row_no=excluded.row_no, updated_at=now();
  if p_mode='auto' then
    select array_agg(id) into v_shifts from public.sales_shifts
     where branch_id=c.branch_id and (started_at at time zone 'Europe/Moscow')::date=c.day;
    select string_agg(nm,'/' order by first_at) into v_names from (
      select coalesce(nullif(btrim(p.name),''),e.name) nm, min(se.created_at) first_at
        from public.sales_shift_employees se join public.sales_employees e on e.id=se.employee_id
        left join public.sales_people p on p.id=e.person_id
       where se.shift_id=any(v_shifts) group by 1) x;
    with v as (select id,total from public.sales where shift_id=any(v_shifts) and status='completed' and payment_status<>'unpaid'),
         pay as (select p.payment_method m, sum(p.amount) a from public.sale_payments p join v on v.id=p.sale_id group by 1)
    select jsonb_build_object(
      'C', v_names,
      'D', (select coalesce(sum(total),0) from v),
      'G', coalesce((select a from pay where m='card'),0),
      'H', coalesce((select a from pay where m='qr'),0),
      'I', coalesce((select a from pay where m='link'),0),
      'J', coalesce((select a from pay where m='transfer'),0),
      'K', coalesce((select a from pay where m='bank_account'),0),
      'L', (select count(*) from v),
      'M', (select coalesce(sum(amount),0) from public.sales_returns where shift_id=any(v_shifts)),
      'Q', (select coalesce(sum(i.quantity),0) from public.sale_items i join v on v.id=i.sale_id
             where i.item_type='service' and i.item_name ilike '%ретуш%')) into v_vals;
    select coalesce(array_agg(distinct x),'{}') into v_skip from public.report_fills f, unnest(f.edited_cols) x
     where f.branch_id=c.branch_id and f.day=c.day;
    v_vals:=v_vals-v_skip;
    perform public.report_put_row(d.sheet_id, d.row_no, v_vals);
    perform public.report_recalc_total(d.sheet_id, d.m_to);
  end if;
  perform workflow_private.sync_expenses(c.branch_id,c.day);
  return public.report_staff_view(p_shift_id);
end $function$

;

do $$ begin if md5(rtrim(replace(pg_get_functiondef('public.report_staff_set(bigint,text,jsonb)'::regprocedure),chr(13),''),E'\n'))<>'b6f42b86a0402af8cc266eba2529cc04' then raise exception 'Report edit function changed during review';end if;end $$;
CREATE OR REPLACE FUNCTION public.report_staff_set(p_shift_id bigint, p_col text, p_value jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare c record; d record; v_mode text; v_data jsonb;
begin
  select * into c from public.report_shift_ctx(p_shift_id);
  select * into d from public.report_day_row(c.branch_id, c.day);
  select mode into v_mode from public.report_fills where shift_id=p_shift_id;
  if v_mode is null then
    select mode into v_mode from public.report_fills where branch_id=c.branch_id and day=c.day order by updated_at desc limit 1;
  end if;
  if v_mode is null then raise exception 'Сначала нажмите «Перенести в общий отчет»'; end if;
  if not (p_col = any(public.report_staff_cols(v_mode))) then raise exception 'Эту клетку заполняет касса'; end if;
  if p_value is not null and jsonb_typeof(p_value) not in ('number','string','null') then raise exception 'Неверное значение'; end if;
  if jsonb_typeof(p_value)='string' and length(p_value#>>'{}')>(case when p_col='P' then 12000 else 500 end) then raise exception 'Слишком длинный текст'; end if;
  perform public.report_mark_edit(d.sheet_id, d.row_no, c.branch_id, c.day, p_col, p_value);
  perform public.report_put_row(d.sheet_id, d.row_no, jsonb_build_object(p_col,p_value));
  perform public.report_recalc_total(d.sheet_id, d.m_to);
  update public.report_fills set updated_at=now() where shift_id=p_shift_id;
  select data into v_data from public.report_sheets where id=d.sheet_id;
  return jsonb_build_object(d.row_no::text, v_data->'rows'->(d.row_no::text), d.m_to::text, v_data->'rows'->(d.m_to::text));
end $function$

;

do $$ begin if md5(rtrim(replace(pg_get_functiondef('public.report_staff_set_past(bigint,integer,text,jsonb)'::regprocedure),chr(13),''),E'\n'))<>'07164e0edd3fe8eebb6bea6ded8b8277' then raise exception 'Report edit function changed during review';end if;end $$;
CREATE OR REPLACE FUNCTION public.report_staff_set_past(p_shift_id bigint, p_row integer, p_col text, p_value jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare c record; d record; v_data jsonb; v_day date; v_shift bigint;
begin
  select * into c from public.report_shift_ctx(p_shift_id);
  if public.is_test_branch(c.branch_id) then raise exception 'Тестовый филиал в общий отчет не попадает'; end if;
  select * into d from public.report_day_row(c.branch_id, c.day);
  if not (p_row = any(public.report_past_rows(d.sheet_id,d.m_from,d.row_no))) then raise exception 'Эту строку менять нельзя'; end if;
  if not (p_col = any(public.report_staff_cols('manual'))) then raise exception 'Эту клетку менять нельзя'; end if;
  if p_value is not null and jsonb_typeof(p_value) not in ('number','string','null') then raise exception 'Неверное значение'; end if;
  if jsonb_typeof(p_value)='string' and length(p_value#>>'{}')>(case when p_col='P' then 12000 else 500 end) then raise exception 'Слишком длинный текст'; end if;
  select data into v_data from public.report_sheets where id=d.sheet_id;
  v_day:=date '1899-12-30'+(v_data->'rows'->(p_row::text)->'A'->>'v')::numeric::int;
  perform public.report_mark_edit(d.sheet_id, p_row, c.branch_id, v_day, p_col, p_value);
  perform public.report_put_row(d.sheet_id, p_row, jsonb_build_object(p_col,p_value));
  perform public.report_recalc_total(d.sheet_id, d.m_to);
  select data into v_data from public.report_sheets where id=d.sheet_id;
  if not exists(select 1 from public.report_fills where branch_id=c.branch_id and day=v_day) then
    select id into v_shift from public.sales_shifts where branch_id=c.branch_id and (started_at at time zone 'Europe/Moscow')::date=v_day order by started_at limit 1;
    if v_shift is not null then
      insert into public.report_fills(shift_id,branch_id,day,mode,sheet_id,row_no) values (v_shift,c.branch_id,v_day,'manual',d.sheet_id,p_row) on conflict (shift_id) do nothing;
    end if;
  else
    update public.report_fills set updated_at=now() where branch_id=c.branch_id and day=v_day;
  end if;
  return jsonb_build_object(p_row::text, v_data->'rows'->(p_row::text), d.m_to::text, v_data->'rows'->(d.m_to::text));
end $function$

;

do $$ begin if md5(rtrim(replace(pg_get_functiondef('public.loyalty_redeem(uuid,numeric,numeric,text)'::regprocedure),chr(13),''),E'\n'))<>'365b00537baa0b6cd9b1b4142562b6a7' then raise exception 'Redemption function changed during review';end if;end $$;
CREATE OR REPLACE FUNCTION public.loyalty_redeem(p_customer_id uuid, p_order_amount numeric, p_points numeric, p_comment text DEFAULT NULL::text)
 RETURNS numeric
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_balance numeric;
  v_limit numeric;
begin
  if p_order_amount is null or p_order_amount <= 0 then raise exception 'Сумма заказа должна быть больше 0'; end if;
  if p_points is null or p_points <= 0 then raise exception 'Количество баллов должно быть больше 0'; end if;
  v_limit := round(p_order_amount * 0.30, 2);
  if p_points > v_limit then raise exception 'Можно списать не более % баллов', v_limit; end if;

  perform pg_advisory_xact_lock(hashtext('loyalty-phone:'||public.loyalty_normalize_phone(phone))) from public.loyalty_customers where id=p_customer_id;
  perform 1 from public.loyalty_customers where id=p_customer_id for update;
  if not found then raise exception 'Клиент не найден'; end if;

  select coalesce(sum(t.points),0) into v_balance
  from public.loyalty_transactions t
  where t.customer_id=p_customer_id and t.available_at <= now();

  if p_points > v_balance then raise exception 'Недостаточно доступных баллов. Доступно: %', v_balance; end if;

  insert into public.loyalty_transactions(customer_id, transaction_type, order_amount, points, comment, available_at)
  values(p_customer_id, 'redeem', p_order_amount, -p_points, nullif(trim(coalesce(p_comment,'')),''), now());

  return v_balance - p_points;
end;
$function$

;

-- Initialize only today's rows. A non-zero manual total is preserved; old receipts
-- are offered for explicit reconciliation rather than silently added twice.
do $$
declare r record;
begin
 for r in select distinct coalesce(sh.branch_id,m.branch_id) as branch_id,coalesce((sh.started_at at time zone 'Europe/Moscow')::date,(m.created_at at time zone 'Europe/Moscow')::date) as receipt_day
 from public.stock_moves m left join public.sales_shifts sh on sh.id=m.shift_id
 where m.kind='receipt' and m.cancelled_at is null and coalesce((sh.started_at at time zone 'Europe/Moscow')::date,(m.created_at at time zone 'Europe/Moscow')::date)=(now() at time zone 'Europe/Moscow')::date
 loop perform workflow_private.sync_expenses(r.branch_id,r.receipt_day);end loop;
end $$;
