-- Напоминания о неоплаченных заказах «при получении» (миграция pickup_reminders, 2026-10-27).
-- 1) Через 7 дней после оформления филиал видит плашку с первым текстом для клиента; сотрудник копирует текст и жмёт «Отправил».
-- 2) Через 2 дня после первого сообщения, если заказ не оплачен, — второй текст.
-- 3) Через 2 дня после второго сообщения: есть клубная карта → карта «Только предоплата» (сайт не даёт «При получении»),
--    нет карты → заказ помечается «Не заберут». Оба признака считаются на лету и пропадают, когда заказ оплачен или отменён.
alter table public.pickup_orders add column if not exists remind1_at timestamptz;
alter table public.pickup_orders add column if not exists remind1_employee_id bigint;
alter table public.pickup_orders add column if not exists remind2_at timestamptz;
alter table public.pickup_orders add column if not exists remind2_employee_id bigint;

-- pickup_list_v3 = pickup_list_v2 + когда и кто отправил напоминания.
create or replace function public.pickup_list_v3(p_branch_id bigint default null, p_include_closed boolean default false)
returns table(id bigint, branch_id bigint, branch_name text, order_number bigint, items jsonb, gross_total numeric, discount_percent numeric,
  total numeric, customer_id uuid, customer_name text, customer_phone text, client_name text, client_phone text, comment text,
  employee_name text, status text, created_at timestamptz, paid_at timestamptz, cancelled_at timestamptz, cancel_reason text,
  client_order_ref text, remind1_at timestamptz, remind1_by text, remind2_at timestamptz, remind2_by text)
language sql stable security definer set search_path to 'public' as $fn$
  select l.*, o.remind1_at, coalesce(p1.name,e1.name), o.remind2_at, coalesce(p2.name,e2.name)
  from public.pickup_list_v2(p_branch_id,p_include_closed) l
  join public.pickup_orders o on o.id=l.id
  left join public.sales_employees e1 on e1.id=o.remind1_employee_id left join public.sales_people p1 on p1.id=e1.person_id
  left join public.sales_employees e2 on e2.id=o.remind2_employee_id left join public.sales_people p2 on p2.id=e2.person_id
  order by l.created_at;
$fn$;

-- Сотрудник отправил клиенту напоминание (p_step = 1 или 2).
create or replace function public.pickup_mark_reminded(p_pickup_id bigint, p_step int, p_employee_id bigint default null) returns timestamptz
language plpgsql security definer set search_path to 'public' as $fn$
declare v timestamptz;
begin
  if p_step=1 then
    update public.pickup_orders set remind1_at=now(),remind1_employee_id=p_employee_id
    where id=p_pickup_id and status='pending' and remind1_at is null returning remind1_at into v;
  elsif p_step=2 then
    update public.pickup_orders set remind2_at=now(),remind2_employee_id=p_employee_id
    where id=p_pickup_id and status='pending' and remind1_at is not null and remind2_at is null returning remind2_at into v;
  else raise exception 'Неизвестный шаг напоминания'; end if;
  if v is null then raise exception 'Заказ уже оплачен, отменён или напоминание уже отмечено'; end if;
  return v;
end $fn$;

grant execute on function public.pickup_list_v3(bigint,boolean), public.pickup_mark_reminded(bigint,int,bigint) to anon, authenticated;
