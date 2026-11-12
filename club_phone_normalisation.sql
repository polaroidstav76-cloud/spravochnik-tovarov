create or replace function public.loyalty_normalize_phone(p_phone text)
returns text language sql immutable strict set search_path='' as $$
 select case when d ~ '^[78]9[0-9]{9}$' then '7'||right(d,10) when d ~ '^9[0-9]{9}$' then '7'||d else d end
 from (select regexp_replace(p_phone,'[^0-9]','','g') d) x;
$$;
create or replace function public.loyalty_phone_for_write(p_phone text,p_allow_exact boolean default false)
returns text language plpgsql set search_path='' as $$
declare d text:=regexp_replace(coalesce(p_phone,''),'[^0-9]','','g'); n text:=public.loyalty_normalize_phone(p_phone); cnt integer; existing text;
begin
 if n ~ '^79[0-9]{9}$' then
   perform pg_advisory_xact_lock(hashtext('loyalty-phone:'||n));
   select count(*),min(phone) into cnt,existing from public.loyalty_customers where public.loyalty_normalize_phone(phone)=n;
   if cnt>1 then
     if p_allow_exact and exists(select 1 from public.loyalty_customers where phone=d) then return d; end if;
     raise exception 'На этот номер уже есть несколько карт. Найдите клиента по полному номеру и выберите нужную карту по имени.';
   end if;
   return case when cnt=1 then existing else n end;
 end if;
 if p_allow_exact and exists(select 1 from public.loyalty_customers where phone=d) then return d; end if;
 raise exception 'Введите полный мобильный номер: +7 и 10 цифр, начиная с 9';
end $$;
revoke all on function public.loyalty_phone_for_write(text,boolean) from public,anon,authenticated;
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
  on conflict(phone) do update set name=excluded.name, comment=coalesce(excluded.comment,public.loyalty_customers.comment), updated_at=now()
  returning * into v_customer;
  return query select v_customer.id,v_customer.name,v_customer.phone;
end;
$function$
;
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
  ON CONFLICT(phone) DO UPDATE
  SET
    name = excluded.name,
    comment = coalesce(
      excluded.comment,
      public.loyalty_customers.comment
    ),
    created_by_employee_id = coalesce(
      excluded.created_by_employee_id,
      public.loyalty_customers.created_by_employee_id
    )
  RETURNING * INTO v_customer;

  RETURN QUERY
  SELECT
    v_customer.id,
    v_customer.name,
    v_customer.phone;
END;
$function$
;
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
    set name = excluded.name,
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
CREATE OR REPLACE FUNCTION public.loyalty_find_customers(p_query text)
 RETURNS TABLE(customer_id uuid, customer_name text, customer_phone text, balance numeric, order_count bigint, customer_comment text, pending_points numeric)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select c.id, c.name, case when public.loyalty_normalize_phone(c.phone) ~ '^79[0-9]{9}$' then '+'||public.loyalty_normalize_phone(c.phone) else c.phone end,
    coalesce(sum(case when t.available_at <= now() then t.points else 0 end),0)::numeric as balance,
    count(t.id) filter (where t.transaction_type='purchase')::bigint as order_count,
    c.comment,
    coalesce(sum(case when t.available_at > now() then t.points else 0 end),0)::numeric as pending_points
  from public.loyalty_customers c
  left join public.loyalty_transactions t on t.customer_id=c.id
  where public.is_staff() and (
    (length(regexp_replace(coalesce(p_query,''),'[^0-9]','','g'))=4 and right(regexp_replace(c.phone,'[^0-9]','','g'),4)=regexp_replace(p_query,'[^0-9]','','g'))
    or (length(regexp_replace(coalesce(p_query,''),'[^0-9]','','g'))>4 and public.loyalty_normalize_phone(c.phone)=public.loyalty_normalize_phone(p_query))
  )
  group by c.id
  order by c.name;
$function$
;
create or replace function public.loyalty_admin_update_customer(p_customer_id uuid,p_name text,p_phone text,p_comment text)
returns void language plpgsql security definer set search_path='' as $admin$
declare v_old text; v_new text:=public.loyalty_normalize_phone(p_phone);
begin
 if not public.is_admin() then raise exception 'Требуется вход администратора'; end if;
 if nullif(trim(p_name),'') is null then raise exception 'Имя клиента не может быть пустым'; end if;
 if nullif(trim(p_phone),'') is null then raise exception 'Номер клиента не может быть пустым'; end if;
 select phone into v_old from public.loyalty_customers where id=p_customer_id for update;
 if not found then raise exception 'Клиент не найден'; end if;
 if public.loyalty_normalize_phone(v_old)=v_new then v_new:=v_old;
 else
   if v_new !~ '^79[0-9]{9}$' then raise exception 'Введите полный мобильный номер: +7 и 10 цифр, начиная с 9'; end if;
   perform pg_advisory_xact_lock(hashtext('loyalty-phone:'||v_new));
   if exists(select 1 from public.loyalty_customers where public.loyalty_normalize_phone(phone)=v_new and id<>p_customer_id) then raise exception 'Карта с таким номером уже существует'; end if;
 end if;
 update public.loyalty_customers set name=trim(p_name),phone=v_new,comment=nullif(trim(coalesce(p_comment,'')),''),updated_at=now() where id=p_customer_id;
end $admin$;
notify pgrst, 'reload schema';

