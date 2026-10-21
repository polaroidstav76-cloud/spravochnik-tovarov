-- Ручное начисление/списание баллов клубной карты сотрудником (как в админке).
-- В комментарий операции дописывается, кто из сотрудников её сделал.
create or replace function public.loyalty_staff_adjust_points(p_customer_id uuid, p_points numeric, p_comment text default null)
returns numeric
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_balance numeric;
  v_new numeric;
  v_staff text;
  v_comment text;
begin
  select s.name into v_staff from public.staff_accounts s where s.user_id = auth.uid() and s.active;
  if not found then raise exception 'Требуется вход сотрудника'; end if;
  if p_points is null or p_points = 0 then raise exception 'Укажите количество баллов'; end if;

  perform 1 from public.loyalty_customers where id=p_customer_id for update;
  if not found then raise exception 'Клиент не найден'; end if;

  select coalesce(sum(t.points),0) into v_balance
  from public.loyalty_transactions t
  where t.customer_id=p_customer_id and t.available_at <= now();
  v_new := v_balance + p_points;
  if v_new < 0 then raise exception 'Баланс не может быть отрицательным. Доступно: %', v_balance; end if;

  v_comment := coalesce(nullif(trim(coalesce(p_comment,'')),''), case when p_points>0 then 'Ручное начисление' else 'Ручное списание' end)
    || ' · сотрудник: ' || coalesce(v_staff,'');
  insert into public.loyalty_transactions(customer_id, transaction_type, order_amount, points, comment, available_at)
  values(p_customer_id, 'adjustment', 0, p_points, v_comment, now());
  return v_new;
end;
$$;

revoke all on function public.loyalty_staff_adjust_points(uuid, numeric, text) from public, anon;
grant execute on function public.loyalty_staff_adjust_points(uuid, numeric, text) to authenticated;
