create table payroll_private.deposits(
 person_id bigint primary key references public.sales_people(id),created_at timestamptz not null default now(),
 paid_at timestamptz,paid_by uuid,paid_amount numeric(12,2)
);
alter table payroll_private.deposits enable row level security;
revoke all on payroll_private.deposits from public,anon,authenticated;
-- Only these two existing employees are enrolled; all subsequently created people enroll automatically.
insert into payroll_private.deposits(person_id) select id from public.sales_people where is_active and name in('Лена','Сакинат');
create function payroll_private.enroll_new_person() returns trigger language plpgsql security definer set search_path='' as $$begin insert into payroll_private.deposits(person_id) values(new.id) on conflict do nothing;return new;end $$;
revoke all on function payroll_private.enroll_new_person() from public,anon,authenticated;
create trigger payroll_deposit_new_person after insert on public.sales_people for each row execute function payroll_private.enroll_new_person();
create function payroll_private.deposit_amount(p_person bigint,p_from date,p_to date) returns jsonb language sql stable security definer set search_path='' as $$
 with members as (
 select distinct on(s.id) s.id,s.started_at,(s.started_at at time zone 'Europe/Moscow')::date work_day,s.no_pay,coalesce(r.shift_rate,0) shift_rate,coalesce(r.retouch_rate,100) retouch_rate,
 (se.is_lead or (select count(*) from public.sales_shift_employees where shift_id=s.id)=1) retouch_lead
 from public.sales_shifts s join public.sales_branches b on b.id=s.branch_id join public.sales_shift_employees se on se.shift_id=s.id join public.sales_employees e on e.id=se.employee_id
 left join lateral(select pr.shift_rate,pr.retouch_rate from public.sales_pay_rates pr where pr.employee_id=e.id and pr.branch_id=s.branch_id and pr.is_active order by pr.id desc limit 1)r on true
 where e.person_id=p_person and not coalesce(b.is_test,false)
 order by s.id,coalesce(r.shift_rate,0) desc,se.is_lead desc
 ),days as (
 select work_day,max(shift_rate) amount from members where not coalesce(no_pay,false) group by work_day order by work_day limit 5
 ),retouch as (
 select m.work_day,sum(i.quantity*m.retouch_rate) amount from members m join days d using(work_day)
 join public.sales s on s.shift_id=m.id and s.status='completed' and s.payment_status<>'unpaid'
 join public.sale_items i on i.sale_id=s.id and i.item_type='service' and i.item_name ~* 'ретуш' where m.retouch_lead group by m.work_day
 ),daily as (select d.work_day,d.amount+coalesce(r.amount,0) amount from days d left join retouch r using(work_day))
 select jsonb_build_object('days',count(*),'amount',coalesce(sum(amount),0),'period_amount',coalesce(sum(amount) filter(where work_day between p_from and p_to),0),'dates',coalesce(jsonb_agg(jsonb_build_object('date',work_day,'amount',amount) order by work_day),'[]'::jsonb)) from daily
$$;
revoke all on function payroll_private.deposit_amount(bigint,date,date) from public,anon,authenticated;
-- Preserve salary privacy, fines and day-deduplication in the original report.
do $$begin execute replace(pg_get_functiondef('payroll_private.report(date,date)'::regprocedure),'FUNCTION payroll_private.report(','FUNCTION payroll_private.report_before_deposit(');end $$;
revoke all on function payroll_private.report_before_deposit(date,date) from public,anon,authenticated;
create or replace function payroll_private.report(p_from date,p_to date) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare m jsonb;x jsonb;result jsonb:='[]';details jsonb;info jsonb;dep payroll_private.deposits%rowtype;deposit_rows jsonb:='[]';me bigint;admin boolean;
begin
 m:=payroll_private.report_before_deposit(p_from,p_to);admin:=(m->>'admin')::boolean;
 select person_id into me from public.staff_accounts where user_id=auth.uid() and active;
 for x in select value from jsonb_array_elements(m->'rows') loop
  select * into dep from payroll_private.deposits where person_id=(x->>'person_id')::bigint;
  if found then details:=payroll_private.deposit_amount(dep.person_id,p_from,p_to);x:=x||jsonb_build_object('deposit',details->'period_amount','total',(x->>'total')::numeric-(details->>'period_amount')::numeric);else x:=x||jsonb_build_object('deposit',0);end if;
  result:=result||jsonb_build_array(x);
 end loop;
 for dep in select * from payroll_private.deposits where admin or person_id=me loop
  details:=payroll_private.deposit_amount(dep.person_id,p_from,p_to);
  info:=jsonb_build_object('person_id',dep.person_id,'name',(select name from public.sales_people where id=dep.person_id),'paid',dep.paid_at is not null,'paid_at',dep.paid_at,'paid_amount',dep.paid_amount)||details;
  deposit_rows:=deposit_rows||jsonb_build_array(info);
 end loop;
 return m||jsonb_build_object('rows',result,'deposits',deposit_rows);
end $$;
revoke all on function payroll_private.report(date,date) from public,anon;
grant execute on function payroll_private.report(date,date) to authenticated;
create function payroll_private.deposit_set_paid(p_person_id bigint,p_paid boolean) returns boolean language plpgsql security definer set search_path='' as $$
declare d payroll_private.deposits%rowtype;details jsonb;
begin
 if not public.is_admin() then raise sqlstate 'PT403' using message='Выплату депозита отмечает только администратор';end if;
 if p_paid is null then raise exception 'Укажите статус выплаты';end if;
 select * into d from payroll_private.deposits where person_id=p_person_id for update;
 if not found then raise exception 'У сотрудника нет депозита';end if;
 if p_paid and d.paid_at is not null then return true;end if;
 details:=payroll_private.deposit_amount(p_person_id,null,null);
 update payroll_private.deposits set paid_at=case when p_paid then now() end,paid_by=case when p_paid then auth.uid() end,paid_amount=case when p_paid then (details->>'amount')::numeric end where person_id=p_person_id;
 return true;
end $$;
create function public.payroll_deposit_set_paid(p_person_id bigint,p_paid boolean) returns boolean language sql security invoker set search_path='' as $$select payroll_private.deposit_set_paid(p_person_id,p_paid)$$;
revoke all on function payroll_private.deposit_set_paid(bigint,boolean),public.payroll_deposit_set_paid(bigint,boolean) from public,anon;
grant execute on function payroll_private.deposit_set_paid(bigint,boolean),public.payroll_deposit_set_paid(bigint,boolean) to authenticated;
notify pgrst,'reload schema';
