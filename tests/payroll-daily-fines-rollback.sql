begin;
do $$declare proof uuid;worker uuid;admin uuid;pid bigint;otherpid bigint;eid bigint;eid2 bigint;bid bigint;bid2 bigint;sid bigint;mid bigint;row jsonb;m jsonb;flow jsonb;chat bigint;today date:=(now() at time zone 'Europe/Moscow')::date;fid uuid;blocked boolean;begin
 select user_id into worker from public.staff_accounts where active and role='staff' and exists(select 1 from auth.sessions where user_id=staff_accounts.user_id) limit 1;
 select user_id into admin from public.staff_accounts where active and role='admin' limit 1;
 select chat_id into chat from public.report_recipients where active limit 1;
 insert into public.sales_people(name,is_active) values('__Payroll isolated test',true) returning id into pid;
 insert into public.sales_people(name,is_active) values('__Payroll OTHER secret',true) returning id into otherpid;
 delete from payroll_private.deposits where person_id in(pid,otherpid);
 select id into proof from auth.sessions where user_id=worker order by created_at desc limit 1;insert into payroll_private.unlocks values(worker,proof,now()+interval '15 minutes') on conflict(user_id,session_id) do update set expires_at=excluded.expires_at;
 update public.staff_accounts set person_id=pid where user_id=worker;
 select id into bid from public.sales_branches where is_active and not is_test and not is_workshop order by id limit 1;
 select id into bid2 from public.sales_branches where is_active and not is_test and not is_workshop and id<>bid order by id limit 1;
 insert into public.sales_employees(branch_id,name,person_id) values(bid,'__Payroll isolated test',pid) returning id into eid;
 insert into public.sales_employees(branch_id,name,person_id) values(bid2,'__Payroll isolated test',pid) returning id into eid2;
 insert into public.sales_pay_rates(employee_id,branch_id,shift_rate,retouch_rate) values(eid,bid,1000,100),(eid2,bid2,1500,100);
 for mid in 1..6 loop
  insert into public.sales_shifts(branch_id,employee_id,started_at,ended_at,status,no_pay)
  values(case when mid=6 then bid2 else bid end,case when mid=6 then eid2 else eid end,
   ((today-case when mid=6 then 0 else 5-mid end)::timestamp at time zone 'Europe/Moscow')+interval '10 hours',
   ((today-case when mid=6 then 0 else 5-mid end)::timestamp at time zone 'Europe/Moscow')+interval '20 hours','closed',false) returning id into sid;
  insert into public.sales_shift_employees(shift_id,employee_id,is_lead) values(sid,case when mid=6 then eid2 else eid end,true);
 end loop;
 insert into payroll_private.fines(person_id,amount) values(otherpid,999);
 perform set_config('request.jwt.claims',jsonb_build_object('sub',worker,'role','authenticated','session_id',proof)::text,true);
 execute 'set local role authenticated';
 m:=public.payroll_report(today-4,today);assert jsonb_array_length(m->'rows')=1;row:=m->'rows'->0;assert (row->>'shifts')::int=5;assert (row->>'duplicates')::int=1;assert (row->>'shift_pay')::numeric=5500;assert not(m::text like '%OTHER secret%');assert jsonb_array_length(m->'fines')=0;
 blocked:=false;begin perform public.payroll_fine_revoke(gen_random_uuid());exception when sqlstate 'PT403' then blocked:=true;end;assert blocked;
 assert not exists(select 1 from public.sales_pay_rates r join public.sales_employees e on e.id=r.employee_id where e.person_id<>pid);
 execute 'reset role';
 perform set_config('request.jwt.claims','{"role":"service_role"}',true);
 assert public.telegram_payroll_fine(-987654321,900000000,'start')->>'status'='inactive';
 perform public.telegram_payroll_fine(chat,899999995,'start');assert public.telegram_payroll_fine(chat,899999996,'input','__unknown_name__ 100')->>'status'='choose';
 assert public.telegram_payroll_fine(chat,900000000,'start')->>'status'='name';
 assert public.telegram_payroll_fine(chat,900000001,'input','#'||pid)->>'status'='amount';
 assert public.telegram_payroll_fine(chat,900000002,'input','-500')->>'status'='bad_amount';
 assert public.telegram_payroll_fine(chat,900000003,'input','500,50')->>'status'='reason';
 assert public.telegram_payroll_fine(chat,900000004,'input','Опоздание')->>'status'='confirm';
 flow:=public.telegram_payroll_fine(chat,900000005,'confirm');assert flow->>'status'='saved';fid:=(flow->>'id')::uuid;
 assert public.telegram_payroll_fine(chat,900000005,'confirm')->>'status'='saved';assert (select count(*) from payroll_private.fines where person_id=pid)=1;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',worker,'role','authenticated','session_id',proof)::text,true);
 execute 'set local role authenticated';m:=public.payroll_report(today-4,today);assert (m->'rows'->0->>'total')::numeric=4999.50;assert jsonb_array_length(m->'fines')=1;assert m->'fines'->0->>'reason'='Опоздание';execute 'reset role';
 perform set_config('request.jwt.claims',jsonb_build_object('sub',admin,'role','authenticated')::text,true);
 execute 'set local role authenticated';perform public.payroll_fine_revoke(fid);execute 'reset role';
 perform set_config('request.jwt.claims',jsonb_build_object('sub',worker,'role','authenticated','session_id',proof)::text,true);
 execute 'set local role authenticated';m:=public.payroll_report(today-4,today);assert (m->'rows'->0->>'total')::numeric=5500;assert (m->'fines'->0->>'revoked')::boolean;execute 'reset role';
 perform set_config('request.jwt.claims','{"role":"service_role"}',true);perform public.telegram_payroll_fine(chat,900000010,'start');flow:=public.telegram_payroll_fine(chat,900000011,'input','#'||pid||' 100');assert flow->>'status'='reason';assert (flow->>'amount')::numeric=100;perform public.telegram_payroll_fine(chat,900000012,'cancel');
 assert not has_function_privilege('authenticated','public.telegram_payroll_fine(bigint,bigint,text,text)','execute');
 assert not has_table_privilege('authenticated','payroll_private.fines','select');
end $$;
rollback;
