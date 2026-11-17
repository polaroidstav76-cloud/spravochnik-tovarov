-- Run inside BEGIN/ROLLBACK; real orders are never changed.
do $test$
declare creator uuid;actor uuid;person bigint;b bigint;e bigint;sh bigint;p bigint;ok boolean;blocked boolean;
begin
 select user_id,person_id into creator,person from public.staff_accounts where active and role='staff' and person_id is not null limit 1;
 select user_id into actor from public.staff_accounts where active and role='staff' and user_id<>creator limit 1;
 if actor is null then raise exception 'Missing staff test actor';end if;
 insert into public.sales_branches(name,is_test) values('__pickup_any_staff_'||gen_random_uuid(),true) returning id into b;
 insert into public.sales_employees(branch_id,name,person_id) values(b,'Test creator',person) returning id into e;
 insert into public.sales_shifts(branch_id,employee_id,status,ended_at) values(b,e,'closed',now()) returning id into sh;
 insert into public.pickup_orders(branch_id,shift_id,employee_id,order_number,items,gross_total,total,status) values(b,sh,e,999999,'[]',100,100,'pending') returning id into p;
 -- A different active staff member has no assignment or open shift in this branch.
 perform set_config('request.jwt.claims',jsonb_build_object('sub',actor,'role','authenticated')::text,true);
 execute 'set local role authenticated';
 blocked:=false;begin perform public.sales_cancel_pickup(p,'  ');exception when others then blocked:=sqlerrm='Укажите причину удаления';end;
 if not blocked then raise exception 'Blank reason accepted';end if;
 ok:=public.sales_cancel_pickup(p,'Test other staff, other branch, closed shift');
 blocked:=false;begin perform public.sales_cancel_pickup(p,'Again');exception when others then blocked:=sqlerrm='Заказ не найден или уже закрыт';end;
 execute 'reset role';
 if not ok or not blocked or not exists(select 1 from public.pickup_orders where id=p and status='cancelled' and cancelled_at is not null and cancel_reason='Test other staff, other branch, closed shift') then raise exception 'Cross-branch staff cancellation failed';end if;
 -- Paid orders cannot be cancelled by this endpoint.
 insert into public.pickup_orders(branch_id,shift_id,employee_id,order_number,items,gross_total,total,status) values(b,sh,e,999999,'[]',100,100,'paid') returning id into p;
 execute 'set local role authenticated';
 blocked:=false;begin perform public.sales_cancel_pickup(p,'Paid');exception when others then blocked:=sqlerrm='Заказ не найден или уже закрыт';end;
 execute 'reset role';if not blocked then raise exception 'Paid order cancelled';end if;
 -- A signed-in account without active staff access is denied.
 perform set_config('request.jwt.claims',jsonb_build_object('sub',gen_random_uuid(),'role','authenticated')::text,true);
 execute 'set local role authenticated';
 blocked:=false;begin perform public.sales_cancel_pickup(p,'No staff access');exception when sqlstate 'PT403' then blocked:=true;end;
 execute 'reset role';if not blocked then raise exception 'Nonstaff account allowed';end if;
 if has_function_privilege('anon','public.sales_cancel_pickup(bigint,text)','execute') then raise exception 'Anonymous access granted';end if;
end $test$;
