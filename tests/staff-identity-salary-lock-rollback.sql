begin;
do $$declare worker uuid;me bigint;sid uuid;other bigint;otheremp bigint;bid bigint;blocked boolean;m jsonb;begin
 select a.user_id,a.person_id,s.id into worker,me,sid from staff_accounts a join auth.sessions s on s.user_id=a.user_id where a.active and a.role='staff' limit 1;assert worker is not null;
 select id into other from sales_people where is_active and id<>me limit 1;select id into bid from sales_branches where is_active and not is_test and not is_workshop order by id limit 1;select id into otheremp from sales_employees where person_id=other and branch_id=bid limit 1;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',worker,'role','authenticated','session_id',sid)::text,true);execute 'set local role authenticated';
 perform public.payroll_lock();blocked:=false;begin perform public.payroll_report(current_date-7,current_date);exception when sqlstate 'PT401' then blocked:=true;end;assert blocked;
 blocked:=false;begin perform public.sales_open_team_shift(bid,array[other]::bigint[],null,null);exception when sqlstate 'PT403' then blocked:=true;end;assert blocked;
 blocked:=false;begin perform public.sales_open_or_join_shift(bid,otheremp);exception when sqlstate 'PT403' then blocked:=true;end;assert blocked;
 blocked:=false;begin insert into sales_shifts(branch_id,employee_id) values(bid,otheremp);exception when insufficient_privilege then blocked:=true;end;assert blocked;
 m:=public.sales_open_team_shift(bid,array[me]::bigint[],null,null);assert m->>'shiftId' is not null;
 execute 'reset role';perform set_config('request.jwt.claims','{"role":"service_role"}',true);perform public.payroll_unlock(worker,sid);
 perform set_config('request.jwt.claims',jsonb_build_object('sub',worker,'role','authenticated','session_id',sid)::text,true);execute 'set local role authenticated';
 m:=public.payroll_report(current_date-7,current_date);assert not exists(select 1 from jsonb_array_elements(m->'rows')x where (x->>'person_id')::bigint is distinct from me);
 perform public.payroll_lock();blocked:=false;begin perform public.payroll_report(current_date-7,current_date);exception when sqlstate 'PT401' then blocked:=true;end;assert blocked;
 execute 'reset role';assert not has_function_privilege('authenticated','public.payroll_unlock(uuid,uuid)','execute');assert not has_table_privilege('authenticated','payroll_private.unlocks','select');
end $$;
rollback;
