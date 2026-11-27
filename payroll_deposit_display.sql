-- First five paid working dates contribute only to the deposit.
-- Preserve the existing password gate, fines and outer training wrapper.
create or replace function payroll_private.deposit_amount(p_person bigint,p_from date,p_to date) returns jsonb language sql stable security definer set search_path='' as $$
 with members as (
 select distinct on(s.id) s.id,s.started_at,(s.started_at at time zone 'Europe/Moscow')::date work_day,s.no_pay,coalesce(r.shift_rate,0) shift_rate,coalesce(r.retouch_rate,100) retouch_rate,
 (se.is_lead or (select count(*) from public.sales_shift_employees where shift_id=s.id)=1) retouch_lead
 from public.sales_shifts s join public.sales_branches b on b.id=s.branch_id join public.sales_shift_employees se on se.shift_id=s.id join public.sales_employees e on e.id=se.employee_id
 left join lateral(select pr.shift_rate,pr.retouch_rate from public.sales_pay_rates pr where pr.employee_id=e.id and pr.branch_id=s.branch_id and pr.is_active order by pr.id desc limit 1)r on true
 where e.person_id=p_person and not coalesce(b.is_test,false)
 order by s.id,coalesce(r.shift_rate,0) desc,se.is_lead desc
 ),days as (
 select work_day,max(shift_rate) shift_pay from members where not coalesce(no_pay,false) group by work_day order by work_day limit 5
 ),retouch as (
 select m.work_day,sum(i.quantity*m.retouch_rate) retouch_pay,sum(i.quantity) retouches from members m join days d using(work_day)
 join public.sales s on s.shift_id=m.id and s.status='completed' and s.payment_status<>'unpaid'
 join public.sale_items i on i.sale_id=s.id and i.item_type='service' and i.item_name ~* 'ретуш' where m.retouch_lead group by m.work_day
 ),daily as (select d.work_day,d.shift_pay,coalesce(r.retouch_pay,0) retouch_pay,coalesce(r.retouches,0) retouches,d.shift_pay+coalesce(r.retouch_pay,0) amount from days d left join retouch r using(work_day))
 select jsonb_build_object('days',count(*),'amount',coalesce(sum(amount),0),'period_amount',coalesce(sum(amount) filter(where work_day between p_from and p_to),0),'period_days',count(*) filter(where work_day between p_from and p_to),'period_shift_pay',coalesce(sum(shift_pay) filter(where work_day between p_from and p_to),0),'period_retouch_pay',coalesce(sum(retouch_pay) filter(where work_day between p_from and p_to),0),'period_retouches',coalesce(sum(retouches) filter(where work_day between p_from and p_to),0),'dates',coalesce(jsonb_agg(jsonb_build_object('date',work_day,'amount',amount) order by work_day),'[]'::jsonb)) from daily
$$;

create or replace function payroll_private.report_before_training(p_from date,p_to date) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare m jsonb;x jsonb;result jsonb:='[]';details jsonb;info jsonb;dep payroll_private.deposits%rowtype;deposit_rows jsonb:='[]';me bigint;admin boolean;
begin
 if not public.is_admin() and not exists(select 1 from payroll_private.unlocks u join auth.sessions s on s.id=u.session_id and s.user_id=u.user_id where u.user_id=auth.uid() and u.session_id=(auth.jwt()->>'session_id')::uuid and u.expires_at>now()) then raise sqlstate 'PT401' using message='Введите пароль своего аккаунта, чтобы посмотреть зарплату';end if;
 m:=payroll_private.report_before_deposit(p_from,p_to);admin:=(m->>'admin')::boolean;
 select person_id into me from public.staff_accounts where user_id=auth.uid() and active;
 for x in select value from jsonb_array_elements(m->'rows') loop
  select * into dep from payroll_private.deposits where person_id=(x->>'person_id')::bigint;
  if found then details:=payroll_private.deposit_amount(dep.person_id,p_from,p_to);x:=x||jsonb_build_object('deposit',details->'period_amount','deposit_days',details->'period_days','shifts',greatest(0,(x->>'shifts')::numeric-(details->>'period_days')::numeric),'shift_pay',(x->>'shift_pay')::numeric-(details->>'period_shift_pay')::numeric,'retouches',(x->>'retouches')::numeric-(details->>'period_retouches')::numeric,'retouch_pay',(x->>'retouch_pay')::numeric-(details->>'period_retouch_pay')::numeric,'total',(x->>'total')::numeric-(details->>'period_amount')::numeric);else x:=x||jsonb_build_object('deposit',0);end if;
  result:=result||jsonb_build_array(x);
 end loop;
 for dep in select * from payroll_private.deposits where admin or person_id=me loop
  details:=payroll_private.deposit_amount(dep.person_id,p_from,p_to);
  info:=jsonb_build_object('person_id',dep.person_id,'name',(select name from public.sales_people where id=dep.person_id),'paid',dep.paid_at is not null,'paid_at',dep.paid_at,'paid_amount',dep.paid_amount)||details;
  deposit_rows:=deposit_rows||jsonb_build_array(info);
 end loop;
 return m||jsonb_build_object('rows',result,'deposits',deposit_rows);
end $$;
