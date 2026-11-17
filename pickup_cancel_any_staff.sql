-- Supersedes pickup_cancel_access_fix.sql: owner and branch restrictions removed at owner's request.
create or replace function public.sales_cancel_pickup(p_pickup_id bigint,p_reason text default null)
returns boolean language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null or not public.is_staff() then
  raise sqlstate 'PT403' using message='Требуется вход сотрудника';
 end if;
 perform 1 from public.pickup_orders where id=p_pickup_id and status='pending' for update;
 if not found then raise exception 'Заказ не найден или уже закрыт';end if;
 if nullif(btrim(p_reason),'') is null then raise exception 'Укажите причину удаления';end if;
 update public.pickup_orders set status='cancelled',cancelled_at=now(),cancel_reason=btrim(p_reason) where id=p_pickup_id;
 return true;
end $$;
revoke all on function public.sales_cancel_pickup(bigint,text) from public,anon;
grant execute on function public.sales_cancel_pickup(bigint,text) to authenticated;
