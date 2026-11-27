begin;
do $$declare proof uuid;worker uuid;admin uuid;pid bigint;eid bigint;bid bigint;sid bigint;saleid bigint;k int;today date:=(now() at time zone 'Europe/Moscow')::date;m jsonb;d jsonb;blocked boolean;begin
 select user_id into worker from staff_accounts where active and role='staff' and exists(select 1 from auth.sessions where user_id=staff_accounts.user_id) limit 1;select user_id into admin from staff_accounts where active and role='admin' limit 1;
 insert into sales_people(name,is_active) values('__deposit_fixture',true) returning id into pid;assert exists(select 1 from payroll_private.deposits where person_id=pid);
 select id into proof from auth.sessions where user_id=worker order by created_at desc limit 1;insert into payroll_private.unlocks values(worker,proof,now()+interval '15 minutes') on conflict(user_id,session_id) do update set expires_at=excluded.expires_at;
 update staff_accounts set person_id=pid where user_id=worker;
 select id into bid from sales_branches where is_active and not is_test and not is_workshop order by id limit 1;
 insert into sales_employees(branch_id,name,person_id) values(bid,'__deposit_fixture',pid) returning id into eid;
 insert into sales_pay_rates(employee_id,branch_id,shift_rate,retouch_rate) values(eid,bid,1000,100);
 for k in 1..7 loop
  insert into sales_shifts(branch_id,employee_id,started_at,ended_at,status,no_pay) values(bid,eid,((today-14+2*least(k,6))::timestamp at time zone 'Europe/Moscow')+interval '10 hours',((today-14+2*least(k,6))::timestamp at time zone 'Europe/Moscow')+interval '20 hours','closed',false) returning id into sid;
  insert into sales_shift_employees(shift_id,employee_id,is_lead) values(sid,eid,true);
  if k in(1,6) then
   insert into sales(shift_id,branch_id,employee_id,payment_method,total,status,payment_status) values(sid,bid,eid,'cash',100,'completed','paid') returning id into saleid;
   insert into sale_items(sale_id,item_type,item_name,quantity,unit_price,line_total) values(saleid,'service','Ретушь',case when k=1 then 2 else 1 end,100,case when k=1 then 200 else 100 end);
  end if;
 end loop;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',worker,'role','authenticated','session_id',proof)::text,true);execute 'set local role authenticated';
 m:=public.payroll_report(today-14,today);assert jsonb_array_length(m->'rows')=1;assert (m->'rows'->0->>'shifts')::int=1;assert (m->'rows'->0->>'deposit')::numeric=5200;assert (m->'rows'->0->>'total')::numeric=1100;
 assert jsonb_array_length(m->'deposits')=1;d:=m->'deposits'->0;assert (d->>'days')::int=5;assert (d->>'amount')::numeric=5200;
 m:=public.payroll_report(today-4,today);assert (m->'rows'->0->>'deposit')::numeric=1000;assert (m->'rows'->0->>'total')::numeric=1100;
 blocked:=false;begin perform public.payroll_deposit_set_paid(pid,true);exception when sqlstate 'PT403' then blocked:=true;end;assert blocked;
 execute 'reset role';perform set_config('request.jwt.claims',jsonb_build_object('sub',admin,'role','authenticated')::text,true);execute 'set local role authenticated';perform public.payroll_deposit_set_paid(pid,true);perform public.payroll_deposit_set_paid(pid,true);execute 'reset role';
 assert (select paid_amount from payroll_private.deposits where person_id=pid)=5200;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',worker,'role','authenticated','session_id',proof)::text,true);execute 'set local role authenticated';m:=public.payroll_report(today-14,today);assert (m->'deposits'->0->>'paid')::boolean;assert (m->'rows'->0->>'total')::numeric=1100;execute 'reset role';
 assert not has_table_privilege('authenticated','payroll_private.deposits','select');assert not has_function_privilege('authenticated','payroll_private.deposit_amount(bigint,date,date)','execute');
end $$;
rollback;
