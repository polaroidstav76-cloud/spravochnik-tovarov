-- The original check required membership in a currently open shift even for the order's creator.
-- Keep ownership independent of shift status; other staff still need the target branch's open shift.
create or replace function public.sales_cancel_pickup(p_pickup_id bigint,p_reason text default null)
returns boolean language plpgsql security definer set search_path='' as $$
declare target public.pickup_orders; actor_person bigint;
begin
 if auth.uid() is null or not public.is_staff() then
  raise sqlstate 'PT403' using message='Требуется вход сотрудника';
 end if;
 select * into target from public.pickup_orders where id=p_pickup_id and status='pending' for update;
 if not found then raise exception 'Заказ не найден или уже закрыт';end if;
 select person_id into actor_person from public.staff_accounts where user_id=auth.uid() and active;
 if not public.is_admin()
    and not exists(select 1 from public.sales_employees e where e.id=target.employee_id and e.person_id=actor_person)
    and not exists(
     select 1 from public.sales_shifts s
     where s.status='open' and s.branch_id=target.branch_id
       and (
        exists(select 1 from public.sales_employees e where e.id=s.employee_id and e.person_id=actor_person)
        or exists(select 1 from public.sales_shift_employees se join public.sales_employees e on e.id=se.employee_id
                  where se.shift_id=s.id and e.person_id=actor_person)
       )
    ) then
  raise sqlstate 'PT403' using message='Удалить заказ может его создатель, сотрудник открытой смены этого филиала или администратор';
 end if;
 if nullif(btrim(p_reason),'') is null then raise exception 'Укажите причину удаления';end if;
 update public.pickup_orders set status='cancelled',cancelled_at=now(),cancel_reason=btrim(p_reason) where id=p_pickup_id;
 return true;
end $$;
revoke all on function public.sales_cancel_pickup(bigint,text) from public,anon;
grant execute on function public.sales_cancel_pickup(bigint,text) to authenticated;
