-- Запасной режим кассы: продажа, сохранённая в браузере без связи, отправляется позже ровно один раз.
-- Применено в Supabase 2026-10-11.

alter table public.sales add column if not exists client_uid uuid;
alter table public.sales add column if not exists offline_at timestamptz;
create unique index if not exists sales_client_uid_key on public.sales(client_uid) where client_uid is not null;

-- sales_create_sale принимает закрытую смену только при отправке офлайн-продажи (флаг polaroid.offline_sync).
-- Строка проверки смены заменена на месте, остальная функция не менялась:
--   where id=p_shift_id and (status='open' or current_setting('polaroid.offline_sync',true)='1') for update;
do $do$ declare d text; begin
  d:=pg_get_functiondef('public.sales_create_sale(bigint,bigint,text,text,jsonb,uuid,numeric,text,text,text,bigint,numeric,jsonb)'::regprocedure);
  d:=replace(d, $x$where id=p_shift_id and status='open' for update;$x$, $x$where id=p_shift_id and (status='open' or current_setting('polaroid.offline_sync',true)='1') for update;$x$);
  if position('polaroid.offline_sync' in d)=0 and position('status=''open'' for update' in d)>0 then raise exception 'shift check not found'; end if;
  execute d;
end $do$;

-- Обёртка над sales_create_sale. p_client_uid генерирует браузер для каждой продажи:
-- повторная отправка той же продажи возвращает уже выданный номер, а не создаёт дубль.
-- p_offline_at задан только для продаж, сохранённых без связи: им ставится время фактической продажи,
-- и они принимаются даже если смену уже закрыли.
create or replace function public.sales_create_sale_v6(
  p_client_uid uuid, p_offline_at timestamptz,
  p_shift_id bigint, p_employee_id bigint, p_payment_method text, p_comment text, p_items jsonb,
  p_loyalty_customer_id uuid default null, p_loyalty_points numeric default 0,
  p_loyalty_name text default null, p_loyalty_phone text default null, p_loyalty_comment text default null,
  p_order_number bigint default null, p_discount_percent numeric default 0, p_payments jsonb default '[]'::jsonb)
returns bigint language plpgsql security definer set search_path to 'public' as $$
declare
  v_existing bigint; v_order bigint;
  v_at timestamptz:=case when p_offline_at is null then null else least(greatest(p_offline_at,now()-interval '14 days'),now()) end;
begin
  if p_client_uid is null then raise exception 'Нет идентификатора продажи'; end if;
  perform pg_advisory_xact_lock(hashtext('sale:'||p_client_uid::text));
  select order_number into v_existing from public.sales where client_uid=p_client_uid;
  if found then return v_existing; end if;

  if v_at is not null then perform set_config('polaroid.offline_sync','1',true); end if;
  v_order:=public.sales_create_sale(p_shift_id,p_employee_id,p_payment_method,p_comment,p_items,p_loyalty_customer_id,p_loyalty_points,
    p_loyalty_name,p_loyalty_phone,p_loyalty_comment,p_order_number,p_discount_percent,p_payments);
  perform set_config('polaroid.offline_sync','',true);

  update public.sales s set client_uid=p_client_uid,
    offline_at=v_at,
    created_at=coalesce(v_at,s.created_at),
    paid_at=case when s.paid_at is not null and v_at is not null then v_at else s.paid_at end
  where s.id=(select x.id from public.sales x join public.sales_shifts sh on sh.branch_id=x.branch_id
              where sh.id=p_shift_id and x.order_number=v_order order by x.id desc limit 1);
  return v_order;
end; $$;

grant execute on function public.sales_create_sale_v6(uuid,timestamptz,bigint,bigint,text,text,jsonb,uuid,numeric,text,text,text,bigint,numeric,jsonb) to anon, authenticated;
